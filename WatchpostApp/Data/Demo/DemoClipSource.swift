import Foundation

/// The offline demo: the real screens and the real model, fed from files that
/// ship with the app instead of from a server. Everything it shows is made up,
/// except for one event: a real recording, six cameras composed into one picture,
/// which every screen marks as such (`RecordedEvent.isRealSample`). Nothing drawn
/// is ever shown in its place: without its file, that event fails.
/// `Tools/MakeDemoMedia` draws the footage from code and writes the files this reads
/// (`demo-events.json`, `demo-telemetry.json`, the clips and stills, the export samples).
/// The ones that carry words — the place names in `demo-events.json` and the export
/// samples — ship once per language in its `.lproj` folder, and `Bundle.main` hands back the
/// copy in the app's language, like it does for `Localizable.xcstrings`.
///
/// The events are placed relative to the moment the demo is opened, so the list
/// always starts with something from today. Every drawn clip is 12 seconds long;
/// the real recording is as long as its file is, 20 seconds.
struct DemoClipSource: ClipSource {
    var identity: SourceIdentity { .demo }

    /// Two sets of footage of one car: parked in a bay (six cameras) and driving
    /// along a street (the four cameras a typical car has).
    enum Footage: String, Sendable {
        case parked
        case drive

        var clip: (name: String, ext: String) { (self == .parked ? "demo" : "demo-drive", "mp4") }
        /// The cameras this car has. An event that names no cameras has all of them.
        var cameras: [Camera] {
            self == .parked ? [.leftRepeater, .front, .rightRepeater, .leftPillar, .back, .rightPillar]
                : [.front, .back, .leftRepeater, .rightRepeater]
        }
        var thumbnail: (name: String, ext: String) { (self == .parked ? "demo-thumb" : "demo-drive-thumb", "png") }
        /// The same clip with the strip a server burns into an exported file.
        var exported: (name: String, ext: String) { (self == .parked ? "demo-export" : "demo-drive-export", "mp4") }
    }

    /// The one real recording the demo ships: twenty seconds of a drive from a public
    /// data set, its six cameras already composed into one picture, each with its name on
    /// it and the credit at the bottom. It comes as it is. It is not drawn, it cannot be
    /// taken apart into cameras, and it says nothing about when or where it was recorded.
    /// Its names never start with `demo-`, so the media generator leaves them alone.
    enum RealSample {
        /// The clip in the bundle, without its extension: the event's one file, and the
        /// name an export of it keeps.
        static let clip = "watchpost-real-six-camera-20s"
        /// One frame of the clip, in the 4:3 shape of the list's thumbnails.
        static let still = "watchpost-real-six-camera-20s-still"
        /// How long the clip is, as it was composed. The app does not read it from the file.
        static let duration: TimeInterval = 20
        /// The data set the recording comes from and the licence it is under: what the credit under its
        /// playback opens. `ATTRIBUTION.txt`, which ships beside the clip, says the same.
        static let source = URL(string: "https://huggingface.co/datasets/cfahlgren1/tesla-fsd-drive-5min")!
        static let license = URL(string: "https://creativecommons.org/licenses/by/4.0/")!
    }

    /// How long the demo pretends a server takes to burn the watermark. The
    /// sheet asks once a second, so this is seen as three steps.
    private static let exportDuration: TimeInterval = 2.4
    private static let exportIDPrefix = "demo-"

    /// Newest first.
    private let events: [RecordedEvent]
    /// The footage behind every drawn clip, by the clip's path.
    private let footageByPath: [String: Footage]
    /// The path of the real recording's clip; nil when the list does not have it.
    private let realSamplePath: String?
    private let drivingTelemetry: TelemetryOutcome
    private let sync: SyncStatus
    /// How long every drawn demo clip is, as the media file says.
    private let clipDuration: TimeInterval?
    /// Where the demo's files are read from: the app's bundle, or one a test made without some of them.
    private let bundle: Bundle

