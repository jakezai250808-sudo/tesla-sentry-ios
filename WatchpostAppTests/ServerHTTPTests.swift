import Foundation
import Testing
@testable import WatchpostApp

/// `HTTPClient` against a real socket on 127.0.0.1: the one transport that talks to the network,
/// for what a stub cannot show (what URLSession makes of a 302, of a body that stops half-way).
struct ServerHTTPTests {
    private static func client() -> HTTPClient { HTTPClient() }

    /// A file path nobody else uses, in a folder of its own.
    private func freshFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("watchpost-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("clip.mp4", isDirectory: false)
    }

    private func removeFolder(of file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private static func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    private func session(on base: URL, password: String? = nil, token: SessionToken? = Fixtures.token,
                         transport: any HTTPTransport = client()) -> ServerSession {
        ServerSession(id: UUID(), base: base, password: password, token: token, transport: transport)
    }

    // MARK: Answers and encoding

    @Test func aHeaderIsFoundWhateverItsCase() {
        let response = HTTPResponse(status: 200, headers: ["set-cookie": "tsf_sess=x.y", "Content-Type": "text/plain"], body: Data("5".utf8))
        #expect(response.value(forHeader: "Set-Cookie") == "tsf_sess=x.y")
        #expect(response.value(forHeader: "SET-COOKIE") == "tsf_sess=x.y")
        #expect(response.value(forHeader: "Location") == nil)
        #expect(response.contentLength == nil)
        #expect(HTTPResponse(status: 200, headers: ["Content-Length": " 123 "], body: Data()).contentLength == 123)
        #expect(HTTPResponse(status: 200, headers: ["Content-Length": "x"], body: Data()).contentLength == nil)
        #expect(HTTPResponse(status: 204, headers: [:], body: Data()).isSuccess)
        #expect(!HTTPResponse(status: 300, headers: [:], body: Data()).isSuccess)
        #expect(!HTTPResponse(status: 199, headers: [:], body: Data()).isSuccess)
    }

    @Test func failureMessagesComeFromTheAnswer() {
        func message(_ status: Int, _ body: String) -> String? {
            HTTPResponse(status: status, headers: [:], body: Data(body.utf8)).failureMessage
        }
        #expect(message(401, " unauthorized \n") == "unauthorized")
        #expect(message(400, #"{"error": "invalid category or event"}"#) == "invalid category or event")
        #expect(message(400, #"{"error": "", "msg": "回退"}"#) == "回退")
        #expect(message(503, "所选画质暂不可用") == "所选画质暂不可用")
        #expect(message(404, "") == nil)
        #expect(message(404, "  \n") == nil)
        // Not text: says nothing.
        #expect(message(404, "\u{FFFD}\u{01FF}") == nil)
        // A long page is cut short.
        #expect(message(502, String(repeating: "x", count: 2_000))?.count == 512)
    }

    @Test func pathsAndQueriesAreEncodedTheWayTheServerDecodesThem() {
        #expect(ServerPath.segment("2026-11-08 19-43-36-front.mp4") == "2026-11-08%2019-43-36-front.mp4")
        #expect(ServerPath.segment("片段-01.mp4") == "%E7%89%87%E6%AE%B5-01.mp4")
        #expect(ServerPath.segment("plain._~-name") == "plain._~-name")
        #expect(ServerPath.segment("a+b&c=d") == "a%2Bb%26c%3Dd")
        #expect(ServerPath.segment("") == "")
        #expect(ServerPath.path("/media/SentryClips/2026-11-08 19-43-36/片段-01.mp4")
                == "/media/SentryClips/2026-11-08%2019-43-36/%E7%89%87%E6%AE%B5-01.mp4")
        #expect(ServerPath.path("/media/x/y.mp4") == "/media/x/y.mp4")
        #expect(ServerPath.queryValue("/archive/SavedClips/x y.mp4") == "/archive/SavedClips/x%20y.mp4")
        #expect(ServerPath.queryValue("p+ss=w&d") == "p%2Bss%3Dw%26d")
        #expect(ServerPath.query([]) == "")
        #expect(ServerPath.query([("a", "x y"), ("b", "1")]) == "a=x%20y&b=1")
    }

