import Foundation

// The one seam between the screens and where clips come from. A saved server
// and the built-in demo both speak this, so the demo is the real app with a
// different source behind it, and no screen talks to the network itself.

/// Where the app's clips come from.
enum SourceIdentity: Hashable, Sendable {
    case demo
    case server(UUID)
}

/// A URL with the headers that must go with it (the session cookie).
struct MediaRequest: Hashable, Sendable {
    let url: URL
    let headers: [String: String]

    init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }
}

/// Something the player can play: the URL, the headers it needs, and the
/// quality it really is. The quality is what the file is, not what was asked for.
struct PlaybackAsset: Hashable, Sendable {
    let url: URL
    let headers: [String: String]
    let quality: Quality

    init(url: URL, quality: Quality, headers: [String: String] = [:]) {
        self.url = url
        self.quality = quality
        self.headers = headers
    }

    var request: MediaRequest { MediaRequest(url: url, headers: headers) }
}

/// How playback moves on from its first file to the quality that was asked for.
enum PlaybackUpgrade: Hashable, Sendable {
    /// The server is still making it (said again on every look, so the UI can tell waiting from stuck).
    case preparing
    case ready(PlaybackAsset)
    /// The server cannot make it. Playback stays on what it has.
    case unavailable
}

/// What to play for one clip at one quality.
struct PlaybackPlan: Sendable {
    /// Play this now.
    let initial: PlaybackAsset
    let requested: Quality
    /// Only followed while `initial.quality != requested`. Ends after `.ready` or `.unavailable`.
    let upgrades: AsyncStream<PlaybackUpgrade>

    /// A plan that is already the quality that was asked for.
    static func exact(_ asset: PlaybackAsset, requested: Quality) -> PlaybackPlan {
        PlaybackPlan(initial: asset, requested: requested, upgrades: AsyncStream { $0.finish() })
    }
}

enum WatermarkAvailability: Hashable, Sendable {
    case available
    case unavailable
}

enum ExportProgress: Hashable, Sendable {
    /// The server is burning the watermark. The percentage is its own count, when it gives one.
    case generating(percent: Int?)
    /// The finished file is being copied to the phone.
    case downloading(received: Int64, total: Int64?)
}

enum ExportFailure: Error, Hashable, Sendable {
    /// The server has no Chinese font (or no ffmpeg), so it refuses to make a watermarked file.
    case watermarkUnavailable
    /// The server refused or failed, in its own words.
    case server(String)
    /// The finished file was already gone when it was asked for.
    case expired
    /// Talking to the server failed.
    case network
    case cancelled
}

/// A job the source was asked to make. The export sheet keeps it, so a wait
/// that was ended can be picked up again while the file is still there.
struct ExportHandle: Hashable, Codable, Sendable {
    let id: String
    let eventID: String
    let file: String
    let camera: Camera
    let quality: Quality
    /// The name the finished file gets on the phone and wherever it is shared.
    let fileName: String
}

protocol ClipSource: Sendable {
    var identity: SourceIdentity { get }

    /// Every event of the three categories, newest first.
    func events() async throws -> [RecordedEvent]
    /// The same event with what only the player's request knows (how long each clip is).
    /// Sources that know nothing more return it unchanged.
    func detailedEvent(_ event: RecordedEvent) async throws -> RecordedEvent
    func syncStatus() async throws -> SyncStatus

    /// The still to show for a clip, taken `time` seconds in.
    func thumbnail(for video: ClipVideo, at time: TimeInterval) -> MediaRequest
    func imageData(for request: MediaRequest) async throws -> Data

    func playbackPlan(for video: ClipVideo, quality: Quality) async throws -> PlaybackPlan
    func telemetry(for video: ClipVideo) async throws -> TelemetryOutcome

    /// Whether a watermarked file can be made right now. Throws when the
    /// source could not be asked; that is not the same as "no".
    func watermarkAvailability() async throws -> WatermarkAvailability

    /// Hands one camera and one minute to the source and returns at once.
    func startExport(event: RecordedEvent, video: ClipVideo, quality: Quality) async throws -> ExportHandle
    /// One look at a job. `.unknown` means "ask again".
    func exportJob(_ handle: ExportHandle) async throws -> ExportJobStatus
    /// Brings the finished file to the phone. Throws `ExportFailure.expired`
    /// when the job is no longer there.
    func downloadExport(_ handle: ExportHandle,
                        progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> URL
}

extension ClipSource {
    func detailedEvent(_ event: RecordedEvent) async throws -> RecordedEvent { event }

    /// The name the exported file gets: `<event>_<camera>.mp4`, plus `_<clip>` when the minute
    /// shown is not the one the event is named after. A clip is named by its minute, as the server
    /// names it (`2026-11-08_19-44-36`, without the camera).
    static func exportFileName(event: RecordedEvent, video: ClipVideo) -> String {
        // The server's own export name is `<event>_<N>路.mp4`; this is one camera.
        var clip = video.file.hasSuffix(".mp4") ? String(video.file.dropLast(4)) : video.file
        if let camera = Camera.camera(inFileName: video.file), clip.hasSuffix("-\(camera.rawValue)") {
            clip.removeLast(camera.rawValue.count + 1)
        }
        // A clip of the event's own minute already starts with the event's name.
        let minute = clip.hasPrefix(event.name) ? "" : "_\(clip)"
        return "\(event.name)_\(video.camera.rawValue)\(minute).mp4"
    }

    static func handle(event: RecordedEvent, video: ClipVideo, quality: Quality, id: String) -> ExportHandle {
        ExportHandle(id: id, eventID: event.id, file: video.file, camera: video.camera, quality: quality,
                     fileName: exportFileName(event: event, video: video))
    }

    /// Makes a watermarked clip and brings it to the phone, in one go.
    func export(event: RecordedEvent, video: ClipVideo, quality: Quality,
                progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> URL {
        let handle = try await startExport(event: event, video: video, quality: quality)
        while true {
            try Task.checkCancellation()
            let status = try await exportJob(handle)
            switch status.state {
            case .done:
                return try await downloadExport(handle, progress: progress)
            case .error:
                throw ExportFailure.server(status.message ?? "")
            case .running, .unknown:
                progress(.generating(percent: status.percent))
                try await Task.sleep(for: .seconds(1))
            }
        }
    }
}
