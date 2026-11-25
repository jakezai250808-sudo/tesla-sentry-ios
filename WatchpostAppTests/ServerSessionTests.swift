import Foundation
import Testing
@testable import WatchpostApp

/// `ServerSession`: the cookie on every request, the login-and-retry rule, and nothing else.
struct ServerSessionTests {
    private static let newToken = "1761600000.newnewnewnewnewnewnewnewnewnew"
    private static var oldCookie: String { "tsf_sess=\(Fixtures.token.value)" }
    private static var newCookie: String { "tsf_sess=\(newToken)" }

    private struct Odd: Error {}

    // MARK: Building requests

    @Test func aRequestCarriesTheCookieTheAcceptAndWhatItWasAsked() {
        let session = Fixtures.session(StubTransport([]))
        let request = session.request("/api/events")
        #expect(request.url?.absoluteString == "http://192.168.1.50:8080/api/events")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "*/*")
        #expect(request.value(forHTTPHeaderField: "Cookie") == Self.oldCookie)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.httpBody == nil)

        let post = session.request("/api/export/burn", method: "POST", body: Data("{}".utf8), contentType: "application/json")
        #expect(post.httpMethod == "POST")
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(post.httpBody == Data("{}".utf8))
        #expect(post.value(forHTTPHeaderField: "Cookie") == Self.oldCookie)
        #expect(session.mediaHeaders == ["Cookie": Self.oldCookie])
        #expect(session.hasPassword == false)
        #expect(Fixtures.session(StubTransport([]), password: "").hasPassword == false)
        #expect(Fixtures.session(StubTransport([]), password: "x").hasPassword)
    }

