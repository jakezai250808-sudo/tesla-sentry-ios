import Foundation
@testable import WatchpostApp

/// A second stand-in for the box, for the tests whose requests do not come one after another:
/// the model asks for the list and the status at once, and a plan that waits for a transcode sends
/// a hint on the side. Each path has answers of its own.
final class RoutingTransport: HTTPTransport, @unchecked Sendable {
    /// What one request to a path gets.
    enum Step: Sendable {
        case now(StubTransport.Reply)
        /// Nothing until the test lets it go (`releaseWaiting()`), or the request's task is cancelled;
        /// then this answer.
        case held(StubTransport.Reply)
    }

    enum Answer: Sendable {
        /// One per request in order; the last one answers every request after it.
        case replies([Step])
        /// Chosen per request from what arrived.
        case decided(@Sendable (StubTransport.Sent) -> StubTransport.Reply)
        /// Every request waits until the test lets it go, then gets this.
        case held(StubTransport.Reply)
    }

    /// A request that was told to wait. `end` may come before `hold` (cancellation is prompt).
    private final class Pause: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?
        private var outcome: Result<Void, any Error>?

        func hold(_ continuation: CheckedContinuation<Void, any Error>) {
            let already: Result<Void, any Error>? = lock.withLock {
                if let outcome { return outcome }
                self.continuation = continuation
                return nil
            }
            if let already { continuation.resume(with: already) }
        }

        func end(_ result: Result<Void, any Error> = .success(())) {
            let waiting: CheckedContinuation<Void, any Error>? = lock.withLock {
                guard outcome == nil else { return nil }
                outcome = result
                let held = continuation
                continuation = nil
                return held
            }
            waiting?.resume(with: result)
        }
    }

    private struct Route {
        var answer: Answer
        var taken = 0
    }

    private enum Pick {
        case reply(StubTransport.Reply)
        case ask(@Sendable (StubTransport.Sent) -> StubTransport.Reply)
        case wait
        case nothing
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var fallback: Route
    private var recorded: [StubTransport.Sent] = []
    private var pauses: [Pause] = []
    private var released = false

    /// A path nobody said anything about is answered with a 500 that says so.
    init(otherwise fallback: StubTransport.Reply = .status(500, "no answer was set up for this path")) {
        self.fallback = Route(answer: .replies([.now(fallback)]))
    }

    // MARK: Setting it up

    /// `path` as `URL.path` gives it (decoded, without the query).
    func route(_ path: String, _ answer: Answer) {
        lock.withLock { routes[path] = Route(answer: answer) }
    }

    func route(_ path: String, _ replies: [StubTransport.Reply]) {
        route(path, .replies(replies.map(Step.now)))
    }

    func route(_ path: String, steps: [Step]) {
        route(path, .replies(steps))
    }

    func route(_ path: String, endless reply: StubTransport.Reply) {
        route(path, .replies([.now(reply)]))
    }

    /// Lets every request that was told to wait go on; each is then answered by what its route says now.
    /// Once released, nothing waits again on this transport.
    func releaseWaiting() {
        let waiting: [Pause] = lock.withLock {
            released = true
            let held = pauses
            pauses = []
            return held
        }
        waiting.forEach { $0.end() }
    }

    // MARK: What arrived

    var sent: [StubTransport.Sent] { lock.withLock { recorded } }

    func sent(to path: String) -> [StubTransport.Sent] { sent.filter { $0.path == path } }

    // MARK: HTTPTransport

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let sent = record(.send, request)
        return try respond(to: await answer(for: sent))
    }

    /// Writes the body in two halves so progress is seen twice, as the real client reports every chunk.
    func download(_ request: URLRequest, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> HTTPResponse {
        let sent = record(.download, request)
        let reply = try await answer(for: sent)
        guard case .status(let status, let headers, let body) = reply else { return try respond(to: reply) }
        let bytes = Data(body.utf8)
        guard (200..<300).contains(status) else { return HTTPResponse(status: status, headers: headers, body: bytes) }

        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard files.createFile(atPath: destination.path, contents: nil) else { throw URLError(.cannotCreateFile) }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let total = headers.first { $0.key.lowercased() == "content-length" }.flatMap { Int64($0.value) }
        let cut = bytes.count / 2
        try handle.write(contentsOf: bytes.prefix(cut))
        progress(Int64(cut), total)
        try handle.write(contentsOf: bytes.suffix(from: cut))
        progress(Int64(bytes.count), total)
        return HTTPResponse(status: status, headers: headers, body: Data())
    }

    // MARK: Internals

    private func record(_ kind: StubTransport.Sent.Kind, _ request: URLRequest) -> StubTransport.Sent {
        let entry = StubTransport.Sent(kind: kind, url: request.url ?? URL(string: "about:blank")!,
                                       method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:],
                                       body: request.httpBody ?? Data())
        lock.withLock { recorded.append(entry) }
        return entry
    }

    private func answer(for sent: StubTransport.Sent) async throws -> StubTransport.Reply {
        while true {
            switch pick(for: sent) {
            case .reply(let reply): return reply
            case .ask(let decide): return decide(sent)
            case .nothing: throw StubTransport.OutOfReplies()
            case .wait: try await pause()
            }
        }
    }

    private func pick(for sent: StubTransport.Sent) -> Pick {
        lock.withLock {
            let key = sent.path
            let own = routes[key] != nil
            var route = own ? routes[key]! : fallback
            defer { if own { routes[key] = route } else { fallback = route } }
            switch route.answer {
            case .replies(let steps):
                guard !steps.isEmpty else { return .nothing }
                let step = steps[min(route.taken, steps.count - 1)]
                route.taken += 1
                switch step {
                case .now(let reply): return .reply(reply)
                case .held(let reply): return released ? .reply(reply) : .wait
                }
            case .decided(let decide):
                return .ask(decide)
            case .held(let reply):
                return released ? .reply(reply) : .wait
            }
        }
    }

    /// Waits until released or cancelled. A released request is answered by what its route says then.
    private func pause() async throws {
        let pause = Pause()
        lock.withLock { pauses.append(pause) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pause.hold(continuation)
            }
        } onCancel: {
            pause.end(.failure(CancellationError()))
        }
    }

    private func respond(to reply: StubTransport.Reply) throws -> HTTPResponse {
        switch reply {
        case .status(let status, let headers, let body):
            HTTPResponse(status: status, headers: headers, body: Data(body.utf8))
        case .raises(let error):
            throw error
        }
    }
}
