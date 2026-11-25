import Foundation

/// The first talk with a server: is it the server, and do we get in?
enum ServerConnection {
    struct Outcome: Sendable {
        let version: String
        /// The cookie to keep (nil for a server that needs no password).
        let token: SessionToken?
        let requiresPassword: Bool
    }

    /// 1. `GET /api/ver` (open to everyone) must answer with a version, or this is not the server.
    /// 2. `GET /api/auth/info` with the cookie we have, if any: 200 with `on: false` is an open server;
    ///    200 with `on: true` means the cookie still works; 401 means log in, with the password if
    ///    there is one, else tell the person their credentials are refused.
    ///
    /// Throws `ConnectFailure` only (plus `CancellationError`).
    static func connect(base: URL, password: String?, token: SessionToken?, transport: any HTTPTransport) async throws -> Outcome {
        let scheme = base.scheme?.lowercased()
        guard scheme == "http" || scheme == "https", let host = base.host, !host.isEmpty else {
            throw ConnectFailure.invalidAddress(.notAnAddress)
        }
        let session = ServerSession(id: UUID(), base: base, password: password, token: token, transport: transport)

        let version: String
        do {
            let response = try await session.send(session.request("/api/ver"))
            guard response.status == 200, let found = Wire.version(JSONValue(data: response.body)) else {
                throw ConnectFailure.incompatibleServer
            }
            version = found
        } catch let failure as ConnectFailure {
            throw failure
        } catch {
            throw TransportFailure.connectFailure(error, base: base)
        }

        let info: HTTPResponse
        do {
            info = try await session.send(session.request("/api/auth/info"))
        } catch {
            throw TransportFailure.connectFailure(error, base: base)
        }
        let json = JSONValue(data: info.body)
        switch info.status {
        case 200:
            // Without `on` the server does not say; trust the cookie that just worked (or the lack of one).
            let gated = Wire.requiresPassword(json) ?? (token != nil)
            if !gated { return Outcome(version: version, token: nil, requiresPassword: false) }
            if let token { return Outcome(version: version, token: token, requiresPassword: true) }
        case 401:
            break
        default:
            throw ConnectFailure.server(status: info.status)
        }

        guard let password, !password.isEmpty else { throw ConnectFailure.credentialsRejected }
        do {
            switch try await session.postLogin(password: password) {
            case .token(let token):
                return Outcome(version: version, token: token, requiresPassword: true)
            case .rejected:
                throw ConnectFailure.credentialsRejected
            case .lockedOut(let notice):
                throw ConnectFailure.lockedOut(notice)
            case .failed(let status, _):
                throw ConnectFailure.server(status: status)
            }
        } catch let failure as ConnectFailure {
            throw failure
        } catch {
            throw TransportFailure.connectFailure(error, base: base)
        }
    }
}