    init(now: Date = Date(), bundle: Bundle = .main) {
        var events: [RecordedEvent] = []
        var footage: [String: Footage] = [:]
        var realSamplePath: String?
        if let url = bundle.bundled("demo-events", "json"), let data = try? Data(contentsOf: url) {
            let root = JSONValue(data: data)
            clipDuration = root["clipSeconds"]?.double.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            for row in root["events"]?.array ?? [] {
                // The real recording has a row of its own and is not made from a set of footage.
                if row["realSample"]?.bool == true {
                    if let event = Self.realSampleEvent(row, now: now, bundle: bundle) {
                        events.append(event)
                        realSamplePath = event.groups.first?.videos.first?.path
                    }
                    continue
                }
                guard let (event, set) = Self.event(row, duration: clipDuration, now: now, bundle: bundle) else { continue }
                events.append(event)
                for group in event.groups {
                    for video in group.videos { footage[video.path] = set }
                }
            }
            sync = Self.syncStatus(root["sync"])
        } else {
            clipDuration = nil
            sync = .unknown
        }
        self.events = events.sorted { $0.start > $1.start }
        self.footageByPath = footage
        self.realSamplePath = realSamplePath
        if let url = bundle.bundled("demo-telemetry", "json") {
            drivingTelemetry = Wire.telemetry(JSONValue(data: (try? Data(contentsOf: url)) ?? Data()))
        } else {
            drivingTelemetry = .none
        }
        self.bundle = bundle
    }

    // MARK: Building the events

    /// `yyyy-MM-dd_HH-mm-ss` on the phone's clock, as the car writes clip names.
    private static func stamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d_%02d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private static func event(_ row: JSONValue, duration: TimeInterval?, now: Date, bundle: Bundle) -> (RecordedEvent, Footage)? {
        guard let category = row["category"]?.string.flatMap(ClipCategory.init(rawValue:)),
              let minutesAgo = row["minutesAgo"]?.double, minutesAgo.isFinite,
              let set = row["footage"]?.string.flatMap(Footage.init(rawValue:)) else { return nil }
        let groupCount = max(row["groups"]?.int ?? 1, 1)
        let named = row["cameras"]?.array
        let cameraNames = named?.compactMap { $0.string } ?? set.cameras.map(\.rawValue)
        let cameras = cameraNames.compactMap(Camera.init(rawValue:))

        // Like a real event, the first minute starts on a whole minute.
        let start = (now.addingTimeInterval(-minutesAgo * 60)).roundedDownToMinute
        let name = stamp(start)
        var groups: [ClipGroup] = []
        for index in 0..<groupCount {
            let minute = start.addingTimeInterval(TimeInterval(index) * 60)
            let files = stamp(minute)
            let videos = cameras.map { camera in
                ClipVideo(file: "\(files)-\(camera.rawValue).mp4", camera: camera,
                          path: "/media/\(category.rawValue)/\(name)/\(files)-\(camera.rawValue).mp4", duration: duration)
            }
            groups.append(ClipGroup(start: minute, videos: videos))
        }

        var meta = EventMeta()
        meta.reason = row["reason"]?.string
        meta.cameraNumber = row["camera"]?.int
        if let offset = row["triggerOffset"]?.double, offset.isFinite {
            meta.timestamp = start.addingTimeInterval(min(max(offset, 0), 60))
        }
        meta.city = row["city"]?.string
        meta.street = row["street"]?.string

        let size = groups.flatMap(\.videos).reduce(Int64(0)) { $0 + (bundle.bundled(set.clip, camera: $1.camera).flatMap(Self.size(of:)) ?? 0) }
        return (RecordedEvent(category: category, name: name, meta: meta, groups: groups, sizeBytes: size, isLocked: nil), set)
    }

