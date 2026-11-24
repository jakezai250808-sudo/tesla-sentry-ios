import Foundation
import os

// Talking to the server over HTTP: one request type, one answer type, and the
// URLSession implementation. Everything above this (the session, the clip
// source) goes through `HTTPTransport`, so tests can stand in for the box.

/// One HTTP answer.
struct HTTPResponse: Sendable, Equatable {
    let status: Int
    /// Header names spelled as the server spelled them (`Set-Cookie`); use `value(forHeader:)` to look one up.
    let headers: [String: String]
    let body: Data

    /// A header whatever case its name arrived in: the server writes `Set-Cookie`, other servers write `set-cookie`.
    func value(forHeader name: String) -> String? {
        if let value = headers[name] { return value }
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }

    /// `Content-Length` when it was sent.
    var contentLength: Int64? {
        value(forHeader: "Content-Length").flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    var isSuccess: Bool { (200..<300).contains(status) }
}

extension HTTPResponse {
    /// What the server said along with a failure: the `error` / `msg` of a JSON answer, or a short text body.
    var failureMessage: String? {
        if let message = Wire.message(JSONValue(data: body)) { return message }
        let text = String(decoding: body.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // A body that is not text (a page, a file) says nothing useful.
        return text.isEmpty || text.contains("\u{FFFD}") ? nil : text
    }
}

/// Sends requests. Implemented by `HTTPClient` (URLSession) and by test stubs.
protocol HTTPTransport: Sendable {
    /// One request/response exchange, body fully received.
    func send(_ request: URLRequest) async throws -> HTTPResponse
    /// Brings the body to `destination`, reporting bytes as they arrive.
    ///
    /// The status is known before the first byte is written. A 2xx answer is written beside `destination`
    /// and moved into its place once it is all there, so a download that fails part-way leaves whatever
    /// was at `destination` alone and no half file anywhere. Any other answer leaves the file alone and
    /// only its (short) body in the returned response.
    func download(_ request: URLRequest, to destination: URL,
                  progress: @escaping @Sendable (_ received: Int64, _ total: Int64?) -> Void) async throws -> HTTPResponse
}

enum TransportFailure {
    /// Any error thrown by a transport → `UpstreamError`.
    static func upstream(_ error: Error) -> UpstreamError {
        if let urlError = error as? URLError {
            return .network(domain: (urlError as NSError).domain, code: urlError.code.rawValue)
        }
        if error is CancellationError {
            // A cancelled request is still the transport stopping; callers that care check `Task.isCancelled` first.
            return .network(domain: NSURLErrorDomain, code: URLError.Code.cancelled.rawValue)
        }
        return .badResponse
    }

    /// Any error thrown while connecting → `ConnectFailure`. `base` decides local vs. public.
    static func connectFailure(_ error: Error, base: URL) -> ConnectFailure {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        guard let urlError = error as? URLError else { return .unreachable }
        if certificateCodes.contains(urlError.code) { return .certificateRejected }
        if unreachableCodes.contains(urlError.code) {
            return ServerAddress.isLocal(base) ? .localNetworkUnreachable : .unreachable
        }
        return .unreachable
    }

    /// -1200 … -1206: the TLS handshake failed on a certificate. The numbers are the family; the names are for reading.
    private static let certificateCodes: Set<URLError.Code> = [
        .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
        .clientCertificateRequired,
    ]

    /// "Could not get through": no such host, refused, lost, no network (also the local-network permission), timed out.
    private static let unreachableCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost,
        .notConnectedToInternet, .timedOut, .resourceUnavailable, .dataNotAllowed,
        .cannotLoadFromNetwork, .httpTooManyRedirects, .internationalRoamingOff, .callIsActive,
    ]
}

// MARK: - Client

/// The server answers a successful login with a 302 that carries the cookie, and tells a page to log
/// in first with a 302 as well. Both must arrive as answers, so no redirect is ever followed.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// `HTTPTransport` on URLSession.
final class HTTPClient: HTTPTransport {
    private let configuration: URLSessionConfiguration
    private let session: URLSession

