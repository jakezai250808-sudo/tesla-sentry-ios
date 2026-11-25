import Foundation
import Testing
@testable import WatchpostApp

// Helpers shared by the networking tests: a transport that answers from a
// script instead of the network, a lock-box for values a `@Sendable` closure
// has to hand back, bodies in the server's own spelling, and the folder of
// one test's exports.

/// Answers HTTP from a script and remembers every request it was asked.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    enum Reply: Sendable {
        case status(Int, headers: [String: String], body: String)
        case raises(any Error)

        static func ok(_ body: String = "", headers: [String: String] = [:]) -> Reply {
            .status(200, headers: headers, body: body)
        }

        static func status(_ code: Int, _ body: String = "", headers: [String: String] = [:]) -> Reply {
            .status(code, headers: headers, body: body)
        }

        /// The gate's answer to a request without a usable cookie.
        static func unauthorized() -> Reply { .status(401, "unauthorized", headers: ["Content-Type": "text/plain; charset=utf-8"]) }

        /// A successful login as the server gives it.
        static func loginOK(token: String = "1761600000.ffffffffffffffffffffffffffffffff") -> Reply {
            .status(302, headers: [
                "Location": "/",
                "Set-Cookie": "tsf_sess=\(token); Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax",
            ])
        }
    }

    struct Sent: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case send
            case download
        }

        let kind: Kind
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data

        /// The path, decoded.
        var path: String { url.path }
        /// The path as it goes on the wire.
        var encodedPath: String { url.path(percentEncoded: true) }
        /// The query as it goes on the wire, percent-encoding kept.
        var query: String? { url.query(percentEncoded: true) }
        var decodedQuery: String? { url.query(percentEncoded: false) }
        var bodyText: String { String(decoding: body, as: UTF8.self) }
        /// The JSON body (`.null` when there is none).
        var json: JSONValue { JSONValue(data: body) }

        func header(_ name: String) -> String? {
            if let value = headers[name] { return value }
            let wanted = name.lowercased()
            return headers.first { $0.key.lowercased() == wanted }?.value
        }
    }

    /// Thrown when the script runs out: a test that asked for more than it scripted fails loudly, not silently.
    struct OutOfReplies: Error {}

    private let lock = NSLock()
    private var script: [Reply]
    private let endless: Reply?
    private var recorded: [Sent] = []
    private var failure: (bytes: Int, error: any Error)?

    init(_ script: [Reply]) {
        self.script = script
        endless = nil
    }

    /// The same answer forever.
    init(endless reply: Reply) {
        script = []
        endless = reply
    }

    /// Makes `download` write `bytes` bytes and then fail, like a connection that drops.
    func failDownload(afterBytes bytes: Int, with error: any Error) {
        lock.withLock { failure = (bytes, error) }
    }

    var sent: [Sent] { lock.withLock { recorded } }

    func sent(to path: String) -> [Sent] { sent.filter { $0.path == path } }

    private func record(_ kind: Sent.Kind, _ request: URLRequest) {
        let entry = Sent(kind: kind, url: request.url ?? URL(string: "about:blank")!, method: request.httpMethod ?? "GET",
                         headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody ?? Data())
        lock.withLock { recorded.append(entry) }
    }

    private func next() throws -> Reply {
        try lock.withLock {
            if let endless { return endless }
            guard !script.isEmpty else { throw OutOfReplies() }
            return script.removeFirst()
        }
    }

    private func response(to reply: Reply) throws -> HTTPResponse {
        switch reply {
        case .status(let status, let headers, let body):
            HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
        case .raises(let error):
            throw error
        }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        record(.send, request)
        return try response(to: next())
    }

    /// Writes the body in two halves so progress is seen twice, as the real client reports every chunk.
    func download(_ request: URLRequest, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> HTTPResponse {
        record(.download, request)
        let reply = try next()
        guard case .status(let status, let headers, let body) = reply else { return try response(to: reply) }
        let bytes = Data(body.utf8)
        guard (200..<300).contains(status) else { return HTTPResponse(status: status, headers: headers, body: bytes) }

        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard files.createFile(atPath: destination.path, contents: nil) else { throw URLError(.cannotCreateFile) }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let total = headers.first { $0.key.lowercased() == "content-length" }.flatMap { Int64($0.value) }
        let cut = bytes.count / 2
        let planned = lock.withLock { failure }
        try handle.write(contentsOf: bytes.prefix(cut))
        progress(Int64(cut), total)
        if let planned, cut >= planned.bytes {
            throw planned.error
        }
        try handle.write(contentsOf: bytes.suffix(from: cut))
        progress(Int64(bytes.count), total)
        return HTTPResponse(status: status, headers: headers, body: Data())
    }
}

