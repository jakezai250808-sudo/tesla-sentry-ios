import Foundation
import os

// One saved server's session: where it is, the cookie that gets requests
// through its gate, and the password to get a new cookie when the old one is
// refused. Requests are built and sent from here so that the cookie, the
// `Accept` header and the login-and-retry rule are decided in one place.

/// What `POST /login` came back with, before it is turned into an error.
enum LoginAnswer {
    case token(SessionToken)
    /// 401: the password is wrong.
    case rejected
    /// 429: too many wrong attempts; the server locks this address for a while, and says how long
    /// on the page it answers with.
    case lockedOut(LockoutNotice)
    case failed(status: Int, message: String?)
}

final class ServerSession: Sendable {
    let id: UUID
    let base: URL
    /// The admin password, when the person chose to save it.
    let password: String?
    let transport: any HTTPTransport

    private struct State: Sendable {
        var token: SessionToken?
        /// Counts every token change, so a request that left with an old cookie can tell.
        var revision = 0
        /// The saved password was refused. It is not tried again on this session: eight wrong
        /// attempts in ten minutes lock the server for the whole phone.
        var passwordRejected = false
        /// The server stopped taking tries (429). Until `until`, or for good when the server named
        /// no wait, a refused cookie is reported as `.lockedOut` and no `POST /login` is made unless
        /// the person asks for that try (`liftLockout()`): a saved password that no longer works
        /// must not keep the server locked for the whole phone.
        var lockout: (notice: LockoutNotice, until: Date?)?
    }
    private let state: OSAllocatedUnfairLock<State>
    private let logins = LoginGate()
    private let now: @Sendable () -> Date

    init(id: UUID, base: URL, password: String?, token: SessionToken?, transport: any HTTPTransport,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.id = id
        self.base = base
        self.password = password
        self.transport = transport
        self.now = now
        state = OSAllocatedUnfairLock(initialState: State(token: token))
    }

    var token: SessionToken? { state.withLock { $0.token } }
    var hasPassword: Bool { !(password ?? "").isEmpty }
    var cookieHeader: String? { token.map { "tsf_sess=\($0.value)" } }
    /// For AVURLAsset and image loads.
    var mediaHeaders: [String: String] { cookieHeader.map { ["Cookie": $0] } ?? [:] }

    func updateToken(_ token: SessionToken?) {
        state.withLock { current in
            current.token = token
            current.revision += 1
            current.passwordRejected = false
            current.lockout = nil
        }
    }

    /// What the server said when it last stopped taking tries. It stays until a sign-in works
    /// (`updateToken`) or the person asks for another try (`liftLockout()`), so that a list that
    /// failed for it can keep saying the sentence after the wait it named has passed.
    var lockoutNotice: LockoutNotice? {
        state.withLock { $0.lockout?.notice }
    }

    /// The person asked for a try (a pull or Retry on the list): the sign-in the list needs is made,
    /// lock or no lock. Another 429 locks it again.
    func liftLockout() {
        state.withLock { $0.lockout = nil }
    }

    /// The lock as it stands for a request: nil once the wait it named has passed. A server that named
    /// no wait is read as locked until the person asks.
    private func activeLockout(_ current: State) -> (notice: LockoutNotice, until: Date?)? {
        guard let lockout = current.lockout else { return nil }
        if let until = lockout.until, until <= now() { return nil }
        return lockout
    }

    // MARK: Requests

    /// The `Accept` the server must never see `text/html` in: with it, its gate answers 302 to the
    /// login page instead of 401, and the app could not tell "log in" from "not the server".
    static let accept = "*/*"

    /// Builds a request for `path` (starts with "/", already percent-encoded where needed, may carry
    /// a `?query`) on this server.
    func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest {
        request(url: Self.url(base, path: path), method: method, body: body, contentType: contentType)
    }

    /// The same for an absolute URL (a `MediaRequest`), with the cookie as it is now.
    func request(url: URL, method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(Self.accept, forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let cookie = cookieHeader { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        return request
    }

    /// `base` plus an already encoded `path`. The server lives at the root, so whatever path `base`
    /// had is replaced, not kept.
    static func url(_ base: URL, path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let plain = base.absoluteString + path
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return URL(string: plain) ?? base
        }
        components.percentEncodedPath = String(parts[0])
        components.percentEncodedQuery = parts.count > 1 ? String(parts[1]) : nil
        components.fragment = nil
        return components.url ?? URL(string: plain) ?? base
    }

    // MARK: Sending

    /// Sends with the cookie as it is now. Transport errors come through unmapped, which is what
    /// `ServerConnection.connect` needs to tell a certificate from a missing box.
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await transport.send(withCookie(request))
    }