    // MARK: Errors

    @Test func transportErrorsBecomeUpstreamErrors() {
        #expect(TransportFailure.upstream(URLError(.notConnectedToInternet)) == .network(domain: NSURLErrorDomain, code: -1009))
        #expect(TransportFailure.upstream(URLError(.timedOut)) == .network(domain: NSURLErrorDomain, code: URLError.Code.timedOut.rawValue))
        #expect(TransportFailure.upstream(CancellationError()) == .network(domain: NSURLErrorDomain, code: URLError.Code.cancelled.rawValue))
        struct Odd: Error {}
        #expect(TransportFailure.upstream(Odd()) == .badResponse)
    }

    @Test func connectingFailuresAreNamedByWhatWentWrongAndWhere() {
        let box = URL(string: "http://192.168.1.50:8080")!
        let far = URL(string: "https://cam.example.com")!
        let refused = URLError(.cannotConnectToHost)
        #expect(TransportFailure.connectFailure(refused, base: box) == .localNetworkUnreachable)
        #expect(TransportFailure.connectFailure(refused, base: far) == .unreachable)
        #expect(TransportFailure.connectFailure(URLError(.networkConnectionLost), base: box) == .localNetworkUnreachable)
        #expect(TransportFailure.connectFailure(URLError(.notConnectedToInternet), base: box) == .localNetworkUnreachable)
        #expect(TransportFailure.connectFailure(URLError(.timedOut), base: far) == .unreachable)
        #expect(TransportFailure.connectFailure(URLError(.serverCertificateUntrusted), base: box) == .certificateRejected)
        #expect(TransportFailure.connectFailure(URLError(.secureConnectionFailed), base: far) == .certificateRejected)
        #expect(TransportFailure.connectFailure(URLError(.badServerResponse), base: box) == .unreachable)
        #expect(TransportFailure.connectFailure(URLError(.cancelled), base: box) == .unreachable)
        #expect(TransportFailure.connectFailure(CancellationError(), base: box) == .cancelled)
        struct Odd: Error {}
        #expect(TransportFailure.connectFailure(Odd(), base: box) == .unreachable)
    }