/// A value that several tasks can read and write.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value { lock.withLock { value } }

    func set(_ newValue: Value) { lock.withLock { value = newValue } }

    func update<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

/// Waits until `condition` holds, for work that is deliberately fire-and-forget.
func waitUntil(timeout: Duration = .seconds(2), _ condition: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await clock.sleep(for: .milliseconds(10))
    }
    return condition()
}

enum FixtureError: Error {
    /// A test's JSON text does not parse.
    case notJSON(String)
}

/// The export folder of one test. Every test that exports makes its own, under a name nothing
/// else has, so that tests running side by side do not take each other's files away.
/// `remove()` takes that folder and nothing of anyone else's.
struct OwnExports: Sendable {
    /// The folder this test has to itself; the files go in a `WatchpostExports` inside it, as in the app.
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchpostExportTests/\(UUID().uuidString)", isDirectory: true)
    }

    /// What a `ServerClipSource` is given as its export folder.
    var directory: URL { root.appendingPathComponent("WatchpostExports", isDirectory: true) }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

enum Fixtures {
    static let base = URL(string: "http://192.168.1.50:8080")!

    /// A cookie as the server signs it: `<exp>.<32 hex>`, a month from now.
    static let token = SessionToken(value: "1761500000.0123456789abcdef0123456789abcdef",
                                    expiresAt: Date(timeIntervalSince1970: 1761500000))
    static let cookie = "tsf_sess=1761500000.0123456789abcdef0123456789abcdef"

    static let event = "2026-11-08_19-43-36"

    /// `/api/events` with one event in each category. The DriveClips trip is the server's too, and is not shown.
    static let eventsJSON = """
        {
          "SentryClips": [
            {"name": "2026-11-08_19-43-36",
             "videos": [
               {"url": "/media/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-front.mp4", "cam": "front", "f": "2026-11-08_19-43-36-front.mp4"},
               {"url": "/media/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-left_pillar.mp4", "cam": "left_pillar", "f": "2026-11-08_19-43-36-left_pillar.mp4"}
             ],
             "size": 73400320,
             "meta": {"reason": "sentry_aware_object_detection", "camera": "0", "timestamp": "2026-11-08T19:43:40",
                      "city": "上海", "street": "南京西路", "est_lat": 31.2304, "est_lon": 121.4737},
             "locked": false, "lock_unknown": false}
          ],
          "SavedClips": [
            {"name": "2026-11-07_08-15-00",
             "videos": [
               {"url": "/media/SavedClips/2026-11-07_08-15-00/2026-11-07_08-15-00-front.mp4", "cam": "front", "f": "2026-11-07_08-15-00-front.mp4"}
             ],
             "size": 36700160, "meta": {"reason": "user_interaction_dashcam_saved", "timestamp": "2026-11-07T08:15:12"},
             "locked": true, "lock_unknown": false}
          ],
          "RecentClips": [
            {"name": "2026-11-08_20-01-00",
             "videos": [
               {"url": "/media/RecentClips/2026-11-08_20-01-00/2026-11-08_20-01-00-back.mp4", "cam": "back", "f": "2026-11-08_20-01-00-back.mp4"}
             ],
             "size": 36700160, "meta": {}, "locked": false, "lock_unknown": true}
          ],
          "DriveClips": [
            {"name": "2026-11-06_09-00-00",
             "videos": [
               {"url": "/media/DriveClips/2026-11-06_09-00-00/2026-11-06_09-00-00-front.mp4", "cam": "front", "f": "2026-11-06_09-00-00-front.mp4"}
             ],
             "size": 36700160, "meta": {}, "clips": ["2026-11-06_09-00-00"], "locked": false, "lock_unknown": false, "end": "2026-11-06_09-00-00"}
          ]
        }
        """

