import Foundation
import Observation
import UIKit

enum LoadState: Equatable {
    /// Nothing asked yet.
    case idle
    /// The first request is on its way; there is nothing to show meanwhile.
    case loading
    case loaded(at: Date)
    case failed
}

enum ConnectState: Equatable {
    case idle
    case connecting
    case failed(ConnectFailure)
}

/// The saved server the connect form was opened for, if any.
struct ConnectTarget: Equatable {
    let recordID: UUID
    let address: URL
}

extension ClipCategory {
    /// The short name on the tab.
    var title: String {
        switch self {
        case .sentry: String(localized: "Sentry", comment: "Tab: sentry clips")
        case .saved: String(localized: "Saved", comment: "Tab: saved clips")
        case .recent: String(localized: "Recent", comment: "Tab: recent clips")
        }
    }

    /// The full name, for accessibility.
    var fullTitle: String {
        switch self {
        case .sentry: String(localized: "Sentry clips", comment: "Category: SentryClips, full name for accessibility")
        case .saved: String(localized: "Saved clips", comment: "Category: SavedClips, full name for accessibility")
        case .recent: String(localized: "Recent clips", comment: "Category: RecentClips, full name for accessibility")
        }
    }
}

/// The app's one piece of state: where it is (not connected, demo, a server),
/// where the events come from, and what the connect form is doing.
@MainActor
@Observable
final class AppModel {
    enum Mode: Equatable {
        case connect
        case demo
        case server(UUID)
    }

    let store: ServerStore
    private let transport: any HTTPTransport

    private(set) var mode: Mode = .connect
    /// Where the events screen's clips come from.
    private(set) var source: (any ClipSource)?
    private var serverSessions: [UUID: ServerSession] = [:]

    // Events screen
    private(set) var events: [RecordedEvent] = []
    private(set) var loadState: LoadState = .idle
    /// Why the last refresh did not work: for the one case the person can fix
    /// outside the app (local network permission), for the events screen to
    /// tell an empty list that is missing because the server refused the session
    /// from any other, and for it to say when the server stopped taking tries at
    /// the password (`listLockout`); nil once a refresh works.
    private(set) var lastFailure: UpstreamError?
    /// When the list on screen was last fetched; the list may be older than the phone's clock.
    private(set) var lastRefresh: Date?
    private(set) var status: SyncStatus?
    private(set) var statusUnavailable = false
    /// The server stopped accepting the session; the person has to sign in again.
    private(set) var sessionExpired = false
    var filter = EventFilter()
    private var loadGeneration = 0

    // Connect form
    var addressText = ""
    var passwordText = ""
    var showPassword = false
    private(set) var connectState: ConnectState = .idle
    private(set) var connectTarget: ConnectTarget?
    /// Counts the connects that worked. A form shown in a sheet watches it to tell
    /// a request that ended well from one the person stopped with "Cancel connecting".
    private(set) var connectCompletions = 0
    private var connectTask: Task<Void, Never>?

    let thumbnails = ThumbnailCache()

    init(store: ServerStore = ServerStore(), transport: any HTTPTransport = HTTPClient()) {
        self.store = store
        self.transport = transport
    }

    // MARK: Where the app is

    var isDemo: Bool { mode == .demo }

    var currentRecord: ServerRecord? {
        if case .server(let id) = mode { return store.record(id: id) }
        return nil
    }

    /// Known from the last request: true when it answered, false when it did
    /// not, nil while nothing was asked yet or a request is on its way. A server that stopped
    /// taking tries at the password answered, so it is online.
    var serverIsOnline: Bool? {
        switch loadState {
        case .idle, .loading: nil
        case .loaded: true
        case .failed: sessionExpired ? nil : lastFailure == .lockedOut
        }
    }

    /// The quality new clips start at on the current server.
    var preferredQuality: Quality {
        currentRecord?.preferredQuality ?? .standard
    }

    func setPreferredQuality(_ quality: Quality) {
        if case .server(let id) = mode { store.setQuality(quality, for: id) }
    }

