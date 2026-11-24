import Foundation
import Testing
@testable import WatchpostApp

/// `AppModel`: where the app is and how it gets there, over a transport that answers from a script.
/// Each test has a store of its own (a defaults suite nobody else reads, and a secret service of its own).
@MainActor
struct AppModelTests {
    /// Not the app's service: the test never reads or writes what the app keeps in the keychain.
    private static let secrets = SecretStore(service: "com.watchpost.tests.secrets")

    private static let newToken = "1761600000.ffffffffffffffffffffffffffffffff"

    private func makeStore() -> ServerStore {
        let suite = "com.watchpost.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = ServerStore(defaults: defaults, secrets: Self.secrets)
        registry.note(suite)
        registry.note(store)
        return store
    }

    private func makeModel(_ transport: RoutingTransport) -> (model: AppModel, store: ServerStore) {
        let store = makeStore()
        return (AppModel(store: store, transport: transport), store)
    }

    /// What a test made, so the test can forget it when it is over: every test starts with `defer { registry.cleanUp() }`.
    @MainActor
    private final class Registry {
        private var suites: [String] = []
        private var stores: [ServerStore] = []

        func note(_ suite: String) { suites.append(suite) }

        func note(_ store: ServerStore) { stores.append(store) }

        func cleanUp() {
            // Forgetting a server forgets its password and cookie too.
            for store in stores {
                for record in store.records { store.remove(record.id) }
            }
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        }
    }

    private let registry = Registry()

    private func record(_ address: String = "192.168.1.50:8080", quality: Quality = .standard) -> ServerRecord {
        ServerRecord(address: try! ServerAddress.normalize(address), preferredQuality: quality)
    }

    /// An open server (no password) with the fixture list and status. Routes can be replaced before connecting.
    private func openServer() -> RoutingTransport {
        let transport = RoutingTransport()
        transport.route("/api/ver", endless: .ok(ServerFixtures.version))
        transport.route("/api/auth/info", endless: .ok(ServerFixtures.authInfoOff))
        transport.route("/api/events", endless: .ok(Fixtures.eventsJSON))
        transport.route("/api/live", endless: .ok(ServerFixtures.live))
        return transport
    }

    /// A server behind a password; the typed password is what gets in.
    private func gatedServer() -> RoutingTransport {
        let transport = openServer()
        transport.route("/api/auth/info", endless: .ok(ServerFixtures.authInfoOn))
        transport.route("/login", endless: .loginOK(token: Self.newToken))
        return transport
    }

    /// Connects with what is in the form, and waits for the list.
    private func connect(_ model: AppModel) async {
        model.connect()
        #expect(model.connectState == .connecting)
        #expect(await settle { model.loadState.isLoaded })
    }

    // MARK: A fresh app

    @Test func aFreshAppIsOnTheConnectScreenWithNothingLoaded() async {
        defer { registry.cleanUp() }
        let (model, _) = makeModel(RoutingTransport())
        #expect(model.mode == .connect)
        #expect(!model.isDemo)
        #expect(model.source == nil)
        #expect(model.loadState == .idle)
        #expect(model.serverIsOnline == nil)
        #expect(model.currentRecord == nil)
        #expect(model.serverPage == nil)
        #expect(model.preferredQuality == .standard)
        #expect(model.connectState == .idle)
        #expect(model.connectCompletions == 0)
        #expect(model.events.isEmpty)
        #expect(model.filter.category == .sentry)
        // With nothing to ask, refreshing is nothing.
        await model.refresh()
        await model.refreshIfNeeded()
        #expect(model.loadState == .idle)
    }

    @Test func theConnectButtonWaitsForAUsableAddressAndForNothingToBeInProgress() async throws {
        defer { registry.cleanUp() }
        let transport = RoutingTransport()
        transport.route("/api/ver", steps: [.held(.raises(URLError(.cannotConnectToHost)))])
        let (model, store) = makeModel(transport)
        #expect(!model.canSubmit, "Nothing typed")
        model.addressText = "192.168.1.50:8080"
        #expect(model.canSubmit)
        model.addressText = "ftp://box.local"
        #expect(!model.canSubmit)
        model.addressText = " 192.168.1.50:8080 "
        model.connect()
        #expect(model.connectState == .connecting)
        #expect(!model.canSubmit, "Already asking")
        transport.releaseWaiting()
        #expect(await settle { model.connectState == .failed(.localNetworkUnreachable) })
        #expect(model.canSubmit)
        #expect(model.mode == .connect)
        #expect(store.records.isEmpty)
    }

