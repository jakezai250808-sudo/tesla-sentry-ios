import Foundation
import os

/// The server as a `ClipSource`: every event, still, playback plan, telemetry
/// reading and export is one of its HTTP endpoints. Nothing here talks to the
/// network directly; everything goes through `session.data(for:)`, which owns
/// the cookie and the login-and-retry rule.
final class ServerClipSource: ClipSource {
    let session: ServerSession
    var identity: SourceIdentity { .server(session.id) }

    private let pollInterval: Duration
    private let maxPolls: Int
    private let clientID: String
    /// The `rev` of the last `/api/live/demand`; the server refuses one older than it has seen.
    private let demandRevision = OSAllocatedUnfairLock(initialState: 0)

    init(session: ServerSession, pollInterval: Duration = .milliseconds(1500), maxPolls: Int = 120,
         clientID: String = ServerClipSource.makeClientID()) {
        self.session = session
        self.pollInterval = pollInterval
        self.maxPolls = max(0, maxPolls)
        self.clientID = clientID
    }

    /// 32 lowercase hex digits, which is what `/api/live/demand` checks a client id for.
    static func makeClientID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: Events

    func events() async throws -> [RecordedEvent] {
        let response = try await session.data(for: session.request("/api/events"))
        guard response.status == 200 else { throw Self.httpFailure(response) }
        return Wire.recordedEvents(fromEvents: JSONValue(data: response.body))
    }

    func detailedEvent(_ event: RecordedEvent) async throws -> RecordedEvent {
        let path = "/api/timeline?" + ServerPath.query([
            ("cat", event.category.rawValue), ("event", event.name), ("gaps", "0"),
        ])
        do {
            let response = try await session.data(for: session.request(path))
            guard response.status == 200 else { return event }
            let timeline = Wire.recordedEvents(fromTimeline: JSONValue(data: response.body), category: event.category)
            return timeline.first { $0.name == event.name } ?? event
        } catch {
            // Only the player asks for this, and a clip without its length still plays. Stopping is the caller's call, though.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return event
        }
    }

    func syncStatus() async throws -> SyncStatus {
        let response = try await session.data(for: session.request("/api/live"))
        guard response.status == 200 else { throw Self.httpFailure(response) }
        return Wire.syncStatus(fromLive: JSONValue(data: response.body))
    }

    // MARK: Stills

    func thumbnail(for video: ClipVideo, at time: TimeInterval) -> MediaRequest {
        // The server clamps `t` to an hour, and a NaN would trap in `Int(_:)`.
        let seconds = time.isFinite ? Int(min(max(time.rounded(), 0), 3600)) : 0
        let path = ServerPath.path(video.thumbnailPath) + "?t=\(seconds)"
        return MediaRequest(url: Self.url(session, path), headers: session.mediaHeaders)
    }

    func imageData(for request: MediaRequest) async throws -> Data {
        var urlRequest = session.request(url: request.url)
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let response = try await session.data(for: urlRequest)
        guard response.status == 200 else { throw Self.httpFailure(response) }
        return response.body
    }

    // MARK: Telemetry

    func telemetry(for video: ClipVideo) async throws -> TelemetryOutcome {
        let path = "/api/telemetry?" + ServerPath.query([("path", video.archivePath)])
        let response = try await session.data(for: session.request(path))
        // 404 is `bad-path`: the file is gone or outside the archive. Nothing to show, not a failure.
        if response.status == 404 { return .none }
        guard response.status == 200 else { throw Self.httpFailure(response) }
        return Wire.telemetry(JSONValue(data: response.body))
    }

    // MARK: Export prerequisites

    func watermarkAvailability() async throws -> WatermarkAvailability {
        let response = try await session.data(for: session.request("/api/font"))
        guard response.status == 200 else { throw Self.httpFailure(response) }
        guard let available = Wire.fontAvailable(JSONValue(data: response.body)) else { throw UpstreamError.badResponse }
        return available ? .available : .unavailable
    }

    // MARK: Playback

    func playbackPlan(for video: ClipVideo, quality: Quality) async throws -> PlaybackPlan {
        let headers = session.mediaHeaders
        let original = PlaybackAsset(url: Self.url(session, ServerPath.path(video.path)), quality: .original, headers: headers)
        guard quality.isTranscoded else { return .exact(original, requested: .original) }

        switch try await sourceState(for: video, quality: quality) {
        case .ready:
            return .exact(Self.transcodedAsset(for: video, quality: quality, headers: headers, session: session),
                          requested: quality)
        case .failed, .missing:
            // The server cannot transcode (no ffmpeg) or lost the file: the original is all there is.
            return PlaybackPlan(initial: original, requested: quality, upgrades: Self.upgrades(ending: .unavailable))
        case .pending, .cooling:
            nudge(for: video, quality: quality)
            return PlaybackPlan(initial: original, requested: quality,
                                upgrades: Self.pollingUpgrades(session: session, video: video, quality: quality,
                                                               pollInterval: pollInterval, maxPolls: maxPolls))
        }
    }