    @Test func theServersPathIsReplacedAndTheQueryKeptAsWritten() {
        let base = URL(string: "https://cam.example.com:8443/sentry/")!
        #expect(ServerSession.url(base, path: "/api/ver").absoluteString == "https://cam.example.com:8443/api/ver")
        #expect(ServerSession.url(base, path: "/media/SentryClips/2026-11-08%2019-43-36/x.mp4?q=480p&exact=1").absoluteString
                == "https://cam.example.com:8443/media/SentryClips/2026-11-08%2019-43-36/x.mp4?q=480p&exact=1")
        #expect(ServerSession.url(base, path: "/api/timeline?event=%E7%89%87%E6%AE%B5&gaps=0").absoluteString
                == "https://cam.example.com:8443/api/timeline?event=%E7%89%87%E6%AE%B5&gaps=0")
        let session = ServerSession(id: UUID(), base: base, password: nil, token: nil, transport: StubTransport([]))
        #expect(session.cookieHeader == nil)
        #expect(session.mediaHeaders == [:])
        #expect(session.request("/api/ver").value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func withoutATokenAStaleCookieOnTheRequestIsNotSent() async throws {
        let transport = StubTransport([.ok()])
        let session = Fixtures.session(transport, token: nil)
        var request = URLRequest(url: Fixtures.base.appendingPathComponent("api/ver"))
        request.setValue("tsf_sess=stale", forHTTPHeaderField: "Cookie")
        _ = try await session.send(request)
        #expect(transport.sent.first?.header("Cookie") == nil)
    }

    @Test func sendLeavesTransportErrorsAsTheyCame() async throws {
        let session = Fixtures.session(StubTransport([.raises(URLError(.notConnectedToInternet)), .raises(Odd())]))
        await #expect(throws: URLError.self) { try await session.send(session.request("/api/ver")) }
        await #expect(throws: Odd.self) { try await session.send(session.request("/api/ver")) }
    }

    // MARK: Logging in

    @Test func aLoginIsAFormWithThePasswordEncodedStrictly() async throws {
        let transport = StubTransport([.loginOK(token: Self.newToken)])
        let session = Fixtures.session(transport)
        let answer = try await session.postLogin(password: "p+ss=w&d 中")
        guard case .token(let token) = answer else {
            Issue.record("Expected a token, got \(answer)")
            return
        }
        #expect(token.value == Self.newToken)
        #expect(token.expiresAt == Date(timeIntervalSince1970: 1_761_600_000))
        // `postLogin` stores nothing.
        #expect(session.token == Fixtures.token)
        let sent = try #require(transport.sent.first)
        #expect(sent.method == "POST")
        #expect(sent.path == "/login")
        #expect(sent.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(sent.header("Accept") == "*/*")
        #expect(sent.header("Cookie") == Self.oldCookie)
        #expect(sent.bodyText == "u=admin&p=p%2Bss%3Dw%26d%20%E4%B8%AD&next=%2F")
    }

    @Test func whatElseALoginCanComeBackWith() async throws {
        let cases: [(StubTransport.Reply, String)] = [
            (.status(401, "用户名或密码不对"), "rejected"),
            (.status(429, "尝试次数过多，请 5 分钟后再试"), "lockedOut"),
            (LoginPage.redirectWithoutCookie, "failed302"),
            (.status(500, "服务端错误"), "failed500"),
        ]
        for (reply, kind) in cases {
            let answer = try await Fixtures.session(StubTransport([reply])).postLogin(password: "x")
            switch (kind, answer) {
            case ("rejected", .rejected):
                break
            case ("lockedOut", .lockedOut(let notice)):
                // The sentence as the server wrote it, and the wait it names.
                #expect(notice == LockoutNotice(message: "尝试次数过多，请 5 分钟后再试", minutes: 5))
            case ("failed302", .failed(let status, let message)):
                #expect(status == 302)
                #expect(message == nil)
            case ("failed500", .failed(let status, let message)):
                #expect(status == 500)
                #expect(message == "服务端错误")
            default:
                Issue.record("\(kind) came back as \(answer)")
            }
        }
    }

    private enum LoginPage {
        /// A 302 whose `Set-Cookie` is missing: the server's way of saying the form was not accepted.
        static let redirectWithoutCookie = StubTransport.Reply.status(302, headers: ["Location": "/login"])
    }

    @Test func aSuccessfulLoginIsStored() async throws {
        let transport = StubTransport([.loginOK(token: Self.newToken)])
        let session = Fixtures.session(transport)
        let token = try await session.login(password: "secret")
        #expect(token.value == Self.newToken)
        #expect(session.token == token)
        #expect(session.cookieHeader == Self.newCookie)
        #expect(session.mediaHeaders == ["Cookie": Self.newCookie])
    }

    @Test func aRefusedLoginIsNamed() async throws {
        let locked = Fixtures.session(StubTransport([.status(429, "尝试次数过多，请 5 分钟后再试")]))
        await #expect(throws: UpstreamError.lockedOut) { try await locked.login(password: "x") }
        let failed = Fixtures.session(StubTransport([.status(500, "服务端错误")]))
        await #expect(throws: UpstreamError.http(status: 500, message: "服务端错误")) { try await failed.login(password: "x") }
        let noCookie = Fixtures.session(StubTransport([LoginPage.redirectWithoutCookie]))
        await #expect(throws: UpstreamError.http(status: 302, message: nil)) { try await noCookie.login(password: "x") }
        let offline = Fixtures.session(StubTransport([.raises(URLError(.timedOut))]))
        await #expect(throws: UpstreamError.network(domain: NSURLErrorDomain, code: URLError.Code.timedOut.rawValue)) {
            try await offline.login(password: "x")
        }
        let odd = Fixtures.session(StubTransport([.raises(Odd())]))
        await #expect(throws: UpstreamError.badResponse) { try await odd.login(password: "x") }
        for session in [locked, failed, noCookie, offline, odd] {
            #expect(session.token == Fixtures.token, "A login that did not work leaves the cookie alone")
        }
        // The lock is remembered with what the server said; the others are not a lock.
        #expect(locked.lockoutNotice == LockoutNotice(message: "尝试次数过多，请 5 分钟后再试", minutes: 5))
        #expect(failed.lockoutNotice == nil)
    }

    /// What the server wrote when it stopped taking tries, read off the page it answers `/login` with
    /// and off a plain sentence alike, with the wait when it is written in minutes.
    @Test(arguments: [
        (#"<html><body><div class="err">尝试次数过多，请 5 分钟后再试</div></body></html>"#, "尝试次数过多，请 5 分钟后再试", 5),
        ("尝试次数过多，请 5 分钟后再试", "尝试次数过多，请 5 分钟后再试", 5),
        (#"<div class="err">Too many attempts. Try again in 10 minutes.</div>"#, "Too many attempts. Try again in 10 minutes.", 10),
        (#"<div class="err">Locked for 5分钟, then retry.</div>"#, "Locked for 5分钟, then retry.", 5),
        (#"<div class="err">Please try again after 2 min.</div>"#, "Please try again in 2 min.", 2),
        (#"<div class="err">Locked &quot;for now&quot; &#8212; 1440 minutes</div>"#, "Locked \"for now\" — 1440 minutes", 1440),
        (#"<div class="err">Please  try again in 30 seconds.</div>"#, "Please try again in 30 seconds.", nil),
        (#"<div class="err">Try again in 2000 minutes.</div>"#, "Try again in 2000 minutes.", nil),
        (#"<div class="err">Too many tries.</div>"#, "Too many tries.", nil),
        (#"<html><body><h1>Login</h1></body></html>"#, nil, nil),
        (#"<div class="err">   </div>"#, nil, nil),
        ("", nil, nil),
    ] as [(String, String?, Int?)])
    func theSentenceAndTheWaitAreReadOffWhatTheServerAnswered(_ body: String, _ message: String?, _ minutes: Int?) {
        #expect(ServerSession.lockoutNotice(in: Data(body.utf8)) == LockoutNotice(message: message, minutes: minutes))
    }

    @Test func theSavedPasswordIsNotTriedTwice() async throws {
        // 1. The saved password is refused by `/login`. 2. A later 401 is answered without asking again.
        let transport = StubTransport([.status(401, "用户名或密码不对"), .unauthorized()])
        let session = Fixtures.session(transport, password: "secret")
        await #expect(throws: UpstreamError.unauthorized) { try await session.login(password: "secret") }
        #expect(session.token == Fixtures.token, "A refused login keeps the cookie it had")
        await #expect(throws: UpstreamError.unauthorized) { try await session.data(for: session.request("/api/events")) }
        #expect(transport.sent.map(\.path) == ["/login", "/api/events"])
        #expect(session.token == Fixtures.token)
    }

    @Test func aNewCookieLetsTheSavedPasswordBeTriedAgain() async throws {
        let transport = StubTransport([.status(401, "no"), .unauthorized(), .loginOK(token: Self.newToken), .ok("{}")])
        let session = Fixtures.session(transport, password: "secret")
        await #expect(throws: UpstreamError.unauthorized) { try await session.login(password: "secret") }
        session.updateToken(nil)
        let response = try await session.data(for: session.request("/api/events"))
        #expect(response.status == 200)
        #expect(transport.sent.map(\.path) == ["/login", "/api/events", "/login", "/api/events"])
        #expect(session.token?.value == Self.newToken)
    }

    @Test func aPasswordThatIsNotTheSavedOneDoesNotStopTheSavedOne() async throws {
        let transport = StubTransport([.status(401, "no"), .unauthorized(), .loginOK(token: Self.newToken), .ok("{}")])
        let session = Fixtures.session(transport, password: "secret")
        await #expect(throws: UpstreamError.unauthorized) { try await session.login(password: "typo") }
        let response = try await session.data(for: session.request("/api/events"))
        #expect(response.status == 200)
        #expect(transport.sent.map(\.path) == ["/login", "/api/events", "/login", "/api/events"])
    }

    // MARK: Sending with the rule

    @Test func withoutAPasswordA401IsJustThat() async throws {
        let session = Fixtures.session(StubTransport([.unauthorized()]), password: nil)
        await #expect(throws: UpstreamError.unauthorized) { try await session.data(for: session.request("/api/events")) }
        #expect(session.token == Fixtures.token, "The cookie is kept: a 401 may be about this one request")
        #expect(session.cookieHeader == Self.oldCookie)
    }

    @Test func a401WithAPasswordMeansOneLoginAndOneRetry() async throws {
        let transport = StubTransport([.unauthorized(), .loginOK(token: Self.newToken), .ok(ServerFixtures.version)])
        let session = Fixtures.session(transport, password: "secret")
        let response = try await session.data(for: session.request("/api/ver"))
        #expect(response.status == 200)
        #expect(transport.sent.map(\.path) == ["/api/ver", "/login", "/api/ver"])
        #expect(transport.sent.map { $0.header("Cookie") } == [Self.oldCookie, Self.oldCookie, Self.newCookie])
        #expect(transport.sent.map(\.method) == ["GET", "POST", "GET"])
        #expect(session.token?.value == Self.newToken)
    }

    @Test func whenTheLoginIsRefusedTheCookieIsDroppedAndTheRequestFails() async throws {
        let transport = StubTransport([.unauthorized(), .status(401, "用户名或密码不对")])
        let session = Fixtures.session(transport, password: "secret")
        await #expect(throws: UpstreamError.unauthorized) { try await session.data(for: session.request("/api/events")) }
        #expect(transport.sent.map(\.path) == ["/api/events", "/login"])
        #expect(session.token == nil)
        #expect(session.cookieHeader == nil)
    }

    @Test func aCookieThatIsRefusedTwiceIsUnauthorized() async throws {
        let transport = StubTransport([.unauthorized(), .loginOK(token: Self.newToken), .unauthorized()])
        let session = Fixtures.session(transport, password: "secret")
        await #expect(throws: UpstreamError.unauthorized) { try await session.data(for: session.request("/api/events")) }
        #expect(transport.sent.map(\.path) == ["/api/events", "/login", "/api/events"])
        // The login worked, so the cookie stays: the refusal is about this request.
        #expect(session.token?.value == Self.newToken)
    }

    @Test func aLockedLoginIsReportedAsSuch() async throws {
        let transport = StubTransport([.unauthorized(), .status(429, "尝试次数过多，请 5 分钟后再试")])
        let session = Fixtures.session(transport, password: "secret")
        await #expect(throws: UpstreamError.lockedOut) { try await session.data(for: session.request("/api/events")) }
        #expect(session.token == nil)
        #expect(session.lockoutNotice == LockoutNotice(message: "尝试次数过多，请 5 分钟后再试", minutes: 5))
    }

    /// Once the server stopped taking tries, nothing asks it for a sign-in until the person does: a
    /// request that needs one is answered as locked without being sent, lock or no cookie. The
    /// person's try (a pull, Retry) is one sign-in more, which can lock it again.
    @Test func aLockedServerIsNotAskedAgainUntilThePersonAsks() async throws {
        let transport = StubTransport([
            .unauthorized(), .status(429, ServerFixtures.lockedOutMessage),
            // The person's try: the cookie is refused once more, and the password is not taken.
            .unauthorized(), .status(429, ServerFixtures.lockedOutMessage),
            // And again: refused, then taken.
            .unauthorized(), .loginOK(token: Self.newToken), .ok("{}"),
        ])
        let session = Fixtures.session(transport, password: "secret")
        await #expect(throws: UpstreamError.lockedOut) { try await session.data(for: session.request("/api/events")) }
        #expect(transport.sent.map(\.path) == ["/api/events", "/login"])

        // The script has no answer for a request here: were one sent, it would not come back as a lock.
        await #expect(throws: UpstreamError.lockedOut) { try await session.data(for: session.request("/api/live")) }
        await #expect(throws: UpstreamError.lockedOut) { try await session.download(session.request("/api/timeline"), to: FileManager.default.temporaryDirectory) { _, _ in } }
        #expect(transport.sent.count == 2)

        session.liftLockout()
        await #expect(throws: UpstreamError.lockedOut) { try await session.data(for: session.request("/api/live")) }
        #expect(transport.sent.map(\.path) == ["/api/events", "/login", "/api/live", "/login"])
        #expect(session.lockoutNotice?.message == ServerFixtures.lockedOutMessage)

        session.liftLockout()
        let response = try await session.data(for: session.request("/api/ver"))
        #expect(response.status == 200)
        #expect(transport.sent.map(\.path) == ["/api/events", "/login", "/api/live", "/login", "/api/ver", "/login", "/api/ver"])
        #expect(session.token?.value == Self.newToken)
        #expect(session.lockoutNotice == nil, "A sign-in that worked ends the lock")
    }

    /// A lock that came from the person's own try (the sign-in-again page) keeps the cookie: the
    /// server refused the password, not the cookie. A request goes out with that cookie, and when it
    /// is refused the answer is the lock, with no sign-in behind the person's back.
    @Test func aLockFromTheSignInAgainPageKeepsTheCookieAndStopsTheAutomaticSignIn() async throws {
        let transport = StubTransport([.status(429, ServerFixtures.lockedOutMessage), .unauthorized()])
        let session = Fixtures.session(transport, password: "secret")
        await #expect(throws: UpstreamError.lockedOut) { try await session.login(password: "typo") }
        #expect(session.token == Fixtures.token)
        await #expect(throws: UpstreamError.lockedOut) { try await session.data(for: session.request("/api/events")) }
        #expect(transport.sent.map(\.path) == ["/login", "/api/events"])
        #expect(session.token == Fixtures.token)
        #expect(transport.sent(to: "/api/events").first?.header("Cookie") == Self.oldCookie)
    }

    /// The wait is the server's, by the phone's clock: one minute short of it nothing is asked, and
    /// once it has passed a request may sign in again.
    @Test func theWaitIsTheOneTheServerNamed() async throws {
        let clock = Box(Date(timeIntervalSince1970: 1_761_500_000))
        let transport = StubTransport([
            .unauthorized(), .status(429, ServerFixtures.lockedOutMessage),
            .unauthorized(), .loginOK(token: Self.newToken), .ok("{}"),
        ])
        let session = ServerSession(id: UUID(), base: Fixtures.base, password: "secret", token: Fixtures.token, transport: transport,
                                    now: { clock.get() })
        await #expect(throws: UpstreamError.lockedOut) { try await session.data(for: session.request("/api/events")) }
        clock.set(clock.get().addingTimeInterval(4 * 60))
        await #expect(throws: UpstreamError.lockedOut) { try await session.data(for: session.request("/api/events")) }
        #expect(transport.sent.map(\.path) == ["/api/events", "/login"])
        #expect(session.lockoutNotice == LockoutNotice(message: ServerFixtures.lockedOutMessage, minutes: 5),
                "After the wait the sentence is still there for a list that failed for it")
        clock.set(clock.get().addingTimeInterval(60))
        let response = try await session.data(for: session.request("/api/events"))
        #expect(response.status == 200)
        #expect(transport.sent.map(\.path) == ["/api/events", "/login", "/api/events", "/login", "/api/events"])
        #expect(session.lockoutNotice == nil)
    }

    /// A server that names no wait is read as locked until the person asks.
    @Test func aLockWithNoWaitLastsUntilThePersonAsks() async throws {
        let clock = Box(Date(timeIntervalSince1970: 1_761_500_000))
        let transport = StubTransport([.unauthorized(), .status(429, "Too many tries."), .unauthorized(), .loginOK(token: Self.newToken), .ok("{}")])
        let session = ServerSession(id: UUID(), base: Fixtures.base, password: "secret", token: Fixtures.token, transport: transport,
                                    now: { clock.get() })
        await #expect(throws: UpstreamError.lockedOut) { try await session.data(for: session.request("/api/events")) }
        #expect(session.lockoutNotice == LockoutNotice(message: "Too many tries.", minutes: nil))
        clock.set(clock.get().addingTimeInterval(3 * 24 * 3_600))
        await #expect(throws: UpstreamError.lockedOut) { try await session.data(for: session.request("/api/events")) }
        #expect(transport.sent.map(\.path) == ["/api/events", "/login"])
        session.liftLockout()
        #expect(try await session.data(for: session.request("/api/events")).status == 200)
    }

    @Test func anythingElseIsReturnedAsItCame() async throws {
        let session = Fixtures.session(StubTransport([.status(500, "busy"), .status(404, #"{"ok": false, "reason": "bad-path"}"#)]))
        #expect(try await session.data(for: session.request("/api/live")).status == 500)
        #expect(try await session.data(for: session.request("/api/telemetry")).status == 404)
    }

    @Test func transportErrorsBecomeUpstreamErrors() async throws {
        let offline = Fixtures.session(StubTransport([.raises(URLError(.timedOut))]))
        await #expect(throws: UpstreamError.network(domain: NSURLErrorDomain, code: URLError.Code.timedOut.rawValue)) {
            try await offline.data(for: offline.request("/api/events"))
        }
        let stopped = Fixtures.session(StubTransport([.raises(CancellationError())]))
        await #expect(throws: UpstreamError.network(domain: NSURLErrorDomain, code: URLError.Code.cancelled.rawValue)) {
            try await stopped.data(for: stopped.request("/api/events"))
        }
        let odd = Fixtures.session(StubTransport([.raises(Odd())]))
        await #expect(throws: UpstreamError.badResponse) { try await odd.data(for: odd.request("/api/events")) }
    }

    @Test func aDownloadLogsInAndRetriesToo() async throws {
        let transport = StubTransport([.unauthorized(), .loginOK(token: Self.newToken), .ok("VIDEO", headers: ["Content-Length": "5"])])
        let session = Fixtures.session(transport, password: "secret")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("watchpost-tests-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        let reports = Box<[(Int64, Int64?)]>([])
        let response = try await session.download(session.request("/api/export/burn/dl?id=x"), to: destination) { received, total in
            reports.update { $0.append((received, total)) }
        }
        #expect(response.status == 200)
        #expect(try String(contentsOf: destination, encoding: .utf8) == "VIDEO")
        #expect(transport.sent.map(\.kind) == [.download, .send, .download])
        #expect(transport.sent.map { $0.header("Cookie") } == [Self.oldCookie, Self.oldCookie, Self.newCookie])
        #expect(reports.get().last?.0 == 5)
        #expect(reports.get().count == 2)
    }

    @Test func onlyOneLoginForManyRequestsThatFoundTheSameStaleCookie() async throws {
        let transport = RoutingTransport(otherwise: .status(500, "unexpected"))
        transport.route("/api/events", .decided { sent in
            sent.header("Cookie") == Self.newCookie ? .ok(#"{"SentryClips": []}"#) : .unauthorized()
        })
        transport.route("/login", .held(.loginOK(token: Self.newToken)))
        let session = Fixtures.session(transport, password: "secret")

        let requests = (0..<3).map { _ in Task { try await session.data(for: session.request("/api/events")) } }
        // All three found the cookie stale; one login is on its way, and the others wait for it.
        #expect(await waitUntil { transport.sent(to: "/api/events").count == 3 && transport.sent(to: "/login").count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.sent(to: "/login").count == 1)
        transport.releaseWaiting()
        for request in requests {
            #expect(try await request.value.status == 200)
        }
        #expect(transport.sent(to: "/login").count == 1)
        #expect(transport.sent(to: "/api/events").count == 6)
        #expect(session.token?.value == Self.newToken)
    }
}