    /// The real recording, from its row: which category it is listed under and how long
    /// ago it sits, placed like the other events. Nothing else is read from the row: it has
    /// no reason, no place and no timestamp, so nothing about it can read as when or where
    /// it was recorded. The demo's date is only where it sits in the list.
    private static func realSampleEvent(_ row: JSONValue, now: Date, bundle: Bundle) -> RecordedEvent? {
        guard let category = row["category"]?.string.flatMap(ClipCategory.init(rawValue:)),
              let minutesAgo = row["minutesAgo"]?.double, minutesAgo.isFinite else { return nil }
        let start = (now.addingTimeInterval(-minutesAgo * 60)).roundedDownToMinute
        let name = stamp(start)
        // A clip has to belong to one camera; `.front` is the model's fallback and means none here.
        let video = ClipVideo(file: "\(RealSample.clip).mp4", camera: .front,
                              path: "/media/\(category.rawValue)/\(name)/\(RealSample.clip).mp4", duration: RealSample.duration)
        return RecordedEvent(category: category, name: name, meta: EventMeta(), groups: [ClipGroup(start: start, videos: [video])],
                             sizeBytes: bundle.bundled(RealSample.clip, "mp4").flatMap(size(of:)) ?? 0, isLocked: nil,
                             isRealSample: true)
    }

    private static func syncStatus(_ row: JSONValue?) -> SyncStatus {
        var status = SyncStatus()
        status.syncRunning = row?["syncRunning"]?.bool
        status.lastSyncAgo = row?["lastSyncAgo"]?.double.flatMap { $0.isFinite ? $0 : nil }
        status.ffmpegAvailable = row?["ffmpegAvailable"]?.bool
        status.archiveUsedBytes = row?["archiveUsedBytes"]?.int64
        status.archiveLimitBytes = row?["archiveLimitBytes"]?.int64
        status.measuredAt = Date()
        return status
    }

    private static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    // MARK: Clips

    func events() async throws -> [RecordedEvent] { events }

    func syncStatus() async throws -> SyncStatus { sync }

    private func footage(of video: ClipVideo) -> Footage? { footageByPath[video.path] }

    /// Whether `path` is the real recording's clip.
    private func isRealSample(path: String) -> Bool { path == realSamplePath }

    func thumbnail(for video: ClipVideo, at time: TimeInterval) -> MediaRequest {
        // The real recording has the one still, whatever moment is asked for. Without it, nothing is offered
        // in its place: like a clip the demo does not know, it asks for a picture that is nowhere.
        if isRealSample(path: video.path) {
            return bundle.bundled(RealSample.still, "jpg").map { MediaRequest(url: $0) }
                ?? MediaRequest(url: URL(fileURLWithPath: "/dev/null"))
        }
        guard let set = footage(of: video),
              let url = bundle.bundled("\(set.thumbnail.name)-\(video.camera.rawValue)", set.thumbnail.ext) else {
            return MediaRequest(url: URL(fileURLWithPath: "/dev/null"))
        }
        return MediaRequest(url: url)
    }

    func imageData(for request: MediaRequest) async throws -> Data {
        guard request.url.isFileURL, request.url.path != "/dev/null" else { throw UpstreamError.http(status: 404, message: nil) }
        return try Data(contentsOf: request.url)
    }

    /// The demo has one file per clip, so every quality is that file: for the real recording, the same file for all its cameras.
    func playbackPlan(for video: ClipVideo, quality: Quality) async throws -> PlaybackPlan {
        let url = isRealSample(path: video.path)
            ? bundle.bundled(RealSample.clip, "mp4")
            : footage(of: video).flatMap { bundle.bundled($0.clip, camera: video.camera) }
        guard let url else { throw UpstreamError.http(status: 404, message: nil) }
        return PlaybackPlan.exact(PlaybackAsset(url: url, quality: quality), requested: quality)
    }