    /// Asks once. Anything unrecognized reads as `.missing`: nothing to wait for.
    private func sourceState(for video: ClipVideo, quality: Quality) async throws -> PlaybackSourceState {
        let response = try await session.data(for: session.request(Self.sourcePath(video, quality: quality)))
        return Self.state(in: response) ?? .missing
    }

    private static func sourcePath(_ video: ClipVideo, quality: Quality) -> String {
        "/api/playback-source?" + ServerPath.query([("file", video.path), ("q", quality.rawValue)])
    }

    /// The state the server named, whatever the status (400 and 404 both come with `{"state": "missing"}`).
    private static func state(in response: HTTPResponse) -> PlaybackSourceState? {
        JSONValue(data: response.body)["state"]?.string.flatMap(PlaybackSourceState.init(rawValue:))
    }

    /// The transcoded file, asked for strictly: with `exact` the server answers 409 rather than a stand-in of another size.
    private static func transcodedAsset(for video: ClipVideo, quality: Quality, headers: [String: String],
                                        session: ServerSession) -> PlaybackAsset {
        let path = ServerPath.path(video.path) + "?" + ServerPath.query([("q", quality.rawValue), ("exact", "1")])
        return PlaybackAsset(url: url(session, path), quality: quality, headers: headers)
    }

    /// A stream that says one thing and ends.
    private static func upgrades(ending final: PlaybackUpgrade) -> AsyncStream<PlaybackUpgrade> {
        AsyncStream { continuation in
            _ = continuation.yield(final)
            continuation.finish()
        }
    }

    /// Says `.preparing` now and after every look that still finds the server working, then exactly one
    /// `.ready` or `.unavailable`, then ends. The polling task stops as soon as the stream is dropped
    /// or the consumer's task is cancelled, so no loop outlives the player that asked for it.
    private static func pollingUpgrades(session: ServerSession, video: ClipVideo, quality: Quality,
                                        pollInterval: Duration, maxPolls: Int) -> AsyncStream<PlaybackUpgrade> {
        let (stream, continuation) = AsyncStream<PlaybackUpgrade>.makeStream()
        let poller = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
        continuation.onTermination = { _ in
            poller.withLock { slot in
                slot?.cancel()
                slot = nil
            }
        }
        poller.withLock { slot in
            slot = Task {
                defer { continuation.finish() }
                if Self.ended(continuation.yield(.preparing)) { return }
                var polls = 0
                while polls < maxPolls {
                    do {
                        try await Task.sleep(for: pollInterval)
                    } catch {
                        return
                    }
                    switch await poll(session: session, video: video, quality: quality) {
                    case .waiting:
                        polls += 1
                        if Self.ended(continuation.yield(.preparing)) { return }
                    case .final(let upgrade):
                        _ = continuation.yield(upgrade)
                        return
                    }
                }
                // Waited long enough; the original is what plays.
                _ = continuation.yield(.unavailable)
            }
        }
        return stream
    }

    /// True once the stream no longer takes values (it was dropped or cancelled).
    private static func ended(_ result: AsyncStream<PlaybackUpgrade>.Continuation.YieldResult) -> Bool {
        if case .terminated = result { return true }
        return false
    }

    private enum PollResult {
        /// Still being made, or a problem that may pass (a lost connection, a busy server).
        case waiting
        case final(PlaybackUpgrade)
    }

    /// One look at the transcode. A session that cannot be restored ends the waiting, since nothing
    /// that follows would get through either.
    private static func poll(session: ServerSession, video: ClipVideo, quality: Quality) async -> PollResult {
        let response: HTTPResponse
        do {
            response = try await session.data(for: session.request(sourcePath(video, quality: quality)))
        } catch let error as UpstreamError {
            switch error {
            case .unauthorized, .lockedOut, .http(status: 401, _), .http(status: 429, _):
                return .final(.unavailable)
            default:
                return .waiting
            }
        } catch {
            return .waiting
        }
        switch state(in: response) {
        case .ready:
            return .final(.ready(transcodedAsset(for: video, quality: quality, headers: session.mediaHeaders, session: session)))
        case .pending, .cooling, nil:
            return .waiting
        case .failed, .missing:
            return .final(.unavailable)
        }
    }

    // MARK: Hints for the server