    init(configuration: URLSessionConfiguration = HTTPClient.makeConfiguration()) {
        self.configuration = configuration
        // The delegate is passed to the session and to every call: either alone should do, both is certain.
        session = URLSession(configuration: configuration, delegate: NoRedirects.shared, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // The cookie is set by hand from the saved session; a cookie store would race with that.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // The server says `no-store` on everything it answers, and a cached answer is a stale one.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A box that is switched off must fail at once, not wait for "connectivity" to come back.
        configuration.waitsForConnectivity = false
        // These boxes sit on the person's own LAN; a system-wide proxy or filter would swallow that.
        configuration.connectionProxyDictionary = [:]
        // The server drops a silent connection after 30 s, so there is no point in out-waiting it.
        configuration.timeoutIntervalForRequest = 30
        // Each request costs the server a thread (it has 48) and AVPlayer opens its own connections on top.
        configuration.httpMaximumConnectionsPerHost = 4
        return configuration
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let reply: (data: Data, response: URLResponse)
        do {
            reply = try await session.data(for: request, delegate: NoRedirects.shared)
        } catch {
            throw HTTPClient.stopped(error)
        }
        return try HTTPClient.http(reply.response, body: reply.data)
    }

    func download(_ request: URLRequest, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> HTTPResponse {
        do {
            return try await Download(to: destination, progress: progress).run(request, configuration: configuration)
        } catch {
            throw HTTPClient.stopped(error)
        }
    }

    /// A refusal is a few words long; this much of it is kept at most, and no more is read.
    fileprivate static let refusalLimit = 64 * 1024

    fileprivate static func http(_ response: URLResponse, body: Data) throws -> HTTPResponse {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers["\(name)"] = "\(value)"
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: body)
    }

    /// URLSession reports a cancelled task as `URLError.cancelled`; structured cancellation expects `CancellationError`.
    fileprivate static func stopped(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if Task.isCancelled { return CancellationError() }
        return error
    }
}

/// One download, with a URLSession of its own: URLSession hands the body out in pieces only to a
/// session's delegate. It calls this on its own queue: the answer's head first, then the body, then
/// done. Nothing here waits on anything, so it does not matter which executor the caller runs on.
/// (`URLSession.AsyncBytes` was tried first: it awaits once per byte, and a loop over it that runs on
/// the main actor takes about a hundredth of the speed.)
private final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Progress is reported at least this often, by bytes or by time, and always at the end.
    private static let reportBytes: Int64 = 256 * 1024
    private static let reportEvery: Duration = .milliseconds(250)

    private let destination: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let clock = ContinuousClock()

    // Shared with the caller's thread.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPResponse, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var finished = false

    // Touched on URLSession's queue only.
    private var head: HTTPResponse?
    private var total: Int64?
    /// The first thing that went wrong, when it went wrong before URLSession noticed.
    private var failure: (any Error)?
    /// The body as it arrives; `destination` itself is only ever the whole file.
    private var part: URL?
    private var handle: FileHandle?
    private var refusal = Data()
    private var received: Int64 = 0
    private var reported: Int64 = -1
    private var reportedAt: ContinuousClock.Instant?

