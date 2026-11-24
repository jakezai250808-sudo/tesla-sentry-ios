import Foundation

// A real HTTP server on 127.0.0.1 for the tests of `HTTPClient`, the one
// transport that talks to the network. The stub cannot show what URLSession
// makes of a 302 or of a body that stops half-way; this can.

/// One request as it arrived on the socket.
struct LoopbackRequest: Sendable, Equatable {
    /// `POST /login HTTP/1.1`
    let requestLine: String
    /// Names as they were written (`Cookie`, `Accept`).
    let headers: [String: String]
    let body: Data

    var method: String { requestLine.split(separator: " ").first.map(String.init) ?? "" }
    /// Path and query as they were written, e.g. `/api/ver`.
    var target: String { requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "" }

    /// A header whatever case it arrived in.
    func header(_ name: String) -> String? {
        if let value = headers[name] { return value }
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }
}

/// What the server writes back.
struct LoopbackResponse: Sendable {
    var status: Int
    var headers: [(String, String)]
    var body: Data
    /// Sends only this many bytes of the body and hangs up, while claiming the whole: a link that drops.
    var cutoff: Int?
    /// Set: the body goes out in `chunkSize` pieces with this long a pause between them, so a download takes
    /// long enough to be watched (and cancelled) on the way.
    var pauseMicros: UInt32?
    var chunkSize = 64 * 1024

    init(_ status: Int, headers: [(String, String)] = [], body: Data = Data(), cutoff: Int? = nil, pauseMicros: UInt32? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.cutoff = cutoff
        self.pauseMicros = pauseMicros
    }

    /// A JSON answer with the headers the box gives.
    static func json(_ text: String, status: Int = 200) -> LoopbackResponse {
        LoopbackResponse(status, headers: Self.serverHeaders + [("Content-Type", "application/json")], body: Data(text.utf8))
    }

    static func text(_ status: Int, _ text: String) -> LoopbackResponse {
        LoopbackResponse(status, headers: Self.serverHeaders + [("Content-Type", "text/plain; charset=utf-8")], body: Data(text.utf8))
    }

    private static var serverHeaders: [(String, String)] { [("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")] }
}

/// Answers each request with what `handler` says, one connection at a time, and remembers the requests.
final class LoopbackServer: @unchecked Sendable {
    typealias Handler = @Sendable (LoopbackRequest) -> LoopbackResponse

    enum StartError: Error {
        case cannotListen(errno: Int32)
    }

    /// `http://127.0.0.1:<port>`.
    let url: URL
    private let core: Core

