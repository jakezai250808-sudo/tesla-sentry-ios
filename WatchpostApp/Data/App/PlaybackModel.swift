import AVFoundation
import CoreMedia
import Foundation
import Observation

/// Why nothing can be shown for a clip.
enum PlaybackProblem: Equatable {
    /// The server no longer has the clip: it was cleaned up since the list was loaded.
    case removed
    /// The file is there but cannot be played (a codec the phone cannot decode, a server error).
    case cannotPlay
}

@MainActor
@Observable
final class PlaybackModel {
    /// Where a person left an event, so opening it again goes back there.
    private static var leftOff: [String: (group: Int, camera: Camera, time: TimeInterval, at: Date)] = [:]

    let source: any ClipSource
    /// The event as the list knows it, then with the clip lengths once the server told them.
    private(set) var event: RecordedEvent
    let player = AVPlayer()

    private(set) var groupIndex: Int
    private(set) var camera: Camera
    /// The quality asked for; kept per server by whoever made this model.
    private(set) var quality: Quality
    /// What is really on screen.
    private(set) var playingQuality: Quality = .original
    /// The file playing is the original while the server makes the quality that was asked for.
    private(set) var waitingForQuality = false
    /// The server said it cannot make the asked-for quality; playback stays on what it has.
    private(set) var qualityUnavailable = false

    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var ended = false
    private(set) var problem: PlaybackProblem?
    /// The camera that triggered the event has no footage; this event opens on another camera.
    private(set) var triggerCameraMissing = false
    private(set) var videoSize: CGSize?

    private(set) var telemetry = TelemetryState.loading
    /// The readings for the moment on screen; nil when nothing was recorded near it.
    private(set) var sample: TelemetrySample?

    /// Called when the person picks another quality, so the app remembers it for this server.
    var onQualityChosen: ((Quality) -> Void)?

    private var export: ExportModel?

    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var generation = 0

    init(event: RecordedEvent, source: any ClipSource, preferredQuality: Quality) {
        self.event = event
        self.source = source
        self.quality = preferredQuality
        let trigger = event.trigger
        groupIndex = trigger.groupIndex
        camera = trigger.camera
        triggerCameraMissing = trigger.cameraMissing
        player.actionAtItemEnd = .pause
        observePlayer()
    }

    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: What is on screen

    var group: ClipGroup? { event.groups.indices.contains(groupIndex) ? event.groups[groupIndex] : nil }

    var video: ClipVideo? { group?.video(for: camera) }

    /// There is a file to play but nothing is in the player: a load was cut short, or the player was cleared.
    var isUnloaded: Bool { video != nil && problem == nil && player.currentItem == nil }

    /// Cameras with footage in the minute being played, in switcher order.
    var groupCameras: [Camera] { group?.cameras ?? [] }

    /// Every camera of the event, for the switcher; ones without footage in this minute are disabled.
    var eventCameras: [Camera] { event.cameras }

    var hasPreviousGroup: Bool { groupIndex > 0 }
    var hasNextGroup: Bool { groupIndex + 1 < event.groups.count }

    /// Where the trigger is in this minute, when the event's own timestamp falls here.
    var triggerOffset: TimeInterval? {
        let trigger = event.trigger
        return trigger.isExact && trigger.groupIndex == groupIndex ? trigger.offset : nil
    }

    var reason: ReasonLabel { TriggerReasons.label(for: event.meta.reason) }

    /// The export for the clip on screen. Kept while the same clip is on screen, so
    /// closing the export sheet and opening it again finds the same job.
    func exportModel() -> ExportModel? {
        guard let video else { return nil }
        if let export, export.video == video, export.quality == quality { return export }
        let model = ExportModel(source: source, event: event, video: video, quality: quality)
        export = model
        return model
    }

    // MARK: Opening

    /// Opens the event on its trigger, or where the person left off a moment ago.
    func open() async {
        let detailed = (try? await source.detailedEvent(event)) ?? event
        guard !Task.isCancelled else { return }
        event = detailed

        let trigger = detailed.trigger
        triggerCameraMissing = trigger.cameraMissing
        var start = trigger.playbackStart
        groupIndex = trigger.groupIndex
        camera = trigger.camera
        // Back to an event just left: same minute, same camera, where it stopped.
        if let leftOff = Self.leftOff[event.id], Date().timeIntervalSince(leftOff.at) < 900,
           detailed.groups.indices.contains(leftOff.group), detailed.groups[leftOff.group].video(for: leftOff.camera) != nil {
            groupIndex = leftOff.group
            camera = leftOff.camera
            start = leftOff.time
            triggerCameraMissing = false
        }
        Self.leftOff[event.id] = nil
        await load(startAt: start, autoplay: true)
    }

