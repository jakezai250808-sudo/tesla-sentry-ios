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
    /// 429: too many wrong attempts; the server locks this address for the rest of a ten-minute window.
    case lockedOut
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
    }
    private let state: OSAllocatedUnfairLock<State>
    private let logins = LoginGate()

    init(id: UUID, base: URL, password: String?, token: SessionToken?, transport: any HTTPTransport) {
        self.id = id
        self.base = base
        self.password = password
        self.transport = transport
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
        }
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
    /// `.unauthorized`, 429 → `.lockedOut`.
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
            return .lockedOut
        default:
            return .failed(status: response.status, message: response.failureMessage)
        }
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
            let response = try await transmit(withCookie(original))
            guard response.status == 401 else { return response }
            guard hasPassword else { throw UpstreamError.unauthorized }

            if state.withLock({ $0.revision }) == revision {
                if state.withLock({ $0.passwordRejected }) { throw UpstreamError.unauthorized }
                do {
                    _ = try await logins.login(self, staleRevision: revision)
                } catch {
                    // The cookie was refused and could not be replaced: keeping it would only repeat this.
                    state.withLock { $0.token = nil; $0.revision += 1 }
                    throw error
                }
            }
            // (Else: a login that finished while this request was in flight already replaced the cookie.)

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
}

/// One login at a time, shared by every request that ran into the same stale cookie.
private actor LoginGate {
    private var inFlight: (revision: Int, task: Task<SessionToken, Error>)?

    func login(_ session: ServerSession, staleRevision revision: Int) async throws -> SessionToken {
        if let inFlight, inFlight.revision == revision {
            return try await inFlight.task.value
        }
        // Not a child task on purpose: a caller that is cancelled must not cancel the login the others are waiting for.
        let task = Task { try await session.logIn(with: session.password ?? "") }
        inFlight = (revision, task)
        defer {
            if inFlight?.revision == revision { inFlight = nil }
        }
        return try await task.value
    }
}