    init(to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    /// Sends the request and returns once the file is in place, or the answer was a refusal.
    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> HTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let accepted = lock.withLock {
                    // Cancelled before there was anything to cancel.
                    guard !cancelled else { return false }
                    self.continuation = continuation
                    return true
                }
                guard accepted else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                task.resume()
                let stop = lock.withLock {
                    self.session = session
                    self.task = task
                    return cancelled
                }
                // Cancelled between the two locks.
                if stop { task.cancel() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    /// Hands the result over exactly once, and lets the session go: it keeps its delegate until it is told to.
    private func finish(_ result: Result<HTTPResponse, any Error>) {
        let waiting: (continuation: CheckedContinuation<HTTPResponse, any Error>, session: URLSession?)? = lock.withLock { () -> (continuation: CheckedContinuation<HTTPResponse, any Error>, session: URLSession?)? in
            guard !finished, let continuation else { return nil }
            finished = true
            let held = (continuation, session)
            self.continuation = nil
            self.session = nil
            task = nil
            return held
        }
        guard let waiting else { return }
        waiting.session?.finishTasksAndInvalidate()
        waiting.continuation.resume(with: result)
    }

    // MARK: What URLSession says

    /// The server never redirects a download either: a 302 here is an answer, like everywhere else.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // Only a file is refused here (when its folder cannot be made); then the completion carries it.
        do {
            let head = try HTTPClient.http(response, body: Data())
            self.head = head
            total = head.contentLength
            if head.isSuccess { try openPart() }
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let head else { return }
        if head.isSuccess {
            do {
                try handle?.write(contentsOf: data)
                received += Int64(data.count)
                report()
            } catch {
                // The disk is full or the file is gone; going on would only write more of nothing.
                failure = failure ?? error
                dataTask.cancel()
            }
        } else {
            let room = HTTPClient.refusalLimit - refusal.count
            guard room > 0 else { return }
            refusal.append(contentsOf: data.prefix(room))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let problem = failure ?? error
        guard let head else {
            // Never got as far as an answer.
            finish(.failure(problem ?? URLError(.badServerResponse)))
            return
        }
        if let problem {
            closePart()
            removePart()
            finish(.failure(problem))
            return
        }
        guard head.isSuccess else {
            finish(.success(HTTPResponse(status: head.status, headers: head.headers, body: refusal)))
            return
        }
        do {
            closePart()
            try putPartInPlace()
            report(force: true)
            finish(.success(HTTPResponse(status: head.status, headers: head.headers, body: Data())))
        } catch {
            removePart()
            finish(.failure(error))
        }
    }

    // MARK: The file

    private func openPart() throws {
        let files = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let part = folder.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).part")
        guard files.createFile(atPath: part.path, contents: nil) else { throw URLError(.cannotCreateFile) }
        handle = try FileHandle(forWritingTo: part)
        self.part = part
    }

    private func closePart() {
        try? handle?.close()
        handle = nil
    }

    /// Only a whole file ever bears the name the caller asked for.
    private func putPartInPlace() throws {
        guard let part else { throw URLError(.cannotCreateFile) }
        let files = FileManager.default
        try? files.removeItem(at: destination)
        try files.moveItem(at: part, to: destination)
        self.part = nil
    }

    private func removePart() {
        if let part { try? FileManager.default.removeItem(at: part) }
        part = nil
    }

    private func report(force: Bool = false) {
        let overdue = reportedAt.map { clock.now - $0 >= Self.reportEvery } ?? true
        guard received != reported, force || received - reported >= Self.reportBytes || overdue else { return }
        reported = received
        reportedAt = clock.now
        progress(received, total)
    }
}

// MARK: - Encoding

/// How the server's paths go into a URL. Event folders and files come from the car and may hold
/// spaces, dots and Chinese characters (the server's `safe_name` allows `[\w\-. ]`), and the server
/// decodes the path before it looks at it, so every such name is percent-encoded here.
enum ServerPath {
    /// What may stay as it is: ASCII letters, digits and `-._~`. (Not `CharacterSet.alphanumerics`:
    /// that keeps Chinese characters raw, which `URLComponents` then refuses.)
    private static let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// One path segment.
    static func segment(_ text: some StringProtocol) -> String {
        let raw = String(text)
        return raw.addingPercentEncoding(withAllowedCharacters: plain) ?? raw
    }

    /// A whole path such as `/media/SentryClips/2026-11-08 19-43-36/…-front.mp4`, each segment encoded, the slashes kept.
    static func path(_ raw: String) -> String {
        raw.split(separator: "/", omittingEmptySubsequences: false).map(segment).joined(separator: "/")
    }

    /// One query value. `/` stays so a media path in it stays readable; space becomes `%20`, never `+`
    /// (the server would read a `+` as a space).
    static func queryValue(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: plain.union(CharacterSet(charactersIn: "/"))) ?? text
    }

    /// `name=value&name=value` with both sides encoded; empty when there are no items.
    static func query(_ items: [(String, String)]) -> String {
        items.map { "\(queryValue($0.0))=\(queryValue($0.1))" }.joined(separator: "&")
    }
}