    /// Back to the last server the app was on, when it is still saved.
    func restore() {
        guard let id = store.lastServerID, let record = store.record(id: id) else { return }
        let password = store.password(for: id)
        let token = store.token(for: id)
        let session = ServerSession(id: id, base: record.address, password: password, token: token, transport: transport)
        activate(record, session: session)
    }

    func enterDemo() {
        cancelConnect()
        thumbnails.removeAll()
        source = DemoClipSource()
        resetList()
        mode = .demo
        Task { await refresh() }
    }

    /// Leaves the demo (or a server) for the connect screen. Saved servers stay saved;
    /// the form starts empty, like the one a new server is typed into.
    func returnToConnect() {
        passwordText = ""
        showPassword = false
        source = nil
        serverSessions = [:]
        store.lastServerID = nil
        thumbnails.removeAll()
        resetList()
        mode = .connect
    }

    /// The web page of the current server, for the one thing the app does not do itself.
    var serverPage: URL? { currentRecord?.address }

    private func resetList() {
        events = []
        loadState = .idle
        lastFailure = nil
        lastRefresh = nil
        status = nil
        statusUnavailable = false
        sessionExpired = false
        filter = EventFilter()
        loadGeneration += 1
    }

    // MARK: Images

    func image(for request: MediaRequest) async -> UIImage? {
        guard let source else { return nil }
        return await thumbnails.image(for: request) { request in
            try await source.imageData(for: request)
        }
    }

    // MARK: Connecting

    /// The Connect button is tappable once the address is a usable one. The
    /// password may stay empty for a server that was set up without one.
    var canSubmit: Bool {
        ServerAddress.problem(addressText) == nil && connectState != .connecting
    }

    /// Opens the form for a saved server, with what is known about it.
    func edit(_ record: ServerRecord) {
        connectTarget = ConnectTarget(recordID: record.id, address: record.address)
        addressText = Self.plainAddress(record.address)
        passwordText = ""
        connectState = .idle
    }