    /// `/api/timeline?cat=SentryClips&event=…`: the sentry event above, with each clip's length.
    static let timelineJSON = """
        [
          {"name": "2026-11-08_19-43-36",
           "videos": [
             {"url": "/media/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-front.mp4", "cam": "front", "f": "2026-11-08_19-43-36-front.mp4",
              "duration": 59.6, "revision": "36700160:1731075820000000000"},
             {"url": "/media/SentryClips/2026-11-08_19-43-36/2026-11-08_19-43-36-left_pillar.mp4", "cam": "left_pillar", "f": "2026-11-08_19-43-36-left_pillar.mp4",
              "duration": null, "revision": "36700160:1731075820000000000"}
           ],
           "size": 73400320,
           "meta": {"reason": "sentry_aware_object_detection", "camera": "0", "timestamp": "2026-11-08T19:43:40",
                    "city": "上海", "street": "南京西路", "est_lat": 31.2304, "est_lon": 121.4737},
           "locked": false, "lock_unknown": false}
        ]
        """

    static func video(_ camera: Camera = .front, event: String = event, category: String = "SentryClips",
                      minute: String = "2026-11-08_19-43-36") -> ClipVideo {
        let file = "\(minute)-\(camera.rawValue).mp4"
        return ClipVideo(file: file, camera: camera, path: "/media/\(category)/\(event)/\(file)", duration: nil)
    }

    /// The sentry event of `eventsJSON`, as the app reads it. The list is newest first, so it is not the first one.
    static var events: [RecordedEvent] {
        Wire.recordedEvents(fromEvents: json(eventsJSON))
    }

    static var sentryEvent: RecordedEvent {
        events.first { $0.id == "SentryClips/\(event)" }!
    }

    static var savedEvent: RecordedEvent {
        events.first { $0.category == .saved }!
    }

    static var recentEvent: RecordedEvent {
        events.first { $0.category == .recent }!
    }

    /// A JSON body as the server would send it. Fails the test when the text is not JSON.
    static func body(_ text: String) -> Data {
        let data = Data(text.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            Issue.record("Fixture is not JSON: \(text)")
            return data
        }
        return data
    }

    static func json(_ text: String) -> JSONValue {
        JSONValue(data: body(text))
    }

    /// A session that holds the test cookie over this transport.
    static func session(_ transport: any HTTPTransport, password: String? = nil, token: SessionToken? = token) -> ServerSession {
        ServerSession(id: UUID(), base: base, password: password, token: token, transport: transport)
    }

    /// A clip source over a session with no waiting at all between two looks at a transcode.
    /// `exports` is where the finished export of this test goes; without it the app's folder is used.
    static func source(_ transport: any HTTPTransport, password: String? = nil, pollInterval: Duration = .milliseconds(5),
                       maxPolls: Int = 3, clientID: String = "0123456789abcdef0123456789abcdef",
                       exports: OwnExports? = nil) -> ServerClipSource {
        ServerClipSource(session: session(transport, password: password), pollInterval: pollInterval, maxPolls: maxPolls,
                         clientID: clientID, exportsDirectory: exports?.directory)
    }

    /// Collects what an upgrade stream has to say, until it ends.
    static func upgrades(of plan: PlaybackPlan) async -> [PlaybackUpgrade] {
        var values: [PlaybackUpgrade] = []
        for await value in plan.upgrades { values.append(value) }
        return values
    }
}

/// Waits until `condition` holds for something on the main actor: a model that moves on its own.
@MainActor
func settle(timeout: Duration = .seconds(3), until condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !(condition()), clock.now < deadline {
        try? await clock.sleep(for: .milliseconds(5))
    }
    return condition()
}