    @Test(arguments: [
        ("ftp://box.local", ConnectState.failed(.invalidAddress(.notAnAddress))),
        ("   ", ConnectState.failed(.invalidAddress(.empty))),
    ] as [(String, ConnectState)])
    func anAddressThatCannotBeUsedIsNamedWithoutAsking(_ typed: String, _ expected: ConnectState) async {
        defer { registry.cleanUp() }
        let transport = openServer()
        let (model, store) = makeModel(transport)
        model.addressText = typed
        model.connect()
        #expect(model.connectState == expected)
        #expect(transport.sent.isEmpty)
        #expect(store.records.isEmpty)
    }

    @Test(arguments: [
        (StubTransport.Reply.ok("nope"), StubTransport.Reply.ok(ServerFixtures.authInfoOff), ConnectState.failed(.incompatibleServer)),
        (.status(500, "down"), .ok(ServerFixtures.authInfoOff), .failed(.incompatibleServer)),
        (.ok(ServerFixtures.version), .status(503, "busy"), .failed(.server(status: 503))),
        (.raises(URLError(.serverCertificateUntrusted)), .ok(ServerFixtures.authInfoOff), .failed(.certificateRejected)),
    ] as [(StubTransport.Reply, StubTransport.Reply, ConnectState)])
    func whatTheFirstAnswersSay(_ version: StubTransport.Reply, _ authInfo: StubTransport.Reply, _ expected: ConnectState) async {
        defer { registry.cleanUp() }
        let transport = RoutingTransport()
        transport.route("/api/ver", endless: version)
        transport.route("/api/auth/info", endless: authInfo)
        let (model, store) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        model.connect()
        #expect(await settle { model.connectState == expected })
        #expect(store.records.isEmpty)
        #expect(model.mode == .connect)
    }

    @Test(arguments: [
        (StubTransport.Reply.status(401), ConnectState.failed(.credentialsRejected)),
        (.status(429, "try later"), .failed(.lockedOut)),
        (.status(500, "down"), .failed(.server(status: 500))),
    ] as [(StubTransport.Reply, ConnectState)])
    func aLoginThatDoesNotWorkIsShownAndNothingIsSaved(_ login: StubTransport.Reply, _ expected: ConnectState) async {
        defer { registry.cleanUp() }
        let transport = openServer()
        transport.route("/api/auth/info", endless: .ok(ServerFixtures.authInfoOn))
        transport.route("/login", endless: login)
        let (model, store) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        model.passwordText = "wrong"
        model.connect()
        #expect(await settle { model.connectState == expected })
        #expect(store.records.isEmpty)
        #expect(model.mode == .connect)
        #expect(model.connectCompletions == 0)
    }

    // MARK: Connecting

    @Test func anOpenServerIsSavedAndTheListIsLoadedWithoutALogin() async throws {
        defer { registry.cleanUp() }
        let transport = openServer()
        let (model, store) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        await connect(model)
        let id = try #require(store.records.first?.id)
        #expect(model.mode == .server(id))
        #expect(store.records.count == 1)
        #expect(store.record(id: id)?.address == (try ServerAddress.normalize("192.168.1.50:8080")))
        #expect(model.currentRecord?.hostLabel == "192.168.1.50:8080")
        #expect(store.record(id: id)?.serverVersion == "2.8.45")
        #expect(store.lastServerID == id)
        #expect(store.token(for: id) == nil, "An open server keeps no cookie")
        #expect(store.password(for: id) == nil)
        #expect(model.connectState == .idle)
        #expect(model.connectTarget == nil)
        #expect(model.passwordText == "")
        #expect(model.connectCompletions == 1)
        #expect(model.source?.identity == .server(id))
        #expect(model.currentRecord?.id == id)
        #expect(model.serverPage == store.record(id: id)?.address)
        #expect(model.events == Fixtures.events)
        #expect(model.status != nil)
        #expect(!model.statusUnavailable)
        #expect(model.loadState.isLoaded)
        #expect(model.serverIsOnline == true)
        #expect(model.lastFailure == nil)
        #expect(model.lastRefresh != nil)
        #expect(model.sessionExpired == false)
        #expect(model.preferredQuality == .standard)
        #expect(transport.sent(to: "/login").isEmpty)
        #expect(Set(transport.sent.map(\.path)) == ["/api/ver", "/api/auth/info", "/api/events", "/api/live"])
        #expect(transport.sent.count == 4)
        // The quality choice is kept with the server.
        model.setPreferredQuality(.hd720)
        #expect(store.record(id: id)?.preferredQuality == .hd720)
        #expect(model.preferredQuality == .hd720)
    }

