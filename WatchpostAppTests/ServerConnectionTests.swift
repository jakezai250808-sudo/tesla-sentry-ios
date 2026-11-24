import Foundation
import Testing
@testable import WatchpostApp

/// `ServerConnection.connect`: is it the server, and do we get in?
struct ServerConnectionTests {
    private static let newToken = "1761600000.newnewnewnewnewnewnewnewnewnew"
    private static var cookie: String { "tsf_sess=\(Fixtures.token.value)" }

    private func connect(_ transport: StubTransport, password: String? = "secret", token: SessionToken? = Fixtures.token,
                         base: URL = Fixtures.base) async throws -> ServerConnection.Outcome {
        try await ServerConnection.connect(base: base, password: password, token: token, transport: transport)
    }

    private func expect(_ outcome: ServerConnection.Outcome, version: String = "2.8.45", token: SessionToken?,
                        requiresPassword: Bool) {
        #expect(outcome.version == version)
        #expect(outcome.token == token)
        #expect(outcome.requiresPassword == requiresPassword)
    }

    // MARK: Getting in

    @Test func anOpenServerNeedsNoCookieAndKeepsNone() async throws {
        let transport = StubTransport([.ok(ServerFixtures.version), .ok(ServerFixtures.authInfoOff)])
        let outcome = try await connect(transport, password: nil)
        expect(outcome, token: nil, requiresPassword: false)
        #expect(transport.sent.map(\.path) == ["/api/ver", "/api/auth/info"])
        // The cookie we had went along, to be told it is not needed.
        #expect(transport.sent.map { $0.header("Cookie") } == [Self.cookie, Self.cookie])
        #expect(transport.sent.allSatisfy { $0.method == "GET" && $0.header("Accept") == "*/*" && $0.body.isEmpty })
    }

    @Test func aGatedServerThatTakesTheCookieKeepsIt() async throws {
        let transport = StubTransport([.ok(ServerFixtures.version), .ok(ServerFixtures.authInfoOn)])
        let outcome = try await connect(transport, password: nil)
        expect(outcome, token: Fixtures.token, requiresPassword: true)
        #expect(transport.sent.map(\.path) == ["/api/ver", "/api/auth/info"])
    }

    @Test func aGatedServerThatWantsALoginGetsOne() async throws {
        let transport = StubTransport([.ok(ServerFixtures.version), .unauthorized(), .loginOK(token: Self.newToken)])
        let outcome = try await connect(transport, token: nil)
        expect(outcome, token: SessionToken(value: Self.newToken, expiresAt: Date(timeIntervalSince1970: 1_761_600_000)),
               requiresPassword: true)
        #expect(transport.sent.map(\.path) == ["/api/ver", "/api/auth/info", "/login"])
        #expect(transport.sent.last?.method == "POST")
        #expect(transport.sent.last?.bodyText == "u=admin&p=secret&next=%2F")
        #expect(transport.sent.last?.header("Cookie") == nil, "No cookie yet when the first login goes out")
    }

    @Test(arguments: [nil, ""])
    func aGatedServerWithNoPasswordMeansCredentialsRefused(_ password: String?) async throws {
        let transport = StubTransport([.ok(ServerFixtures.version), .unauthorized()])
        await #expect(throws: ConnectFailure.credentialsRejected) { try await connect(transport, password: password, token: nil) }
        #expect(transport.sent.map(\.path) == ["/api/ver", "/api/auth/info"])
    }

    @Test func aGatedServerWithACookieAndNoPassword() async throws {
        // The cookie is refused and there is no password to replace it with.
        let transport = StubTransport([.ok(ServerFixtures.version), .unauthorized()])
        await #expect(throws: ConnectFailure.credentialsRejected) { try await connect(transport, password: nil) }
        #expect(transport.sent.map(\.path) == ["/api/ver", "/api/auth/info"])
    }

    struct LoginAnswerCase: Sendable {
        let reply: StubTransport.Reply
        let failure: ConnectFailure
        let what: String
    }

    @Test(arguments: [
        LoginAnswerCase(reply: .status(401, "用户名或密码不对"), failure: .credentialsRejected, what: "wrong password"),
        LoginAnswerCase(reply: .status(429, "尝试次数过多，请 5 分钟后再试"), failure: .lockedOut, what: "locked out"),
        LoginAnswerCase(reply: .status(500, "服务端错误"), failure: .server(status: 500), what: "server error"),
        LoginAnswerCase(reply: .status(302, headers: ["Location": "/"]), failure: .server(status: 302), what: "302 without a cookie"),
    ])
    func whatALoginCanComeBackWith(_ answer: LoginAnswerCase) async throws {
        let transport = StubTransport([.ok(ServerFixtures.version), .unauthorized(), answer.reply])
        await #expect(throws: answer.failure, "\(answer.what)") { try await connect(transport, token: nil) }
        #expect(transport.sent.map(\.path) == ["/api/ver", "/api/auth/info", "/login"])
    }