    func openNewServerForm() {
        connectTarget = nil
        addressText = ""
        passwordText = ""
        connectState = .idle
    }

    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        connectState = .idle
    }

    /// The address without the parts nobody types: scheme `http://`, trailing slash.
    static func plainAddress(_ url: URL) -> String {
        var text = url.absoluteString
        if url.scheme?.lowercased() == "http" { text = String(text.dropFirst("http://".count)) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// Tries the address and password in the form.
    func connect() {
        guard connectState != .connecting else { return }
        let base: URL
        do {
            base = try ServerAddress.normalize(addressText)
        } catch {
            connectState = .failed(.invalidAddress(error))
            return
        }
        // The same server edited in place keeps its session and quality; a new address starts clean.
        let old = connectTarget.flatMap { store.record(id: $0.recordID) }.flatMap { $0.address == base ? $0 : nil }
        let token = old.flatMap { store.token(for: $0.id) }
        let typed = passwordText.isEmpty ? nil : passwordText
        let password = typed ?? old.flatMap { store.password(for: $0.id) }

        connectState = .connecting
        connectTask = Task { [weak self] in
            // Cancelled before this ran: nothing is asked and nothing is saved.
            guard let self, !Task.isCancelled else { return }
            do {
                let outcome = try await ServerConnection.connect(base: base, password: password, token: token, transport: self.transport)
                // Cancelled while the server was thinking: a late answer changes nothing.
                guard !Task.isCancelled else { return }
                let recordID = old?.id ?? UUID()
                var record = ServerRecord(id: recordID, address: base, addedAt: old?.addedAt ?? Date(),
                                          preferredQuality: old?.preferredQuality ?? .standard)
                record.serverVersion = outcome.version
                self.store.save(record)
                if let typed { self.store.setPassword(typed, for: recordID) }
                self.store.setToken(outcome.token, for: recordID)
                let session = ServerSession(id: recordID, base: base, password: password, token: outcome.token, transport: self.transport)
                self.finishConnecting()
                self.activate(record, session: session)
                UIAccessibility.post(notification: .announcement,
                                     argument: String(localized: "Connected", comment: "Announced by VoiceOver when the server is connected"))
            } catch {
                // A cancelled attempt is not the server failing; whoever cancelled has already set the state.
                guard !Task.isCancelled else { return }
                self.connectState = Self.afterFailure(error)
            }
        }
    }

    /// Taps a saved server: connects with what is stored for it.
    func connect(to record: ServerRecord) {
        guard connectState != .connecting else { return }
        let password = store.password(for: record.id)
        let token = store.token(for: record.id)
        connectTarget = ConnectTarget(recordID: record.id, address: record.address)
        connectState = .connecting
        connectTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let outcome = try await ServerConnection.connect(base: record.address, password: password, token: token,
                                                                 transport: self.transport)
                guard !Task.isCancelled else { return }
                var updated = record
                updated.serverVersion = outcome.version
                self.store.save(updated)
                self.store.setToken(outcome.token, for: record.id)
                let session = ServerSession(id: record.id, base: record.address, password: password,
                                            token: outcome.token, transport: self.transport)
                self.finishConnecting()
                self.activate(updated, session: session)
            } catch {
                guard !Task.isCancelled else { return }
                self.connectState = Self.afterFailure(error)
            }
        }
    }

    private static func afterFailure(_ error: Error) -> ConnectState {
        let failure = (error as? ConnectFailure) ?? .unreachable
        return failure == .cancelled ? .idle : .failed(failure)
    }

    private func finishConnecting() {
        connectState = .idle
        connectTarget = nil
        passwordText = ""
        connectTask = nil
        connectCompletions += 1
    }

    private func activate(_ record: ServerRecord, session: ServerSession) {
        thumbnails.removeAll()
        serverSessions[record.id] = session
        source = ServerClipSource(session: session)
        resetList()
        mode = .server(record.id)
        store.lastServerID = record.id
        store.touch(record.id)
        Task { await refresh() }
    }

    // MARK: The list

    /// Why there is no list, when the server stopped accepting the session: the person can fix
    /// that here. It is read off the failure and not off `sessionExpired`, which is cleared
    /// when the sign-in-again sheet is cancelled while the refusal is still the reason.
    var listNeedsSignIn: Bool { loadState == .failed && lastFailure == .unauthorized }

    /// The server's sentence from the sign-in the list is waiting on, when the list failed because
    /// the server stopped taking tries at the password: for the events screen to say under its own
    /// line, as it was said and in no other words. Nil for every other failure, and with no session
    /// to read it from; the sentence is not kept across launches.
    var listLockout: LockoutNotice? {
        guard !isDemo, lastFailure == .lockedOut, case .server(let id) = mode,
              let session = serverSessions[id] else { return nil }
        return session.lockoutNotice ?? LockoutNotice(message: nil, minutes: nil)
    }

    /// Whether the phone may not have got through to a server on its own network, which is often the
    /// local-network permission: then the events screen says so, hedged as the connect page does, and
    /// offers the way to Settings, under an empty list and under the banner over one still on screen.
    /// It reads the failure, as iOS reports a refused permission as an ordinary transport error. The
    /// demo reaches no server, and with no failed request or no current server there is nothing to read.
    var listMayNeedLocalNetworkPermission: Bool {
        guard !isDemo, let lastFailure, let record = currentRecord else { return false }
        return TransportFailure.localNetworkUnreachable(lastFailure, base: record.address)
    }

    func refreshIfNeeded() async {
        switch loadState {
        case .idle: await refresh()
        case .loaded(let at): if Date().timeIntervalSince(at) > 60 { await refresh() }
        case .loading, .failed: break
        }
    }

    /// Fetches everything the events screen shows. Answers from an older
    /// request, or from a server that is no longer current, are dropped.
    ///
    /// `askedByPerson` is a pull on the list or its Retry button. When the server stopped taking
    /// tries at the password (429), only that asks for the sign-in the list needs: without it nothing
    /// signs in, and the list is answered as locked until the wait the server named has passed, so
    /// that nothing in the app keeps the server locked by trying again on its own.
    func refresh(askedByPerson: Bool = false) async {
        guard let source else { return }
        if askedByPerson, case .server(let id) = mode { serverSessions[id]?.liftLockout() }
        loadGeneration += 1
        let generation = loadGeneration
        let stateBefore = loadState
        if events.isEmpty { loadState = .loading }
        async let eventsResult = AppModel.outcome { try await source.events() }
        async let statusResult = AppModel.outcome { try await source.syncStatus() }
        let (list, live) = await (eventsResult, statusResult)
        guard generation == loadGeneration, self.source?.identity == source.identity else { return }
        // Cancelled because the screen that asked went away: that is not an answer from the server.
        guard !Task.isCancelled else {
            loadState = stateBefore == .loading ? (events.isEmpty ? .idle : .loaded(at: lastRefresh ?? Date.distantPast)) : stateBefore
            return
        }
        switch list {
        case .success(let events):
            self.events = events
            lastFailure = nil
            lastRefresh = Date()
            loadState = .loaded(at: lastRefresh!)
        case .failure(let error):
            loadState = .failed
            lastFailure = error as? UpstreamError
            if lastFailure == .unauthorized { sessionExpired = true }
        }
        switch live {
        case .success(let status):
            self.status = status
            statusUnavailable = false
        case .failure:
            self.status = nil
            statusUnavailable = true
        }
    }

    private static func outcome<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    func setCategory(_ category: ClipCategory) {
        let changed = filter.changeCategory(to: category)
        if changed {
            UIAccessibility.post(notification: .announcement, argument: filter.category.fullTitle)
        }
    }

    func clearFilter() {
        filter.day = nil
        filter.bucket = nil
        filter.reason = nil
    }

    /// Signs in again on the current server with the password typed in the sheet. Returns nil once it
    /// worked and the list has been asked for again, loaded or not; otherwise why it did not work:
    /// `.credentialsRejected` when the server refused the password, `.lockedOut` (with what the
    /// server said) when it stopped taking tries, and `.localNetworkUnreachable` when the request
    /// did not get through to a server
    /// on its own network (often the local-network permission), which has the sheet offer the way to
    /// Settings. Anything else is `.unreachable`, as it is with no current server, when nothing was
    /// asked at all.
    ///
    /// A password that signed in, when it is not empty, is saved for this server and is, for the rest
    /// of this run, the one its session signs in with by itself: a cookie the server refuses later is
    /// answered with one sign-in, not with this page again, for as long as the server takes it. A
    /// password that did not sign in, and closing the page, leave both as they were. No other server
    /// is touched.
    func reconnect(password: String) async -> ConnectFailure? {
        guard case .server(let id) = mode, let session = serverSessions[id] else { return .unreachable }
        do {
            let token = try await session.login(password: password)
            store.setToken(token, for: id)
            if !password.isEmpty { store.setPassword(password, for: id) }
            sessionExpired = false
            await refresh()
            return nil
        } catch {
            guard let failure = error as? UpstreamError else { return .unreachable }
            switch failure {
            case .unauthorized: return .credentialsRejected
            case .lockedOut:
                return .lockedOut(session.lockoutNotice ?? LockoutNotice(message: nil, minutes: nil))
            default:
                if TransportFailure.localNetworkUnreachable(failure, base: session.base) {
                    return .localNetworkUnreachable
                }
                return .unreachable
            }
        }
    }

    /// Closes the sign-in-again sheet. The password typed there was for that one
    /// server: it must not stay in the connect form, where another address could be typed.
    func dismissSessionNotice() {
        sessionExpired = false
        passwordText = ""
        showPassword = false
    }

    /// Forgets a saved server. Removing the one in use goes back to the connect screen.
    func remove(_ record: ServerRecord) {
        if case .server(let id) = mode, id == record.id {
            returnToConnect()
        }
        serverSessions[record.id] = nil
        store.remove(record.id)
    }
}