    @Test func aGatedServerIsLoggedIntoWithTheTypedPasswordAndBothAreKept() async throws {
        defer { registry.cleanUp() }
        let transport = gatedServer()
        let (model, store) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        model.passwordText = "s3cret"
        await connect(model)
        let id = try #require(store.records.first?.id)
        #expect(model.passwordText == "", "Not left in the form")
        #expect(store.password(for: id) == "s3cret")
        #expect(store.token(for: id)?.value == Self.newToken)
        #expect(model.mode == .server(id))
        let login = try #require(transport.sent(to: "/login").first)
        #expect(login.bodyText == "u=admin&p=s3cret&next=%2F")
        // The list is asked for with the cookie the login brought.
        #expect(transport.sent(to: "/api/events").first?.header("Cookie") == "tsf_sess=\(Self.newToken)")
        #expect(transport.sent(to: "/api/live").first?.header("Cookie") == "tsf_sess=\(Self.newToken)")
        #expect(transport.sent(to: "/login").count == 1)
    }

    @Test func connectingToASavedServerUsesWhatIsStoredForIt() async throws {
        defer { registry.cleanUp() }
        let transport = openServer()
        transport.route("/api/auth/info", endless: .ok(ServerFixtures.authInfoOn))
        let store = makeStore()
        var record = record()
        record.serverVersion = "2.7.1"
        store.save(record)
        store.setPassword("kept", for: record.id)
        store.setToken(Fixtures.token, for: record.id)
        let model = AppModel(store: store, transport: transport)
        model.connect(to: record)
        #expect(model.connectState == .connecting)
        #expect(model.connectTarget == ConnectTarget(recordID: record.id, address: record.address))
        #expect(await settle { model.loadState.isLoaded })
        // The stored cookie still works: no login, the same record, the version brought up to date.
        #expect(transport.sent(to: "/login").isEmpty)
        #expect(transport.sent(to: "/api/auth/info").first?.header("Cookie") == Fixtures.cookie)
        #expect(store.records.map(\.id) == [record.id])
        #expect(store.record(id: record.id)?.serverVersion == "2.8.45")
        #expect(store.token(for: record.id) == Fixtures.token)
        #expect(store.password(for: record.id) == "kept")
        #expect(model.mode == .server(record.id))
        #expect(model.connectTarget == nil)
        #expect(model.connectCompletions == 1)
        #expect(store.lastServerID == record.id)
    }

    @Test func editingASavedServerInPlaceKeepsItAndANewAddressSavesANewOne() async throws {
        defer { registry.cleanUp() }
        let transport = gatedServer()
        let store = makeStore()
        let old = record(quality: .hd720)
        store.save(old)
        store.setToken(Fixtures.token, for: old.id)
        let model = AppModel(store: store, transport: transport)
        model.edit(old)
        #expect(model.connectTarget == ConnectTarget(recordID: old.id, address: old.address))
        #expect(model.addressText == "192.168.1.50:8080")
        #expect(model.passwordText == "")
        #expect(model.connectState == .idle)
        model.connect()
        #expect(await settle { model.loadState.isLoaded })
        // Same address: the same server, with what was stored for it (the cookie is still good).
        #expect(store.records.map(\.id) == [old.id])
        #expect(store.record(id: old.id)?.preferredQuality == .hd720)
        #expect(store.record(id: old.id)?.addedAt == old.addedAt)
        #expect(model.mode == .server(old.id))
        #expect(model.preferredQuality == .hd720)
        #expect(transport.sent(to: "/login").isEmpty)
        // Another address typed into the same form is another server; the first stays saved.
        model.returnToConnect()
        model.edit(old)
        model.addressText = "192.168.1.51"
        model.passwordText = "pw"
        model.connect()
        #expect(await settle { model.connectState == .idle && model.loadState.isLoaded && model.mode != .server(old.id) })
        #expect(store.records.count == 2)
        #expect(store.record(id: old.id) != nil)
        #expect(model.connectCompletions == 2)
        model.openNewServerForm()
        #expect(model.connectTarget == nil)
        #expect(model.addressText == "")
        #expect(model.passwordText == "")
    }