    /// Tells the server which clip is about to be played, so it transcodes that one first.
    /// Fire-and-forget: the plan does not depend on the answer.
    private func nudge(for video: ClipVideo, quality: Quality) {
        guard let category = Self.category(of: video) else { return }
        let session = self.session
        let clientID = self.clientID
        let demandRevision = self.demandRevision
        Task.detached(priority: Task.currentPriority) {
            do {
                let path: String
                let body: Data
                switch category {
                case "SentryClips", "SavedClips":
                    // The server only pre-transcodes these two; RecentClips roll out of the archive too fast.
                    path = "/api/kick"
                    body = try JSONEncoder().encode(Kick(q: quality.rawValue, paths: [video.path]))
                case "RecentClips":
                    path = "/api/live/demand"
                    let rev = demandRevision.withLock { current in
                        current += 1
                        return current
                    }
                    body = try JSONEncoder().encode(Demand(client: clientID, rev: rev, paths: [video.path], q: quality.rawValue))
                default:
                    return
                }
                _ = try await session.data(for: session.request(path, method: "POST", body: body, contentType: "application/json"))
            } catch {
                // A hint nobody is waiting for.
            }
        }
    }

    /// `/media/<category>/<event>/<file>` → the category as the server spells it.
    private static func category(of video: ClipVideo) -> String? {
        let parts = video.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 4, parts[0] == "media" else { return nil }
        return String(parts[1])
    }

    private struct Kick: Encodable {
        let q: String
        let paths: [String]
    }

    private struct Demand: Encodable {
        let client: String
        let rev: Int
        let paths: [String]
        let q: String
    }

    // MARK: Export

    func startExport(event: RecordedEvent, video: ClipVideo, quality: Quality) async throws -> ExportHandle {
        let request = BurnRequest(cat: event.category.rawValue, name: event.name, cams: [video.camera.rawValue],
                                  wm: true, q: quality.rawValue, files: [video.file])
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let body = try encoder.encode(request)
            let response = try await session.data(for: session.request("/api/export/burn", method: "POST", body: body,
                                                                                    contentType: "application/json"))
            switch Wire.exportJobStarted(JSONValue(data: response.body)) {
            case .success(let id):
                guard response.status == 200 else { throw ExportFailure.server(response.failureMessage ?? "") }
                return Self.handle(event: event, video: video, quality: quality, id: id)
            case .failure(let refusal):
                throw Self.refusal(refusal.message)
            }
        } catch {
            try Self.throwExportFailure(error)
        }
    }

    func exportJob(_ handle: ExportHandle) async throws -> ExportJobStatus {
        let path = "/api/stitch/status?" + ServerPath.query([("id", handle.id)])
        do {
            let response = try await session.data(for: session.request(path))
            return Wire.exportJobStatus(JSONValue(data: response.body), httpStatus: response.status)
        } catch {
            try Self.throwExportFailure(error)
        }
    }

    func downloadExport(_ handle: ExportHandle,
                        progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> URL {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("WatchpostExports", isDirectory: true)
        let destination = directory.appendingPathComponent(handle.fileName)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            // A half copy from an earlier attempt must not be mistaken for the finished file.
            try? files.removeItem(at: destination)
            // The link is single-use, so this is sent once. The only repeat is after a 401, which the
            // server gives before it looks at the job at all.
            let path = "/api/export/burn/dl?" + ServerPath.query([("id", handle.id)])
            let response = try await session.download(session.request(path), to: destination) { received, total in
                progress(.downloading(received: received, total: total))
            }
            switch response.status {
            case 200:
                return destination
            case 404:
                // `not ready` or `gone`: the job was taken already, or never finished.
                throw ExportFailure.expired
            default:
                throw ExportFailure.server(response.failureMessage ?? "")
            }
        } catch {
            try? files.removeItem(at: destination)
            try Self.throwExportFailure(error)
        }
    }

    /// `POST /api/export/burn`'s body, in the server's spelling.
    private struct BurnRequest: Encodable {
        let cat: String
        let name: String
        let cams: [String]
        let wm: Bool
        let q: String
        let files: [String]
    }

    /// The server has no Chinese font for the watermark, or no ffmpeg to burn it with; the export
    /// sheet can then offer to go without. Anything else is the server's own explanation.
    private static func refusal(_ message: String) -> ExportFailure {
        message.contains("字体") || message.contains("ffmpeg") ? .watermarkUnavailable : .server(message)
    }

    /// Maps anything thrown during an export to `ExportFailure`, or back to `CancellationError`
    /// when the task was cancelled.
    private static func throwExportFailure(_ error: Error) throws -> Never {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        if let failure = error as? ExportFailure { throw failure }
        if error is UpstreamError { throw ExportFailure.network }
        throw ExportFailure.server(error.localizedDescription)
    }

    // MARK: Helpers

    private static func url(_ session: ServerSession, _ path: String) -> URL {
        ServerSession.url(session.base, path: path)
    }

    private static func httpFailure(_ response: HTTPResponse) -> UpstreamError {
        .http(status: response.status, message: response.failureMessage)
    }
}
