import Foundation

/// The offline demo: the real screens and the real model, fed from files that
/// ship with the app instead of from a server. Everything it shows is made up.
/// `Tools/MakeDemoMedia` draws the footage from code and writes the files this reads
/// (`demo-events.json`, `demo-telemetry.json`, the clips and stills, the export samples).
/// The ones that carry words — the place names in `demo-events.json` and the export
/// samples — ship once per language in its `.lproj` folder, and `Bundle.main` hands back the
/// copy in the app's language, like it does for `Localizable.xcstrings`.
///
/// The events are placed relative to the moment the demo is opened, so the list
/// always starts with something from today. Every clip is 12 seconds long.
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

    /// How long the demo pretends a server takes to burn the watermark. The
    /// sheet asks once a second, so this is seen as three steps.
    private static let exportDuration: TimeInterval = 2.4
    private static let exportIDPrefix = "demo-"

    /// Newest first.
    private let events: [RecordedEvent]
    /// The footage behind every clip, by the clip's path.
    private let footageByPath: [String: Footage]
    private let drivingTelemetry: TelemetryOutcome
    private let sync: SyncStatus
    /// How long every demo clip is, as the media file says.
    private let clipDuration: TimeInterval?

    init(now: Date = Date()) {
        var events: [RecordedEvent] = []
        var footage: [String: Footage] = [:]
        if let url = Self.bundled("demo-events", "json"), let data = try? Data(contentsOf: url) {
            let root = JSONValue(data: data)
            clipDuration = root["clipSeconds"]?.double.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            for row in root["events"]?.array ?? [] {
                guard let (event, set) = Self.event(row, duration: clipDuration, now: now) else { continue }
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
        if let url = Self.bundled("demo-telemetry", "json") {
            drivingTelemetry = Wire.telemetry(JSONValue(data: (try? Data(contentsOf: url)) ?? Data()))
        } else {
            drivingTelemetry = .none
        }
    }

    // MARK: Building the events

    /// `yyyy-MM-dd_HH-mm-ss` on the phone's clock, as the car writes clip names.
    private static func stamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d_%02d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    private static func bundled(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "DemoAssets")
    }

    private static func event(_ row: JSONValue, duration: TimeInterval?, now: Date) -> (RecordedEvent, Footage)? {
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

        let size = groups.flatMap(\.videos).reduce(Int64(0)) { $0 + (Self.bundled(set.clip, camera: $1.camera).flatMap(Self.size(of:)) ?? 0) }
        return (RecordedEvent(category: category, name: name, meta: meta, groups: groups, sizeBytes: size, isLocked: nil), set)
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

    private static func bundled(_ file: (name: String, ext: String), camera: Camera) -> URL? {
        bundled("\(file.name)-\(camera.rawValue)", file.ext)
    }

    private static func size(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }

    // MARK: Clips

    func events() async throws -> [RecordedEvent] { events }

    func syncStatus() async throws -> SyncStatus { sync }

    private func footage(of video: ClipVideo) -> Footage? { footageByPath[video.path] }

    func thumbnail(for video: ClipVideo, at time: TimeInterval) -> MediaRequest {
        guard let set = footage(of: video),
              let url = Self.bundled("\(set.thumbnail.name)-\(video.camera.rawValue)", set.thumbnail.ext) else {
            return MediaRequest(url: URL(fileURLWithPath: "/dev/null"))
        }
        return MediaRequest(url: url)
    }

    func imageData(for request: MediaRequest) async throws -> Data {
        guard request.url.isFileURL, request.url.path != "/dev/null" else { throw UpstreamError.http(status: 404, message: nil) }
        return try Data(contentsOf: request.url)
    }

    /// The demo has one file per camera, so every quality is that file.
    func playbackPlan(for video: ClipVideo, quality: Quality) async throws -> PlaybackPlan {
        guard let set = footage(of: video), let url = Self.bundled(set.clip, camera: video.camera) else {
            throw UpstreamError.http(status: 404, message: nil)
        }
        return PlaybackPlan.exact(PlaybackAsset(url: url, quality: quality), requested: quality)
    }

    /// Only clips recorded while driving carry telemetry, as on a real car.
    func telemetry(for video: ClipVideo) async throws -> TelemetryOutcome {
        footage(of: video) == .drive ? drivingTelemetry : .none
    }

    // MARK: Export

    func watermarkAvailability() async throws -> WatermarkAvailability { .available }

    func startExport(event: RecordedEvent, video: ClipVideo, quality: Quality) async throws -> ExportHandle {
        guard let set = footage(of: video), Self.bundled(set.exported, camera: video.camera) != nil else {
            throw ExportFailure.server("")
        }
        return Self.handle(event: event, video: video, quality: quality,
                           id: Self.exportIDPrefix + String(Int64(Date().timeIntervalSince1970 * 1000)))
    }

    /// Read off the job's own id, so nothing has to be remembered between asks.
    func exportJob(_ handle: ExportHandle) async throws -> ExportJobStatus {
        guard let started = Int64(handle.id.dropFirst(Self.exportIDPrefix.count)),
              let set = footageByPath["/media/\(handle.eventID)/\(handle.file)"],
              let url = Self.bundled(set.exported, camera: handle.camera) else {
            return ExportJobStatus(state: .error, percent: nil, message: nil, sizeBytes: nil)
        }
        let elapsed = Date().timeIntervalSince1970 - Double(started) / 1000
        guard elapsed >= 0, elapsed < Self.exportDuration else {
            return ExportJobStatus(state: .done, percent: 100, message: nil, sizeBytes: Self.size(of: url))
        }
        return ExportJobStatus(state: .running, percent: Int(elapsed / Self.exportDuration * 100), message: nil, sizeBytes: nil)
    }

    /// Brings the bundled sample to the temporary folder in a few steps, as a
    /// download would, so the sheet's progress is seen.
    func downloadExport(_ handle: ExportHandle,
                        progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> URL {
        guard let set = footageByPath["/media/\(handle.eventID)/\(handle.file)"],
              let source = Self.bundled(set.exported, camera: handle.camera) else {
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

extension Date {
    fileprivate var roundedDownToMinute: Date { Date(timeIntervalSince1970: floor(timeIntervalSince1970 / 60) * 60) }
}