    @Test func cancellingAConnectStopsWaitingAndNothingIsSaved() async throws {
        defer { registry.cleanUp() }
        let transport = RoutingTransport()
        transport.route("/api/ver", steps: [.held(.ok(ServerFixtures.version))])
        let (model, store) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        model.connect()
        #expect(model.connectState == .connecting)
        model.cancelConnect()
        #expect(model.connectState == .idle)
        transport.releaseWaiting()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.connectState == .idle)
        #expect(model.mode == .connect)
        #expect(store.records.isEmpty)
        #expect(transport.sent(to: "/api/auth/info").isEmpty)
    }

    @Test func restoreGoesBackToTheLastServerAndLoadsIt() async throws {
        defer { registry.cleanUp() }
        let transport = openServer()
        let store = makeStore()
        let saved = ServerRecord(address: try ServerAddress.normalize("192.168.1.50:8080"), lastUsedAt: .distantPast)
        store.save(saved)
        store.setToken(Fixtures.token, for: saved.id)
        store.lastServerID = saved.id
        let model = AppModel(store: store, transport: transport)
        model.restore()
        #expect(model.mode == .server(saved.id))
        #expect(model.source?.identity == .server(saved.id))
        #expect(await settle { model.loadState.isLoaded })
        #expect(model.events == Fixtures.events)
        #expect(try #require(store.record(id: saved.id)).lastUsedAt > .distantPast)
        // Without a last server, or with one that was forgotten, there is nowhere to go back to.
        let fresh = AppModel(store: makeStore(), transport: openServer())
        fresh.restore()
        #expect(fresh.mode == .connect)
        let gone = makeStore()
        gone.lastServerID = UUID()
        let stale = AppModel(store: gone, transport: openServer())
        stale.restore()
        #expect(stale.mode == .connect)
    }

    // MARK: The list

    @Test func aListThatCannotBeFetchedShowsTheBoxAsOfflineWithTheReason() async throws {
        defer { registry.cleanUp() }
        let transport = openServer()
        transport.route("/api/events", steps: [.now(.raises(URLError(.cannotConnectToHost))), .now(.ok(Fixtures.eventsJSON))])
        let (model, _) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        model.connect()
        #expect(await settle { model.loadState == .failed })
        #expect(model.events.isEmpty)
        #expect(model.serverIsOnline == false)
        #expect(model.lastFailure == .network(domain: NSURLErrorDomain, code: URLError.cannotConnectToHost.rawValue))
        #expect(model.sessionExpired == false)
        #expect(model.status != nil, "The status answered")
        // A failed list is not asked for again behind the person's back.
        await model.refreshIfNeeded()
        #expect(transport.sent(to: "/api/events").count == 1)
        // An explicit refresh is.
        await model.refresh()
        #expect(model.loadState.isLoaded)
        #expect(model.serverIsOnline == true)
        #expect(model.lastFailure == nil)
        #expect(model.events == Fixtures.events)
        #expect(transport.sent(to: "/api/events").count == 2)
    }

    @Test func aStatusThatDoesNotAnswerIsOnlyTheStatus() async {
        defer { registry.cleanUp() }
        let transport = openServer()
        transport.route("/api/live", endless: .status(500, "busy"))
        let (model, _) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        await connect(model)
        #expect(model.loadState.isLoaded)
        #expect(model.serverIsOnline == true)
        #expect(model.status == nil)
        #expect(model.statusUnavailable)
        #expect(!model.events.isEmpty)
    }

    @Test func aFreshListIsNotAskedForAgainUntilItIsAMinuteOld() async {
        defer { registry.cleanUp() }
        let transport = openServer()
        let (model, _) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        await connect(model)
        #expect(transport.sent(to: "/api/events").count == 1)
        await model.refreshIfNeeded()
        await model.refreshIfNeeded()
        #expect(transport.sent(to: "/api/events").count == 1)
        #expect(transport.sent(to: "/api/live").count == 1)
    }

    @Test func anAnswerFromAServerJustLeftIsDropped() async throws {
        defer { registry.cleanUp() }
        let transport = openServer()
        transport.route("/api/events", steps: [.held(.ok(Fixtures.eventsJSON))])
        let (model, store) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        model.connect()
        #expect(await waitUntil { transport.sent(to: "/api/events").count == 1 })
        model.returnToConnect()
        #expect(model.mode == .connect)
        transport.releaseWaiting()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.loadState == .idle)
        #expect(model.events.isEmpty)
        #expect(model.source == nil)
        #expect(store.records.count == 1, "Leaving does not forget the server")
    }

    // MARK: Signing in again

    @Test func aRefusedSessionAsksForThePasswordAgain() async throws {
        defer { registry.cleanUp() }
        let transport = gatedServer()
        // The cookie is refused on the list, and the saved password on the login that follows.
        transport.route("/api/events", steps: [.now(.unauthorized()), .now(.ok(Fixtures.eventsJSON))])
        transport.route("/login", steps: [.now(.loginOK(token: Self.newToken)), .now(.status(401)), .now(.loginOK(token: "1761700000.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))])
        let (model, store) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        model.passwordText = "s3cret"
        model.connect()
        #expect(await settle { model.sessionExpired })
        #expect(model.loadState == .failed)
        #expect(model.lastFailure == .unauthorized)
        #expect(model.serverIsOnline == nil, "Offline or not is not the question now")
        #expect(model.mode != .connect, "The server stays current")
        #expect(transport.sent(to: "/login").count == 2)
        model.dismissSessionNotice()
        #expect(!model.sessionExpired)
        #expect(model.passwordText == "")
        // Signing in again with a new password: kept, and the list is loaded.
        #expect(await model.reconnect(password: "better") == nil)
        #expect(!model.sessionExpired)
        #expect(model.loadState.isLoaded)
        #expect(store.records.first.flatMap { store.password(for: $0.id) } == "better")
        #expect(store.records.first.flatMap { store.token(for: $0.id) }?.value == "1761700000.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(transport.sent(to: "/login").count == 3)
        #expect(transport.sent(to: "/api/events").count == 2)
        #expect(transport.sent(to: "/api/events").last?.header("Cookie") == "tsf_sess=1761700000.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    }

    @Test(arguments: [
        (StubTransport.Reply.status(401), ConnectFailure.credentialsRejected),
        (.status(429, "try later"), .lockedOut),
        (.raises(URLError(.cannotConnectToHost)), .unreachable),
    ] as [(StubTransport.Reply, ConnectFailure)])
    func whySigningInAgainDidNotWork(_ login: StubTransport.Reply, _ expected: ConnectFailure) async {
        defer { registry.cleanUp() }
        let transport = openServer()
        transport.route("/login", endless: login)
        let (model, _) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        await connect(model)
        #expect(await model.reconnect(password: "whatever") == expected)
    }

    @Test func signingInAgainNeedsACurrentServer() async {
        defer { registry.cleanUp() }
        let (model, _) = makeModel(RoutingTransport())
        #expect(await model.reconnect(password: "whatever") == .unreachable)
    }

    // MARK: Leaving

    @Test func forgettingTheServerInUseGoesBackToTheConnectScreen() async throws {
        defer { registry.cleanUp() }
        let transport = openServer()
        let (model, store) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        await connect(model)
        let current = try #require(model.currentRecord)
        let other = record("192.168.1.51")
        store.save(other)
        store.setPassword("x", for: other.id)
        model.remove(other)
        #expect(model.mode == .server(current.id))
        #expect(store.records.map(\.id) == [current.id])
        model.passwordText = "typed"
        model.showPassword = true
        model.setCategory(.recent)
        model.remove(current)
        #expect(model.mode == .connect)
        #expect(model.source == nil)
        #expect(store.records.isEmpty)
        #expect(store.lastServerID == nil)
        #expect(model.loadState == .idle)
        #expect(model.events.isEmpty)
        #expect(model.passwordText == "")
        #expect(!model.showPassword)
        #expect(model.filter.category == .sentry)
        #expect(model.currentRecord == nil)
    }

    @Test func leavingKeepsTheServerSavedButClearsTheScreen() async {
        defer { registry.cleanUp() }
        let transport = openServer()
        let (model, store) = makeModel(transport)
        model.addressText = "192.168.1.50:8080"
        await connect(model)
        model.passwordText = "typed"
        model.showPassword = true
        model.setCategory(.saved)
        model.returnToConnect()
        #expect(model.mode == .connect)
        #expect(model.source == nil)
        #expect(model.passwordText == "")
        #expect(!model.showPassword)
        #expect(model.filter.category == .sentry)
        #expect(model.loadState == .idle)
        #expect(store.records.count == 1)
        #expect(store.lastServerID == nil)
    }

    // MARK: The demo

    @Test func theDemoShowsItsOwnEventsAndTalksToNoServer() async {
        defer { registry.cleanUp() }
        let transport = RoutingTransport()
        let (model, _) = makeModel(transport)
        model.enterDemo()
        #expect(model.mode == .demo)
        #expect(model.isDemo)
        #expect(model.source?.identity == .demo)
        #expect(await settle { model.loadState.isLoaded })
        #expect(model.events.count == 9)
        #expect(model.events.allSatisfy { $0.category == .sentry || $0.category == .saved || $0.category == .recent })
        #expect(model.serverIsOnline == true)
        #expect(model.status != nil)
        #expect(model.currentRecord == nil)
        #expect(transport.sent.isEmpty)
        model.returnToConnect()
        #expect(model.mode == .connect)
        #expect(model.events.isEmpty)
    }
}

private extension LoadState {
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}