    @Test func theConfigurationKeepsNothingAndWaitsForNothing() {
        let configuration = HTTPClient.makeConfiguration()
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.connectionProxyDictionary?.isEmpty == true)
        #expect(configuration.timeoutIntervalForRequest == 30)
        #expect(configuration.httpMaximumConnectionsPerHost == 4)
    }

    // MARK: Through a socket

    @Test func aRequestGoesOutAsBuiltAndTheAnswerComesBackWhole() async throws {
        let server = try LoopbackServer { request in
            switch request.target {
            case "/api/ver": .json(ServerFixtures.version)
            case "/api/events": .json(#"{"SentryClips": [], "SavedClips": [], "RecentClips": []}"#, status: 200)
            default: .text(404, "not found")
            }
        }
        defer { server.stop() }
        let session = session(on: server.url)
        let response = try await session.data(for: session.request("/api/ver"))
        #expect(response.status == 200)
        #expect(response.value(forHeader: "Content-Type") == "application/json")
        #expect(response.value(forHeader: "Cache-Control")?.hasPrefix("no-store") == true)
        #expect(Wire.version(JSONValue(data: response.body)) == "2.8.45")

        let sent = try #require(server.requests.first)
        #expect(sent.method == "GET")
        #expect(sent.target == "/api/ver")
        #expect(sent.header("Accept") == "*/*")
        #expect(sent.header("Cookie") == "tsf_sess=\(Fixtures.token.value)")
        #expect(sent.body.isEmpty)
    }

    @Test func aRedirectIsAnAnswerNotFollowed() async throws {
        let server = try LoopbackServer { request in
            switch request.target {
            case "/": LoopbackResponse(302, headers: [("Location", "/elsewhere"), ("Content-Type", "text/html; charset=utf-8")], body: Data("login page".utf8))
            case "/elsewhere": .text(200, "followed")
            default: .text(404, "not found")
            }
        }
        defer { server.stop() }
        // The gate's answer to a page: a 302 to the login page. It must arrive as an answer, so the app can tell it from a missing box.
        let request = session(on: server.url).request("/", method: "GET")
        let response = try await Self.client().send(request)
        #expect(response.status == 302)
        #expect(response.value(forHeader: "Location") == "/elsewhere")
        #expect(String(decoding: response.body, as: UTF8.self) == "login page")
        #expect(server.requests.map(\.target) == ["/"])
    }

    @Test func aPostCarriesItsBodyAndItsType() async throws {
        let server = try LoopbackServer { request in
            .text(200, "got \(request.method) \(String(decoding: request.body, as: UTF8.self)) as \(request.header("Content-Type") ?? "-")")
        }
        defer { server.stop() }
        let session = session(on: server.url)
        let form = "u=admin&p=secret&next=%2F"
        let response = try await session.data(for: session.request("/login", method: "POST", body: Data(form.utf8),
                                                                       contentType: "application/x-www-form-urlencoded"))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "got POST \(form) as application/x-www-form-urlencoded")
    }

    @Test func aDownloadPutsTheWholeFileInPlace() async throws {
        let body = Self.bytes(300 * 1024)
        let server = try LoopbackServer { _ in
            LoopbackResponse(200, headers: [("Content-Type", "video/mp4")], body: body)
        }
        defer { server.stop() }
        let destination = freshFile()
        defer { removeFolder(of: destination) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A half copy from an earlier attempt is replaced, not appended to.
        try Data("HALF".utf8).write(to: destination)

        let reports = Box<[(Int64, Int64?)]>([])
        let response = try await Self.client().download(session(on: server.url).request("/api/export/burn/dl?id=x"),
                                                        to: destination) { received, total in reports.update { $0.append((received, total)) } }
        #expect(response.status == 200)
        #expect(response.body.isEmpty)
        #expect(try Data(contentsOf: destination) == body)
        let seen = reports.get()
        #expect(seen.count >= 1)
        #expect(seen.last?.0 == Int64(body.count))
        #expect(seen.last?.1 == Int64(body.count))
        #expect(seen.allSatisfy { $0.0 <= Int64(body.count) && $0.1 == Int64(body.count) })
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.0 <= $1.0 })
        let folder = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        #expect(folder == ["clip.mp4"])
        #expect(server.requests.first?.method == "GET")
    }

    @Test(arguments: [404, 503])
    func aRefusalLeavesTheFileAloneAndKeepsItsWords(_ status: Int) async throws {
        let server = try LoopbackServer { _ in .text(status, "所选画质暂不可用") }
        defer { server.stop() }
        let destination = freshFile()
        defer { removeFolder(of: destination) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("KEEP".utf8).write(to: destination)

        let response = try await Self.client().download(session(on: server.url).request("/api/export/burn/dl?id=x"), to: destination) { _, _ in }
        #expect(response.status == status)
        #expect(response.failureMessage == "所选画质暂不可用")
        #expect(try Data(contentsOf: destination) == Data("KEEP".utf8))
        let folder = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        #expect(folder == ["clip.mp4"])
    }

    @Test func aDownloadThatIsCutOffFailsAndLeavesNothingBehind() async throws {
        let server = try LoopbackServer { _ in
            LoopbackResponse(200, headers: [("Content-Type", "video/mp4")], body: Self.bytes(200 * 1024), cutoff: 50 * 1024)
        }
        defer { server.stop() }
        let destination = freshFile()
        defer { removeFolder(of: destination) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) {
            try await Self.client().download(session(on: server.url).request("/media/x.mp4"), to: destination) { _, _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let folder = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        #expect(folder.isEmpty)
    }

    @Test func aLongDownloadReportsAsItGoes() async throws {
        let body = Self.bytes(200 * 1024)
        let server = try LoopbackServer { _ in
            LoopbackResponse(200, headers: [("Content-Type", "video/mp4")], body: body, pauseMicros: 300_000)
        }
        defer { server.stop() }
        let destination = freshFile()
        defer { removeFolder(of: destination) }

        let reports = Box<[(Int64, Int64?)]>([])
        let response = try await Self.client().download(session(on: server.url).request("/media/x.mp4"), to: destination) { received, total in
            reports.update { $0.append((received, total)) }
        }
        #expect(response.status == 200)
        #expect(try Data(contentsOf: destination) == body)
        let seen = reports.get()
        // Four chunks of 64 KB with a third of a second between them: seen on the way, not only at the end.
        #expect(seen.count >= 2)
        #expect((seen.first?.0 ?? Int64.max) < Int64(body.count))
        #expect(seen.last?.0 == Int64(body.count))
        #expect(seen.last?.1 == Int64(body.count))
    }

    @Test func aRefusedConnectionIsNamedAfterWhereTheBoxIs() async throws {
        let port = try LoopbackServer.unusedPort()
        let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
        do {
            _ = try await Self.client().send(URLRequest(url: base))
            Issue.record("Nothing listens on that port; the connection should have been refused")
        } catch {
            #expect(error is URLError)
            #expect(TransportFailure.connectFailure(error, base: base) == .localNetworkUnreachable)
        }
    }

    // MARK: The gate, through the real client

    /// The server's gate as the notes describe it: `/api/ver` is open, everything else wants the cookie.
    private static let newCookie = "tsf_sess=1761600000.newnewnewnewnewnewnewnewnewnew"

    private static func gatedServer() throws -> LoopbackServer {
        try LoopbackServer { request in
            switch request.target {
            case "/api/ver":
                return .json(ServerFixtures.version)
            case "/api/auth/info":
                return request.header("Cookie") == Self.newCookie ? .json(ServerFixtures.authInfoOn) : .unauthorized()
            case "/login":
                guard request.method == "POST", request.header("Content-Type") == "application/x-www-form-urlencoded",
                      let body = String(data: request.body, encoding: .utf8) else { return .text(400, "bad form") }
                if body.contains("p=right") {
                    return LoopbackResponse(302, headers: [("Location", "/"), ("Set-Cookie", "tsf_sess=1761600000.newnewnewnewnewnewnewnewnewnew; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax")])
                }
                return .text(body.contains("p=wrong") ? 401 : 400, "用户名或密码不对")
            case "/api/events":
                return request.header("Cookie") == Self.newCookie
                    ? .json(#"{"SentryClips": [], "SavedClips": [], "RecentClips": []}"#)
                    : .unauthorized()
            default:
                return .text(404, "not found")
            }
        }
    }

    @Test func theSessionLogsInOnceAndRetriesThroughTheRealClient() async throws {
        let server = try Self.gatedServer()
        defer { server.stop() }
        let session = session(on: server.url, password: "right", token: nil)
        let response = try await session.data(for: session.request("/api/events"))
        #expect(response.status == 200)
        #expect(session.token?.value == "1761600000.newnewnewnewnewnewnewnewnewnew")
        #expect(session.token?.expiresAt == Date(timeIntervalSince1970: 1_761_600_000))
        #expect(server.requests.map(\.target) == ["/api/events", "/login", "/api/events"])
        #expect(server.requests.last?.header("Cookie") == Self.newCookie)
    }

    @Test func connectGetsInThroughTheRealClient() async throws {
        let server = try Self.gatedServer()
        defer { server.stop() }
        let outcome = try await ServerConnection.connect(base: server.url, password: "right", token: nil, transport: Self.client())
        #expect(outcome.version == "2.8.45")
        #expect(outcome.token?.value == "1761600000.newnewnewnewnewnewnewnewnewnew")
        #expect(outcome.requiresPassword)
        #expect(server.requests.map(\.target) == ["/api/ver", "/api/auth/info", "/login"])
        #expect(server.requests.allSatisfy { $0.header("Accept") == "*/*" })
        #expect(server.requests[2].body == Data("u=admin&p=right&next=%2F".utf8))
    }

    @Test func connectIsRefusedThroughTheRealClientToo() async throws {
        let server = try Self.gatedServer()
        defer { server.stop() }
        await #expect(throws: ConnectFailure.credentialsRejected) {
            try await ServerConnection.connect(base: server.url, password: "wrong", token: nil, transport: Self.client())
        }
        #expect(server.requests.map(\.target) == ["/api/ver", "/api/auth/info", "/login"])
    }
}

private extension LoopbackResponse {
    static func unauthorized() -> LoopbackResponse { .text(401, "unauthorized") }
}