    init(handler: @escaping Handler) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw StartError.cannotListen(errno: errno) }
        // A client that hangs up first must not kill the test host with SIGPIPE.
        var on: Int32 = 1
        _ = setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1,
              withUnsafePointer(to: &address, {
                  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                      bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                  }
              }) == 0,
              listen(listener, 16) == 0
        else {
            let code = errno
            close(listener)
            throw StartError.cannotListen(errno: code)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")!

        // The serve loop waits on this pipe; a byte on it is the only way it is told to stop.
        var wake: [Int32] = [0, 0]
        guard pipe(&wake) == 0 else {
            let code = errno
            close(listener)
            throw StartError.cannotListen(errno: code)
        }
        core = Core(listener: listener, wake: wake, handler: handler)
        Thread.detachNewThread { [core] in core.serve() }
    }

    deinit {
        core.stop()
    }

    var requests: [LoopbackRequest] { core.requests }

    /// Stops serving. Requests already answered stay recorded.
    func stop() {
        core.stop()
    }

    /// A port nothing listens on: one that was bound a moment ago and is free again.
    static func unusedPort() throws -> UInt16 {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        guard probe >= 0 else { throw StartError.cannotListen(errno: errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1,
              withUnsafePointer(to: &address, {
                  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                      bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                  }
              }) == 0
        else {
            let code = errno
            close(probe)
            throw StartError.cannotListen(errno: code)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) }
        }
        close(probe)
        return UInt16(bigEndian: address.sin_port)
    }

    /// The socket end: owns the descriptors, so it is the only thing that touches them.
    private final class Core: @unchecked Sendable {
        private let listener: Int32
        /// `read`, `write`.
        private let wake: [Int32]
        private let handler: LoopbackServer.Handler
        private let lock = NSLock()
        private var recorded: [LoopbackRequest] = []
        private var stopAsked = false
        private let exited = DispatchSemaphore(value: 0)

        init(listener: Int32, wake: [Int32], handler: @escaping LoopbackServer.Handler) {
            self.listener = listener
            self.wake = wake
            self.handler = handler
        }

        var requests: [LoopbackRequest] { lock.withLock { recorded } }

        private var isStopped: Bool { lock.withLock { stopAsked } }

        /// Tells the loop to stop and waits until it is out of the socket calls, so the descriptors are
        /// closed only when nothing can be using their numbers.
        func stop() {
            let first = lock.withLock {
                let was = !stopAsked
                stopAsked = true
                return was
            }
            guard first else { return }
            var byte: UInt8 = 1
            _ = write(wake[1], &byte, 1)
            _ = exited.wait(timeout: .now() + .seconds(10))
            close(listener)
            close(wake[0])
            close(wake[1])
        }

        func serve() {
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            while !isStopped {
                var readers = fd_set()
                set(listener, in: &readers)
                set(wake[0], in: &readers)
                let ready = select(max(listener, wake[0]) + 1, &readers, nil, nil, &timeout)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                // Asked to stop, maybe with a connection still waiting: that one is reset when the socket closes.
                if isStopped { break }
                guard ready > 0 else { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                answer(client)
                close(client)
            }
            exited.signal()
        }

        private static let headEnd: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        private static let headLimit = 64 * 1024
        private static let bodyLimit = 1024 * 1024

        /// Marks a descriptor for `select`. `fd_set` is one bit per descriptor, least significant bit
        /// first; the C macros for it do not import into Swift.
        private func set(_ fd: Int32, in watchers: inout fd_set) {
            withUnsafeMutableBytes(of: &watchers) { raw in
                raw[Int(fd) / 8] |= 1 << UInt8(Int(fd) % 8)
            }
        }

        /// Reads one request, answers it, and comes back.
        private func answer(_ client: Int32) {
            // Accepted sockets inherit the listener's non-blocking flag here; a read that runs ahead of the
            // request would come back empty. Blocking, with a time limit, is what this needs.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // No request here needs long: a stuck client must not hold the only serve loop.
            var limit = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

            var buffer = [UInt8]()
            var separator: Range<Int>?
            while separator == nil {
                if let found = buffer.firstRange(of: Self.headEnd) {
                    separator = found
                    break
                }
                guard buffer.count < Self.headLimit, receive(client, into: &buffer) else { return }
            }
            guard let separator else { return }

            let lines = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let wanted = min(headers.first { $0.key.lowercased() == "content-length" }.flatMap { Int($0.value) } ?? 0,
                             Self.bodyLimit)
            var body = Array(buffer[separator.upperBound...])
            while body.count < wanted {
                guard receive(client, into: &body) else { return }
            }

            let request = LoopbackRequest(requestLine: lines.first ?? "", headers: headers, body: Data(body))
            lock.withLock { recorded.append(request) }
            send(handler(request), to: client)
        }

        /// Appends what is on the socket; false when it is gone.
        private func receive(_ fd: Int32, into buffer: inout [UInt8]) -> Bool {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            let count = chunk.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, raw.count) }
            guard count > 0 else { return false }
            buffer.append(contentsOf: chunk[..<count])
            return true
        }

        private func send(_ response: LoopbackResponse, to fd: Int32) {
            var out = Data("HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n".utf8)
            for (name, value) in response.headers {
                out.append(Data("\(name): \(value)\r\n".utf8))
            }
            out.append(Data("Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n".utf8))
            guard push(out, to: fd) else { return }
            let body = response.body.prefix(min(response.body.count, max(response.cutoff ?? response.body.count, 0)))
            guard let pause = response.pauseMicros else {
                _ = push(body, to: fd)
                return
            }
            var offset = 0
            while offset < body.count {
                let end = min(offset + response.chunkSize, body.count)
                guard push(body[offset..<end], to: fd) else { return }
                usleep(pause)
                offset = end
            }
        }

        /// Puts all of `bytes` on the socket; false when it is gone.
        private func push(_ bytes: Data, to fd: Int32) -> Bool {
            return bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    // The descriptor may be gone already (the client read enough, or hung up): that is not this test's problem.
                    let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += count
                }
                return true
            }
        }

        private static func reason(_ status: Int) -> String {
            switch status {
            case 200: "OK"
            case 302: "Found"
            case 404: "Not Found"
            default: "Status"
            }
        }
    }
}