    @Test(arguments: [403, 404, 500, 503])
    func anAuthInfoThatFailsIsTheServersStatus(_ status: Int) async throws {
        let transport = StubTransport([.ok(ServerFixtures.version), .status(status, "nope")])
        await #expect(throws: ConnectFailure.server(status: status)) { try await connect(transport) }
        #expect(transport.sent.map(\.path) == ["/api/ver", "/api/auth/info"])
    }

    @Test func anAuthInfoThatDoesNotSayTrustsTheCookie() async throws {
        let withCookie = StubTransport([.ok(ServerFixtures.version), .ok("{}")])
        expect(try await connect(withCookie, password: nil), token: Fixtures.token, requiresPassword: true)

        let withoutCookie = StubTransport([.ok(ServerFixtures.version), .ok("{}")])
        expect(try await connect(withoutCookie, password: nil, token: nil), token: nil, requiresPassword: false)
    }

    // MARK: Not the server

    @Test(arguments: [
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>login</body></html>",
        #"{"v": ""}"#, "{}", "[]", "2.8.45",
    ])
    func anythingWithoutAVersionIsNotTheServer(_ body: String) async throws {
        let transport = StubTransport([.ok(body)])
        await #expect(throws: ConnectFailure.incompatibleServer) { try await connect(transport) }
        #expect(transport.sent.map(\.path) == ["/api/ver"], "Nothing else is asked of something that is not the server")
    }

    @Test(arguments: [201, 302, 400, 404, 500])
    func aVersionThatIsNot200IsNotTheServer(_ status: Int) async throws {
        let transport = StubTransport([.status(status, ServerFixtures.version)])
        await #expect(throws: ConnectFailure.incompatibleServer) { try await connect(transport) }
        #expect(transport.sent.map(\.path) == ["/api/ver"])
    }

    @Test(arguments: ["ftp://box.local", "http:///api/ver", "mailto:a@b.c", "//box.local"])
    func anAddressThatIsNotOneSaysSo(_ text: String) async throws {
        let base = try #require(URL(string: text))
        let transport = StubTransport([])
        await #expect(throws: ConnectFailure.invalidAddress(.notAnAddress)) { try await connect(transport, base: base) }
        #expect(transport.sent.isEmpty)
    }

    // MARK: Nothing answers

    @Test(arguments: ["/api/ver", "/api/auth/info"])
    func aBoxThatCannotBeReachedIsNamedByWhereItIs(_ path: String) async throws {
        let refused = URLError(.cannotConnectToHost)
        let script: [StubTransport.Reply] = path == "/api/ver" ? [.raises(refused)] : [.ok(ServerFixtures.version), .raises(refused)]
        let transport = StubTransport(script)
        await #expect(throws: ConnectFailure.localNetworkUnreachable) { try await connect(transport) }
        let far = StubTransport(script)
        await #expect(throws: ConnectFailure.unreachable) { try await connect(far, base: URL(string: "https://cam.example.com")!) }
        #expect(transport.sent.map(\.path).last == path)
    }

    @Test func aCertificateNoOneTrustedIsNamed() async throws {
        let transport = StubTransport([.raises(URLError(.serverCertificateUntrusted))])
        await #expect(throws: ConnectFailure.certificateRejected) { try await connect(transport) }
        let expired = StubTransport([.raises(URLError(.serverCertificateHasBadDate))])
        await #expect(throws: ConnectFailure.certificateRejected) {
            try await connect(expired, base: URL(string: "https://cam.example.com")!)
        }
    }

    @Test func otherFailuresAreJustUnreachable() async throws {
        struct Odd: Error {}
        for error in [URLError(.badServerResponse), URLError(.cancelled), Odd()] as [any Error] {
            let transport = StubTransport([.raises(error)])
            await #expect(throws: ConnectFailure.unreachable) { try await connect(transport) }
        }
    }

    @Test func aCancelledConnectIsCancelled() async throws {
        let transport = StubTransport([.raises(CancellationError())])
        await #expect(throws: ConnectFailure.cancelled) { try await connect(transport) }
        // Also when the task is already cancelled and the transport says something else.
        let other = StubTransport([.raises(URLError(.cancelled))])
        let task = Task { try await connect(other) }
        task.cancel()
        guard case .failure(let error) = await task.result else {
            Issue.record("A cancelled connect must not succeed")
            return
        }
        #expect(error as? ConnectFailure == .cancelled)
    }
}