    /// Called when the screen goes away: remembers the spot and stops everything.
    func close() {
        if !ended, currentTime > 1, currentTime < max(duration - 1, 0) {
            Self.leftOff[event.id] = (groupIndex, camera, currentTime, Date())
        }
        stop()
    }

    func stop() {
        generation += 1
        loadTask?.cancel()
        telemetryTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Changing what plays

    /// Another camera of the minute being played, at the same moment and the same play state.
    /// Once the minute has played out, or when the minute had no file for the camera before, the
    /// other camera starts from the beginning and plays.
    func select(_ camera: Camera) {
        guard camera != self.camera, let group, group.video(for: camera) != nil else { return }
        let start = Self.swapStart(playedOut: ended, wasPlaying: isPlaying, hadNothing: video == nil, at: currentTime)
        self.camera = camera
        swapFile(startAt: start.startAt, autoplay: start.autoplay)
    }

    func select(quality: Quality) {
        guard quality != self.quality else { return }
        self.quality = quality
        onQualityChosen?(quality)
        let start = Self.swapStart(playedOut: ended, wasPlaying: isPlaying, hadNothing: false, at: currentTime)
        swapFile(startAt: start.startAt, autoplay: start.autoplay)
    }

    func goToPreviousGroup() { moveTo(groupIndex - 1) }
    func goToNextGroup() { moveTo(groupIndex + 1) }

    private func moveTo(_ index: Int) {
        guard event.groups.indices.contains(index) else { return }
        let start = Self.swapStart(playedOut: ended, wasPlaying: isPlaying, hadNothing: false, at: 0)
        groupIndex = index
        // The camera stays as chosen. A minute without it says so on screen; the other cameras are one tap away.
        swapFile(startAt: start.startAt, autoplay: start.autoplay)
    }

    /// Where the file swapped in for another one starts, and whether it plays at once.
    /// Normally the same moment and the same play state. Once the minute has played out the
    /// playhead sits at its very end, where a fresh file has nothing left to show, so that one
    /// starts over and plays, as Replay does. The first file after a minute without one plays too.
    nonisolated static func swapStart(playedOut: Bool, wasPlaying: Bool, hadNothing: Bool, at time: TimeInterval)
        -> (startAt: TimeInterval, autoplay: Bool) {
        if playedOut || hadNothing { return (0, true) }
        return (time, wasPlaying)
    }

    private func swapFile(startAt time: TimeInterval, autoplay: Bool) {
        loadTask?.cancel()
        Task { await load(startAt: time, autoplay: autoplay) }
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), duration > 0 ? duration : time)
        ended = false
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
    }

    func skip(_ seconds: TimeInterval) { seek(to: currentTime + seconds) }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if ended { ended = false; player.seek(to: .zero) }
            player.play()
        }
    }

    func replay() {
        ended = false
        player.seek(to: .zero)
        player.play()
    }

    func retry() {
        swapFile(startAt: currentTime, autoplay: true)
    }

    // MARK: Loading

    private func load(startAt time: TimeInterval, autoplay: Bool) async {
        generation += 1
        let myGeneration = generation
        loadTask?.cancel()
        guard let video else {
            // Nothing was recorded for this camera in this minute.
            player.replaceCurrentItem(with: nil)
            problem = nil
            ended = false
            waitingForQuality = false
            qualityUnavailable = false
            duration = 0
            currentTime = 0
            videoSize = nil
            isPlaying = false
            isBuffering = false
            telemetry = .none
            sample = nil
            return
        }
        problem = nil
        ended = false
        waitingForQuality = false
        qualityUnavailable = false
        videoSize = nil
        loadTelemetry(for: video, generation: myGeneration)

        let requested = quality
        let plan: PlaybackPlan
        do {
            plan = try await source.playbackPlan(for: video, quality: requested)
        } catch {
            guard myGeneration == generation, !Task.isCancelled else { return }
            problem = Self.problem(for: error)
            return
        }
        guard myGeneration == generation, !Task.isCancelled else { return }
        duration = video.duration ?? duration
        currentTime = time
        playingQuality = plan.initial.quality
        waitingForQuality = plan.initial.quality != requested

        let item = Self.makeItem(plan.initial)
        observe(item)
        player.replaceCurrentItem(with: item)
        if time > 0 {
            await seekNear(time)
            guard myGeneration == generation else { return }
        }
        if autoplay { player.play() }
        follow(plan, generation: myGeneration)
    }

    /// Puts the playhead at `time` on the file just given to the player. Without a tolerance the
    /// player may land on the keyframe before it, seconds earlier in a long group of pictures.
    private func seekNear(_ time: TimeInterval) async {
        _ = await player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                              toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                              toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
    }

    /// Swaps in the quality that was asked for once the server has it, at the same moment.
    private func follow(_ plan: PlaybackPlan, generation myGeneration: Int) {
        guard plan.initial.quality != plan.requested else { return }
        loadTask = Task { [weak self] in
            for await upgrade in plan.upgrades {
                guard let self, myGeneration == self.generation else { break }
                switch upgrade {
                case .preparing:
                    self.waitingForQuality = true
                case .ready(let asset):
                    self.waitingForQuality = false
                    await self.replace(with: asset, quality: plan.requested, generation: myGeneration)
                case .unavailable:
                    self.waitingForQuality = false
                    self.qualityUnavailable = true
                }
            }
        }
    }

    private func replace(with asset: PlaybackAsset, quality: Quality, generation myGeneration: Int) async {
        let time = currentTime
        // A minute that played out while the server was working stays played out, on the better file.
        let resume = isPlaying && !ended
        let item = Self.makeItem(asset)
        observe(item)
        player.replaceCurrentItem(with: item)
        playingQuality = quality
        if time > 0 {
            await seekNear(time)
            guard myGeneration == generation else { return }
        }
        if resume { player.play() }
    }

    private static func makeItem(_ asset: PlaybackAsset) -> AVPlayerItem {
        let urlAsset = AVURLAsset(url: asset.url, options: ["AVURLAssetHTTPHeaderFieldsKey": asset.headers])
        return AVPlayerItem(asset: urlAsset)
    }

    private static func problem(for error: Error) -> PlaybackProblem {
        let nsError = error as NSError
        // AVFoundation reports an HTTP 404 as -12938; a file that is gone also comes as "file does not exist".
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorFileDoesNotExist { return .removed }
        if nsError.domain == "AVFoundationErrorDomain" && nsError.code == -12938 { return .removed }
        if nsError.domain == "CoreMediaErrorDomain" && nsError.code == -12889 { return .removed }
        return .cannotPlay
    }

    // MARK: Telemetry

    func retryTelemetry() {
        guard let video else { return }
        loadTelemetry(for: video, generation: generation)
    }

    private func loadTelemetry(for video: ClipVideo, generation myGeneration: Int) {
        telemetryTask?.cancel()
        telemetry = .loading
        sample = nil
        let source = source
        telemetryTask = Task { [weak self] in
            do {
                let outcome = try await source.telemetry(for: video)
                guard let self, myGeneration == self.generation, !Task.isCancelled else { return }
                switch outcome {
                case .none: self.telemetry = .none
                case .track(let track): self.telemetry = .loaded(track)
                }
            } catch {
                guard let self, myGeneration == self.generation, !Task.isCancelled else { return }
                self.telemetry = .unavailable
            }
        }
    }

    // MARK: Player events

    private func observePlayer() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.readTransportState() }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor in self?.didEnd(item) }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor in self?.read(status: status, error: error) }
        }
        itemObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor in
                guard let self, size.width > 0, size.height > 0 else { return }
                self.videoSize = size
            }
        }
    }

    private func read(status: AVPlayerItem.Status, error: Error?) {
        if status == .failed, let error, problem == nil {
            problem = Self.problem(for: error)
            isPlaying = false
            isBuffering = false
        }
    }

    private func readTransportState() {
        isPlaying = player.timeControlStatus == .playing
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    private func tick(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        sample = telemetry.track?.sample(at: seconds)
    }

    private func didEnd(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        ended = true
        isPlaying = false
        // Minutes that really follow each other play on; a gap in the recording stops here.
        if let group, event.groups.indices.contains(groupIndex + 1),
           abs(event.groups[groupIndex + 1].start.timeIntervalSince(group.start) - 60) < 0.5,
           event.groups[groupIndex + 1].video(for: camera) != nil {
            ended = false
            groupIndex += 1
            Task { await load(startAt: 0, autoplay: true) }
        }
    }
}