    /// Only clips recorded while driving carry telemetry, as on a real car. The real recording carries none.
    func telemetry(for video: ClipVideo) async throws -> TelemetryOutcome {
        footage(of: video) == .drive ? drivingTelemetry : .none
    }

    // MARK: Export

    func watermarkAvailability() async throws -> WatermarkAvailability { .available }

    func startExport(event: RecordedEvent, video: ClipVideo, quality: Quality) async throws -> ExportHandle {
        let id = Self.exportIDPrefix + String(Int64(Date().timeIntervalSince1970 * 1000))
        // The real recording is handed over as it ships, under its own name: no demo date and no camera in it.
        if isRealSample(path: video.path) {
            guard bundle.bundled(RealSample.clip, "mp4") != nil else { throw ExportFailure.server("") }
            return ExportHandle(id: id, eventID: event.id, file: video.file, camera: video.camera, quality: quality,
                                fileName: "\(RealSample.clip).mp4")
        }
        guard let set = footage(of: video), bundle.bundled(set.exported, camera: video.camera) != nil else {
            throw ExportFailure.server("")
        }
        return Self.handle(event: event, video: video, quality: quality, id: id)
    }

    /// Read off the job's own id, so nothing has to be remembered between asks.
    func exportJob(_ handle: ExportHandle) async throws -> ExportJobStatus {
        guard let started = Int64(handle.id.dropFirst(Self.exportIDPrefix.count)),
              let url = exportedFile(for: handle) else {
            return ExportJobStatus(state: .error, percent: nil, message: nil, sizeBytes: nil)
        }
        let elapsed = Date().timeIntervalSince1970 - Double(started) / 1000
        guard elapsed >= 0, elapsed < Self.exportDuration else {
            return ExportJobStatus(state: .done, percent: 100, message: nil, sizeBytes: Self.size(of: url))
        }
        return ExportJobStatus(state: .running, percent: Int(elapsed / Self.exportDuration * 100), message: nil, sizeBytes: nil)
    }

    /// The file an export hands over: a drawn clip's watermarked sample, or the real recording itself.
    private func exportedFile(for handle: ExportHandle) -> URL? {
        let path = "/media/\(handle.eventID)/\(handle.file)"
        if isRealSample(path: path) { return bundle.bundled(RealSample.clip, "mp4") }
        return footageByPath[path].flatMap { bundle.bundled($0.exported, camera: handle.camera) }
    }

    /// Brings the bundled sample to the temporary folder in a few steps, as a
    /// download would, so the sheet's progress is seen.
    func downloadExport(_ handle: ExportHandle,
                        progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> URL {
        guard let source = exportedFile(for: handle) else {
            throw ExportFailure.expired
        }
        let data = try Data(contentsOf: source)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(handle.fileName, isDirectory: false)
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ExportFailure.network }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        let total = Int64(data.count)
        let step = max(total / 8, 1)
        var received: Int64 = 0
        while received < total {
            try Task.checkCancellation()
            let end = min(received + step, total)
            try file.write(contentsOf: data.subdata(in: Int(received)..<Int(end)))
            received = end
            progress(.downloading(received: received, total: total))
            try await Task.sleep(for: .milliseconds(40))
        }
        return destination
    }
}

private extension Bundle {
    /// A file of the demo's, at the top of the bundle or in its `DemoAssets` folder.
    func bundled(_ name: String, _ ext: String) -> URL? {
        url(forResource: name, withExtension: ext)
            ?? url(forResource: name, withExtension: ext, subdirectory: "DemoAssets")
    }

    /// A file of a set of footage, one per camera: `<name>-<camera>.<ext>`.
    func bundled(_ file: (name: String, ext: String), camera: Camera) -> URL? {
        bundled("\(file.name)-\(camera.rawValue)", file.ext)
    }
}

extension Date {
    fileprivate var roundedDownToMinute: Date { Date(timeIntervalSince1970: floor(timeIntervalSince1970 / 60) * 60) }
}