    /// Sends it with the cookie; maps transport errors to `UpstreamError`; on 401 with a saved
    /// password logs in once and retries.
    func data(for request: URLRequest) async throws -> HTTPResponse {
        try await authenticated(request) { [transport] request in
            try await transport.send(request)
        }
    }

    /// `data(for:)` for a body that is streamed to a file instead of held in memory.
    func download(_ request: URLRequest, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> HTTPResponse {
        try await authenticated(request) { [transport] request in
            try await transport.download(request, to: destination, progress: progress)
        }
    }

    /// `POST /login` with user "admin". 302 + Set-Cookie → token (stored, returned). 401 →
    /// `.unauthorized`, 429 → `.lockedOut`. It is the person's own try (connect, the sign-in-again
    /// page), so it is sent lock or no lock.
    func login(password: String) async throws -> SessionToken {
        try await logIn(with: password)
    }

    /// `POST /login` as it came back, with transport errors unmapped; for `connect`, which reports
    /// failures its own way. Nothing is stored.
    func postLogin(password: String) async throws -> LoginAnswer {
        // The server reads a form of at most 4096 bytes; `+` means a space to it, so the password is encoded strictly.
        let form = "u=admin&p=" + ServerPath.queryValue(password) + "&next=%2F"
        let request = request("/login", method: "POST", body: Data(form.utf8),
                              contentType: "application/x-www-form-urlencoded")
        let response = try await send(request)
        switch response.status {
        case 302:
            guard let token = Wire.sessionToken(setCookie: response.value(forHeader: "Set-Cookie")) else {
                return .failed(status: 302, message: nil)
            }
            return .token(token)
        case 401:
            return .rejected
        case 429:
            let notice = Self.lockoutNotice(in: response.body)
            let until = notice.minutes.map { now().addingTimeInterval(Double($0) * 60) }
            state.withLock { $0.lockout = (notice, until) }
            return .lockedOut(notice)
        default:
            return .failed(status: response.status, message: response.failureMessage)
        }
    }

    /// The server's sentence when it stops taking tries, and the wait it names. The server answers
    /// `/login` with its login page, the sentence in the page's error line and nowhere else, and no
    /// `Retry-After`. The line is taken as it is written, in the language the server answered in; a
    /// body that is a short plain text is taken as that sentence; a body with neither says nothing.
    static func lockoutNotice(in body: Data) -> LockoutNotice {
        let text = String(decoding: body.prefix(65_536), as: UTF8.self)
        let message: String?
        if let line = try? Self.errorLine.firstMatch(in: text)?.output.1 {
            message = plainText(line)
        } else if isASentence(text) {
            message = plainText(Substring(text))
        } else {
            message = nil
        }
        return LockoutNotice(message: message, minutes: message.flatMap(namedMinutes(in:)))
    }

    /// A short plain text and nothing else: not a page, which has markup, and not a JSON answer,
    /// which would otherwise be shown as what the server said, braces and all.
    private static func isASentence(_ text: String) -> Bool {
        text.count <= 200 && !text.contains("<") && !text.contains("{")
    }

    /// The error line of the server's login page: `<div class="err">…</div>`. Made where it is
    /// used: a pattern is not kept in a static, which Swift 6 would not have as shared state.
    /// The server's own page, as it answers a locked sign-in, is at the top of the parser table in
    /// the tests: a pattern that does not match it reads as "the server said nothing", on every
    /// screen, and no other row has the page's own shape.
    private static var errorLine: Regex<(Substring, Substring)> { #/<div class="err">([^<]*)</# }

    /// A sentence with its markup and entities gone; nil when nothing is left. The patterns are
    /// written with the long delimiters (`#/…/#`): a bare `/…/` after `(` reads as operators here.
    private static func plainText(_ text: Substring) -> String? {
        let unmarked = text.replacing(#/<[^>]*>/#, with: "")
        let named = unmarked.replacing(#/&(amp|lt|gt|quot|apos|nbsp);/#) { match in
            switch match.output.1 {
            case "amp": "&"
            case "lt": "<"
            case "gt": ">"
            case "quot": "\""
            case "apos": "'"
            default: "\u{00A0}"
            }
        }
        let numbered = named.replacing(#/&#([0-9]+|[xX][0-9A-Fa-f]+);/#) { match in
            let body = match.output.1
            let hex = body.first == "x" || body.first == "X"
            let value = UInt32(hex ? body.dropFirst() : body, radix: hex ? 16 : 10)
            return value.flatMap(Unicode.Scalar.init).map(String.init) ?? ""
        }
        let sentence = numbered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return sentence.isEmpty ? nil : sentence
    }

    /// The wait the sentence names, as minutes: a number written with "分" (分钟) or "min"/"minute(s)".
    /// Anything else reads as no wait at all, a number of seconds or one of more than a day among it,
    /// and then the app waits for the person, not for a time.
    private static func namedMinutes(in sentence: String) -> Int? {
        guard let digits = try? Self.minuteWait.firstMatch(in: sentence)?.output.1,
              let minutes = Int(digits), (1...1_440).contains(minutes) else { return nil }
        return minutes
    }

    /// "分" (U+5206) and "分钟" (U+5206 U+949F), written as code points: the sources hold no CJK.
    private static var minuteWait: Regex<(Substring, Substring)> {
        #/(?i)(\d+)\s*(?:\u{5206}\u{949F}|\u{5206}|mins?|minutes?)/#
    }

    // MARK: Internals

    /// The one password check at a time. A burst of requests that all find the cookie expired must
    /// cost the server one attempt, not a burst of them, and they all want the same answer.
    fileprivate func logIn(with password: String) async throws -> SessionToken {
        do {
            switch try await postLogin(password: password) {
            case .token(let token):
                updateToken(token)
                return token
            case .rejected:
                if password == self.password { state.withLock { $0.passwordRejected = true } }
                throw UpstreamError.unauthorized
            case .lockedOut:
                throw UpstreamError.lockedOut
            case .failed(let status, let message):
                throw UpstreamError.http(status: status, message: message)
            }
        } catch let error as UpstreamError {
            throw error
        } catch {
            throw TransportFailure.upstream(error)
        }
    }

    private func authenticated(_ original: URLRequest,
                               transmit: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) async throws -> HTTPResponse {
        do {
            let revision = state.withLock { $0.revision }
            // Locked out, with no cookie to send: every signed-in request would only be refused again.
            if token == nil, state.withLock({ activeLockout($0) }) != nil { throw UpstreamError.lockedOut }
            let response = try await transmit(withCookie(original))
            guard response.status == 401 else { return response }
            guard hasPassword else { throw UpstreamError.unauthorized }

            // The server is not taking tries for a while, on its own word: that is what this is, and
            // `/login` is not sent. The person's own ask lifts the lock first (`liftLockout()`).
            if state.withLock({ activeLockout($0) }) != nil { throw UpstreamError.lockedOut }

            if isAtRevision(revision) {
                if state.withLock({ $0.passwordRejected }) { throw UpstreamError.unauthorized }
                do {
                    _ = try await logins.login(self, staleRevision: revision)
                } catch {
                    signInFailed(staleRevision: revision)
                    throw error
                }
            }
            // (Else: a login that finished while this request was in flight already replaced the cookie.)
            // Unless it did not: one that found the server locked changed the revision too, and left
            // no cookie to retry with. The lock is what answers here as well.
            if state.withLock({ activeLockout($0) }) != nil { throw UpstreamError.lockedOut }

            let retry = try await transmit(withCookie(original))
            guard retry.status != 401 else { throw UpstreamError.unauthorized }
            return retry
        } catch let error as UpstreamError {
            throw error
        } catch {
            throw TransportFailure.upstream(error)
        }
    }

    private func withCookie(_ request: URLRequest) -> URLRequest {
        var request = request
        if let cookie = cookieHeader {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        } else {
            request.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    /// Whether the cookie is still as it was when `revision` was read: no sign-in, no refusal and
    /// no sign-out changed it since.
    fileprivate func isAtRevision(_ revision: Int) -> Bool {
        state.withLock { $0.revision == revision }
    }

    /// The cookie was refused and the sign-in that was to replace it did not work: keeping it would
    /// only repeat this. Once per cookie: whoever sees the failure first drops it, and the others
    /// find it dropped, or find a newer cookie that a person signed in for in the meantime, which stays.
    fileprivate func signInFailed(staleRevision revision: Int) {
        state.withLock { current in
            guard current.revision == revision else { return }
            current.token = nil
            current.revision += 1
        }
    }
}

/// One login at a time, shared by every request that ran into the same stale cookie.
private actor LoginGate {
    /// The sign-in for the cookie state it was asked for, kept after it finished: a request that
    /// took long to get here is answered by it, and the password is not tried twice for one state.
    private var signIn: (revision: Int, task: Task<SessionToken, Error>)?

    /// The token of the one sign-in for the cookie state `revision`, which every request that found
    /// the same stale cookie waits for. Nil when that state was left behind with no sign-in to
    /// wait for: there is nothing for the caller but to go on with the cookie as it is now.
    func login(_ session: ServerSession, staleRevision revision: Int) async throws -> SessionToken? {
        if let current = signIn, current.revision == revision {
            return try await current.task.value
        }
        guard session.isAtRevision(revision) else { return nil }
        // Not a child task on purpose: a caller that is cancelled must not cancel the login the others are waiting for.
        let task = Task { try await session.logIn(with: session.password ?? "") }
        signIn = (revision, task)
        return try await task.value
    }
}
