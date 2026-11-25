import Foundation
import Testing
@testable import WatchpostApp

/// A store that answers like the App Store would, from a script. It never talks to Apple.
final class FakeTipStore: TipStore, @unchecked Sendable {
    private enum Answer {
        /// Returned at once.
        case result(Result<TipPurchaseOutcome, any Error>)
        /// Left waiting, as while the App Store sheet is up, until `release`.
        case hold
    }

    private let lock = NSLock()
    private var listed: [TipProduct]
    private var stored: [TipReceipt]
    /// Tips the App Store took back and still lists, as after a refund while the app was away.
    private var takenBack: [UInt64]
    /// How often the store was asked for its listener.
    private var listenerAsks = 0
    private var scripted: Answer
    private var asked: [String] = []
    /// What a waiting purchase is handed. Kept, so an answer given before the wait starts is not lost.
    private let handed: AsyncStream<Result<TipPurchaseOutcome, any Error>>.Continuation
    private let answers: AsyncStream<Result<TipPurchaseOutcome, any Error>>
    /// Tips the App Store confirms while the app runs.
    let continuation: AsyncStream<TipReceipt>.Continuation
    /// Tips the App Store takes back while the app runs, by its number for the purchase.
    let refunds: AsyncStream<UInt64>.Continuation
    private let stream: AsyncStream<TipReceipt>
    private let refundStream: AsyncStream<UInt64>

    init(listing products: [TipProduct], unfinished: [TipReceipt] = [], takenBack: [UInt64] = []) {
        listed = products
        stored = unfinished
        self.takenBack = takenBack
        scripted = .result(.success(.cancelled))
        (answers, handed) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (stream, continuation) = AsyncStream<TipReceipt>.makeStream()
        (refundStream, refunds) = AsyncStream<UInt64>.makeStream()
    }

    /// What a purchase returns.
    func answer(_ outcome: Result<TipPurchaseOutcome, any Error>) {
        lock.withLock { scripted = .result(outcome) }
    }

    /// Purchases from now on wait, as while the App Store sheet is up.
    func hold() {
        lock.withLock { scripted = .hold }
    }

    /// Ends the purchase that waits, and says what purchases after that return.
    func release(_ outcome: Result<TipPurchaseOutcome, any Error>) {
        lock.withLock { scripted = .result(outcome) }
        handed.yield(outcome)
    }

    var listedProducts: [TipProduct] {
        get { lock.withLock { listed } }
        set { lock.withLock { listed = newValue } }
    }

    var unfinishedTips: [TipReceipt] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var listedAsTakenBack: [UInt64] {
        get { lock.withLock { takenBack } }
        set { lock.withLock { takenBack = newValue } }
    }

    var askedForListener: Int { lock.withLock { listenerAsks } }

    /// Every tip the app asked to buy, in order.
    var purchases: [String] { lock.withLock { asked } }

    func products() async throws -> [TipProduct] { listedProducts }

    func purchase(_ productID: String) async throws -> TipPurchaseOutcome {
        let answer: Answer = lock.withLock {
            asked.append(productID)
            return scripted
        }
        switch answer {
        case .result(let result):
            return try result.get()
        case .hold:
            for await result in answers { return try result.get() }
            throw CancellationError()
        }
    }

    func unfinishedTips() async -> [TipReceipt] { unfinishedTips }

    func refundedTips() async -> [UInt64] { listedAsTakenBack }

    var laterTips: LaterTips {
        lock.withLock { listenerAsks += 1 }
        return LaterTips(purchases: stream, refunds: refundStream)
    }
}

/// A store that cannot be reached at all.
private struct FailingTipStore: TipStore {
    struct Refused: Error {}

    func products() async throws -> [TipProduct] { throw Refused() }
    func purchase(_ productID: String) async throws -> TipPurchaseOutcome { throw Refused() }
    func unfinishedTips() async -> [TipReceipt] { [] }
    var laterTips: LaterTips { LaterTips(purchases: AsyncStream { $0.finish() }, refunds: AsyncStream { $0.finish() }) }
}

@MainActor
private func makeTips(store: any TipStore) -> (TipPurchases, UserDefaults) {
    let defaults = UserDefaults(suiteName: "TipPurchasesTests.\(UUID().uuidString)")!
    let tips = TipPurchases(productIDs: TipPurchases.productIDs, store: store, defaults: defaults)
    return (tips, defaults)
}

@MainActor
private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "TipPurchasesTests.\(UUID().uuidString)")!
}

private let listedTips = TipPurchases.productIDs.enumerated().map { index, id in
    TipProduct(id: id, displayPrice: "¥\(index + 1).00", amount: Decimal(index + 1), currencyCode: "CNY")
}

private func receipt(_ index: Int, daysAgo: Int = 0) -> TipReceipt {
    TipReceipt(productID: TipPurchases.productIDs[index],
               transactionID: UInt64(2000000000000000 + index),
               purchasedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) - TimeInterval(daysAgo) * 86_400),
               displayPrice: "¥\(index + 1).00", amount: Decimal(index + 1), currencyCode: "CNY")
}

/// Waits until no purchase is running, or complains that one never ended.
@MainActor
private func settle(_ tips: TipPurchases, fileID: String = #fileID, filePath: String = #filePath,
                     line: Int = #line, column: Int = #column) async {
    for _ in 0 ..< 200 {
        if tips.phase == .idle { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The purchase never ended",
                 sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
}

/// The tips: what counts as a tip, what the ticket remembers, and when a thank-you is due.
struct TipPurchasesTests {
    /// The tips are listed cheapest first, in the app's own order whatever order the store answers in.
    @Test
    @MainActor
    func loadKeepsTheAppsOrder() async {
        let store = FakeTipStore(listing: listedTips)
        store.listedProducts = listedTips.reversed()
        let (tips, _) = makeTips(store: store)

        await tips.load()

        #expect(tips.products.map(\.id) == TipPurchases.productIDs)
        #expect(tips.problem == nil)
        #expect(!tips.isLoading)
    }

    /// A store with nothing to sell, or one that cannot be reached, is said so and stays quiet.
    @Test
    @MainActor
    func nothingToSellIsSaidSo() async {
        let (empty, _) = makeTips(store: FakeTipStore(listing: []))
        await empty.load()
        #expect(empty.products.isEmpty)
        #expect(empty.problem == .unavailable)
        #expect(!empty.isLoading)

        let (failing, _) = makeTips(store: FailingTipStore())
        await failing.load()
        #expect(failing.products.isEmpty)
        #expect(failing.problem == .unavailable)
    }

    /// A tip that goes through becomes the ticket, is kept for the next launch, and its thank-you is queued.
    @Test
    @MainActor
    func boughtTipBecomesTheTicket() async {
        let store = FakeTipStore(listing: listedTips)
        let (tips, defaults) = makeTips(store: store)
        await tips.load()
        let bought = receipt(1)
        store.answer(.success(.bought(bought)))

        await tips.buy(tips.products[1])
        await settle(tips)

        #expect(store.purchases == [TipPurchases.productIDs[1]])
        #expect(tips.ticket == bought)
        #expect(tips.showsTicket)
        #expect(tips.confirmations == 1)
        #expect(tips.problem == nil)
        #expect(!tips.isAwaitingApproval)
        #expect(tips.phase == .idle)
        #expect(TipTicket.load(from: defaults) == bought)
    }

    /// Closing the App Store sheet is not a tip: no ticket, no thank-you, no complaint.
    @Test
    @MainActor
    func cancelledPurchaseLeavesNothing() async {
        let store = FakeTipStore(listing: listedTips)
        let (tips, defaults) = makeTips(store: store)
        await tips.load()

        await tips.buy(listedTips[0])
        await settle(tips)

        #expect(store.purchases == [TipPurchases.productIDs[0]])
        #expect(tips.ticket == nil)
        #expect(!tips.showsTicket)
        #expect(tips.confirmations == 0)
        #expect(tips.problem == nil)
        #expect(TipTicket.load(from: defaults) == nil)
    }

    /// Ask to Buy still waiting: nothing is owned yet, so no ticket and no thank-you, only the waiting note.
    @Test
    @MainActor
    func pendingPurchaseWaitsWithoutATicket() async {
        let store = FakeTipStore(listing: listedTips)
        let (tips, defaults) = makeTips(store: store)
        await tips.load()
        tips.start()
        store.answer(.success(.pending))

        await tips.buy(listedTips[2])
        await settle(tips)

        #expect(tips.isAwaitingApproval)
        #expect(tips.ticket == nil)
        #expect(!tips.showsTicket)
        #expect(tips.problem == nil)
        #expect(TipTicket.load(from: defaults) == nil)

        // The approval that arrives later clears the waiting note.
        store.continuation.yield(receipt(2))
        for _ in 0 ..< 200 where tips.ticket == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(tips.ticket == receipt(2))
        #expect(!tips.isAwaitingApproval)
        store.continuation.finish()
    }

    /// A purchase that did not complete says so, and is not a tip.
    @Test(arguments: [TipStoreProblem.missingProduct, TipStoreProblem.unverified])
    @MainActor
    func failedPurchaseIsNotATip(problem: TipStoreProblem) async {
        let store = FakeTipStore(listing: listedTips)
        let (tips, defaults) = makeTips(store: store)
        await tips.load()
        store.answer(.failure(problem))

        await tips.buy(listedTips[0])
        await settle(tips)

        #expect(tips.problem == .purchaseFailed)
        #expect(tips.ticket == nil)
        #expect(!tips.showsTicket)
        #expect(tips.phase == .idle)
        #expect(TipTicket.load(from: defaults) == nil)
    }

    /// While the tips page is up, its thank-you is shown on the page and not again over the whole app.
    @Test
    @MainActor
    func openPageKeepsTheThankYouOnThePage() async {
        let store = FakeTipStore(listing: listedTips)
        let (tips, _) = makeTips(store: store)
        await tips.load()
        tips.isPageOpen = true
        store.answer(.success(.bought(receipt(0))))

        await tips.buy(listedTips[0])
        await settle(tips)

        #expect(tips.ticket == receipt(0))
        #expect(tips.confirmations == 1)
        #expect(!tips.showsTicket)
    }

    /// Nothing is bought while the App Store sheet of the previous tap is still up.
    @Test
    @MainActor
    func secondTapDuringAPurchaseIsIgnored() async {
        let store = FakeTipStore(listing: listedTips)
        let (tips, _) = makeTips(store: store)
        await tips.load()
        store.hold()

        let first = Task { await tips.buy(tips.products[0]) }
        while tips.phase != .buying(TipPurchases.productIDs[0]) || store.purchases.isEmpty {
            await Task.yield()
        }
        #expect(store.purchases == [TipPurchases.productIDs[0]])

        await tips.buy(tips.products[2])
        #expect(store.purchases == [TipPurchases.productIDs[0]])

        store.release(.success(.bought(receipt(0))))
        await first.value
        #expect(tips.ticket == receipt(0))
        #expect(tips.phase == .idle)
    }

    /// A tip approved while the app was away arrives from the listener: it is the ticket, and its thank-you is queued.
    @Test
    @MainActor
    func laterPurchaseArrivesAsATicket() async {
        let store = FakeTipStore(listing: [])
        let (tips, defaults) = makeTips(store: store)
        tips.start()

        store.continuation.yield(receipt(2))

        for _ in 0 ..< 200 where tips.ticket == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(tips.ticket == receipt(2))
        #expect(tips.showsTicket)
        #expect(tips.confirmations == 1)
        #expect(TipTicket.load(from: defaults) == receipt(2))
        store.continuation.finish()
    }

    /// The ticket of the last tip is still there after a relaunch, without a new thank-you.
    @Test
    @MainActor
    func ticketSurvivesARelaunch() {
        let defaults = freshDefaults()
        let big = receipt(1)
        TipTicket.save(big, to: defaults)

        // A new model over the same defaults, as after a relaunch.
        let afterRelaunch = TipPurchases(productIDs: TipPurchases.productIDs,
                                         store: FakeTipStore(listing: []), defaults: defaults)
        #expect(afterRelaunch.ticket == big)
        #expect(!afterRelaunch.showsTicket)
        #expect(afterRelaunch.confirmations == 0)
    }

    /// An earlier tip coming back is a ticket, not a new purchase: no thank-you.
    @Test
    @MainActor
    func earlierTipComesBackWithoutThankYou() async {
        let older = receipt(0, daysAgo: 30)
        let store = FakeTipStore(listing: listedTips, unfinished: [older])
        let (tips, defaults) = makeTips(store: store)

        await tips.restoreEarlierTips()

        #expect(tips.ticket == older)
        #expect(!tips.showsTicket)
        #expect(!tips.foundNoEarlierTips)
        #expect(tips.confirmations == 0)
        #expect(TipTicket.load(from: defaults) == older)
    }

    /// Restore that finds nothing says so, and a newer ticket already here is not pushed aside.
    @Test
    @MainActor
    func restoreNeverDowngradesTheTicket() async {
        let store = FakeTipStore(listing: listedTips)
        let (tips, _) = makeTips(store: store)
        await tips.restoreEarlierTips()
        #expect(tips.foundNoEarlierTips)
        #expect(tips.ticket == nil)

        store.answer(.success(.bought(receipt(2))))
        await tips.buy(listedTips[2])
        await settle(tips)
        tips.hasShownTicket()
        store.unfinishedTips = [receipt(0, daysAgo: 3)]

        await tips.restoreEarlierTips()

        #expect(tips.ticket == receipt(2))
        #expect(!tips.showsTicket)
        #expect(!tips.foundNoEarlierTips)
        #expect(tips.confirmations == 1)
    }

    /// Restore that finds nothing says so whether or not a ticket is already here.
    @Test
    @MainActor
    func restoreWithATicketStillSaysWhenNothingIsFound() async {
        let store = FakeTipStore(listing: listedTips)
        let (tips, _) = makeTips(store: store)

        store.answer(.success(.bought(receipt(1))))
        await tips.buy(listedTips[1])
        await settle(tips)
        tips.hasShownTicket()

        await tips.restoreEarlierTips()

        #expect(tips.foundNoEarlierTips)
        #expect(tips.ticket == receipt(1))
        #expect(!tips.showsTicket)
        #expect(tips.confirmations == 1)
    }

    /// The line that says Restore found nothing only describes the look just made: opening the page
    /// again, or starting a purchase, clears it.
    @Test
    @MainActor
    func theLineAboutFindingNothingDoesNotOutlastTheLook() async {
        let store = FakeTipStore(listing: listedTips)
        let (tips, _) = makeTips(store: store)

        await tips.restoreEarlierTips()
        #expect(tips.foundNoEarlierTips)

        await tips.load()
        #expect(!tips.foundNoEarlierTips)

        await tips.restoreEarlierTips()
        #expect(tips.foundNoEarlierTips)

        await tips.buy(listedTips[0])
        #expect(!tips.foundNoEarlierTips)
    }

    /// Waits until the condition holds, or gives up quietly.
    @MainActor
    private func until(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A tip the App Store takes back is no longer the ticket: its row goes and no thank-you is waiting.
    @Test
    @MainActor
    func aTipTakenBackIsNoLongerTheTicket() async {
        let store = FakeTipStore(listing: [])
        let (tips, defaults) = makeTips(store: store)
        tips.start()
        store.continuation.yield(receipt(1))
        await until { tips.ticket != nil }
        #expect(tips.ticket == receipt(1) && tips.showsTicket)
        #expect(TipTicket.load(from: defaults) == receipt(1))

        store.refunds.yield(receipt(1).transactionID)
        await until { tips.ticket == nil }

        #expect(tips.ticket == nil)
        #expect(!tips.showsTicket)
        #expect(TipTicket.load(from: defaults) == nil)
        #expect(tips.confirmations == 1)
        store.continuation.finish()
        store.refunds.finish()
    }

    /// A different tip taken back leaves the ticket alone.
    @Test
    @MainActor
    func anotherTipTakenBackChangesNothing() async {
        let store = FakeTipStore(listing: [])
        let (tips, defaults) = makeTips(store: store)
        tips.start()
        store.continuation.yield(receipt(1))
        await until { tips.ticket != nil }
        tips.hasShownTicket()

        store.refunds.yield(receipt(0).transactionID)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(tips.ticket == receipt(1))
        #expect(TipTicket.load(from: defaults) == receipt(1))
        store.continuation.finish()
        store.refunds.finish()
    }

    /// A tip the App Store took back while the app was away stops being the ticket when the person restores.
    @Test
    @MainActor
    func restoreDropsATipTakenBackWhileAway() async {
        let defaults = freshDefaults()
        TipTicket.save(receipt(2), to: defaults)
        let store = FakeTipStore(listing: [], takenBack: [receipt(2).transactionID])
        // A new model over the same defaults, as after a relaunch.
        let afterRelaunch = TipPurchases(productIDs: TipPurchases.productIDs, store: store, defaults: defaults)
        #expect(afterRelaunch.ticket == receipt(2))

        await afterRelaunch.restoreEarlierTips()

        #expect(afterRelaunch.ticket == nil)
        #expect(afterRelaunch.foundNoEarlierTips)
        #expect(TipTicket.load(from: defaults) == nil)
    }

    /// The store is asked for its listener, which starts it, only by `start`, and once. Unit tests drive the
    /// app without calling `start`, so they start no listener.
    @Test
    @MainActor
    func nothingListensToTheStoreBeforeStart() {
        let store = FakeTipStore(listing: [])
        let (tips, _) = makeTips(store: store)
        #expect(store.askedForListener == 0)

        tips.start()
        #expect(store.askedForListener == 1)

        tips.start()
        #expect(store.askedForListener == 1)
    }

    /// The App Store naming again the tip that is already the ticket, as a listener may after a
    /// relaunch, is not a second tip: no second thank-you, and nothing else moves.
    @Test
    @MainActor
    func aTipNamedAgainGetsNoSecondThankYou() async {
        let store = FakeTipStore(listing: listedTips)
        let (tips, _) = makeTips(store: store)
        tips.start()

        store.answer(.success(.bought(receipt(2))))
        await tips.buy(listedTips[2])
        await settle(tips)
        #expect(tips.confirmations == 1)
        tips.hasShownTicket()

        store.continuation.yield(receipt(2))
        try? await Task.sleep(for: .milliseconds(100))

        #expect(tips.confirmations == 1)
        #expect(!tips.showsTicket)
        #expect(tips.ticket == receipt(2))

        // A different tip is still a new tip.
        store.continuation.yield(receipt(0))
        for _ in 0 ..< 200 where tips.confirmations == 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(tips.confirmations == 2)
        #expect(tips.showsTicket)
        store.continuation.finish()
    }

    /// A stored ticket that cannot be read is no ticket, rather than a crash or a wrong one.
    @Test
    @MainActor
    func unreadableTicketIsIgnored() {
        let defaults = freshDefaults()
        defaults.set(Data("not a ticket".utf8), forKey: TipTicket.key)
        #expect(TipTicket.load(from: defaults) == nil)

        // The App Store's number is longer than a number survives some encodings: every digit is kept.
        let exact = TipReceipt(productID: TipPurchases.productIDs[0], transactionID: 20_000_001_234_567_890,
                               purchasedAt: Date(timeIntervalSince1970: 1_800_000_000), displayPrice: "$0.99",
                               amount: Decimal(string: "0.99"), currencyCode: "USD")
        TipTicket.save(exact, to: defaults)
        #expect(TipTicket.load(from: defaults) == exact)

        // The App Store said no price for this one: that is kept too.
        let unpriced = TipReceipt(productID: TipPurchases.productIDs[1], transactionID: 42,
                                  purchasedAt: Date(timeIntervalSince1970: 1_800_000_001), displayPrice: "",
                                  amount: nil, currencyCode: nil)
        TipTicket.save(unpriced, to: defaults)
        #expect(TipTicket.load(from: defaults) == unpriced)
    }
}

/// The three tips the App Store sells, named once.
struct TipProductIDTests {
    @Test
    func productIDsAreTheOnesAppleLists() {
        #expect(TipPurchases.productIDs == [
            "com.jakezai.watchpost.pwvw.tip.alittle",
            "com.jakezai.watchpost.pwvw.tip.extra",
            "com.jakezai.watchpost.pwvw.tip.generous",
        ])
    }
}

/// What turning usage statistics off leaves behind on this device: nothing of the SDK's.
struct StatisticsStoreTests {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsStoreTests.\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The SDK's own folder goes whole, with its install number, its queue and its settings. What
    /// the app itself keeps beside it stays.
    @Test
    func discardRemovesTheSDKFolder() throws {
        let project = "ak_test_\(UUID().uuidString)"
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // As SDK 3.98.2 leaves it: everything inside one folder named after the project.
        let kept = folder.appendingPathComponent(project, isDirectory: true)
        let queue = kept.appendingPathComponent("posthog.queueFolder.uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try Data("waiting".utf8).write(to: queue.appendingPathComponent("an-event.json"))
        for name in ["posthog.deviceId", "posthog.anonymousId", "posthog.optOut", "posthog.remoteConfig"] {
            try Data("x".utf8).write(to: kept.appendingPathComponent(name))
        }
        // The app's own files beside it stay.
        let crashes = folder.appendingPathComponent("AirCrashReports", isDirectory: true)
        try FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true)
        let crash = crashes.appendingPathComponent("a-crash.json")
        try Data("kept".utf8).write(to: crash)
        try Data("kept".utf8).write(to: folder.appendingPathComponent("crash-reports.json"))

        let suite = "StatisticsStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in StatisticsStore.preferenceKeys {
            defaults.set("seen before", forKey: key)
        }
        defaults.set("kept", forKey: "something-else")

        let removed = StatisticsStore.discard(in: folder, project: project, defaults: defaults)

        #expect(removed == [project])
        for key in StatisticsStore.preferenceKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
        #expect(defaults.string(forKey: "something-else") == "kept")
        #expect(!FileManager.default.fileExists(atPath: kept.path))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["AirCrashReports", "crash-reports.json"])
        #expect(try Data(contentsOf: crash) == Data("kept".utf8))

        // Once more is harmless.
        #expect(StatisticsStore.discard(in: folder, project: project).isEmpty)
    }

    /// What an older SDK left loose, every file and folder it names, goes too, and nothing else there.
    @Test
    func discardRemovesWhatOlderSDKsLeftLoose() throws {
        let folder = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = folder.appendingPathComponent("posthog.queueFolder.uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try Data("waiting".utf8).write(to: queue.appendingPathComponent("an-event.json"))
        for name in ["posthog.distinctId", "posthog.anonymousId", "posthog.flags", "posthog.remoteConfig",
                     "posthog.optOut", "posthog.logsFolder"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        // The app's own file in the same folder stays.
        let own = folder.appendingPathComponent("crash-reports.json")
        try Data("kept".utf8).write(to: own)

        let removed = StatisticsStore.discard(in: folder)

        #expect(Set(removed) == ["posthog.queueFolder.uuid", "posthog.distinctId", "posthog.anonymousId",
                                "posthog.flags", "posthog.remoteConfig", "posthog.optOut", "posthog.logsFolder"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["crash-reports.json"])
        #expect(try Data(contentsOf: own) == Data("kept".utf8))

        // Once more is harmless.
        #expect(StatisticsStore.discard(in: folder).isEmpty)
    }

    /// A folder that was never there is nothing to do.
    @Test
    func discardOfAMissingFolderIsNothing() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("StatisticsStoreTests.never.\(UUID().uuidString)")
        #expect(StatisticsStore.discard(in: missing).isEmpty)
    }
}

/// What usage statistics may say, and what its network lets out.
/// One after the other: two of these borrow the app's own switch and carrier, and put them back.
@Suite(.serialized)
struct UsageEventRuleTests {
    private let deviceFacts: [String: Any] = [
        "$app_version": "1.0", "$app_build": "3", "$os_name": "iOS", "$os_version": "18.1",
        "$device_model": "iPhone", "$lib": "posthog-ios", "$lib_version": "3.98.2",
        // What the SDK gathers besides, which must not leave.
        "$device_name": "Jake's iPhone", "$locale": "zh-Hans_CN", "$timezone": "Asia/Shanghai",
        "$network_wifi": true, "$screen_height": 2_000, "$is_emulator": false, "$app_namespace": "com.example",
        "$nested": ["a": "b"], "$app_version_long": String(repeating: "x", count: 200),
    ]

    /// An opening of the app carries the app and system version and nothing about the person.
    @Test(arguments: Array(UsageEventRule.appEvents))
    func appEventsKeepVersionsOnly(event: String) {
        var properties = deviceFacts
        properties["version"] = "1.0"
        properties["build"] = "3"
        properties["from_background"] = true
        properties["previous_version"] = "0.9"
        properties["previous_build"] = "2"
        properties["address"] = "https://vault.example"
        properties["password"] = "hunter2"

        let outgoing = UsageEventRule.outgoingProperties(event: event, of: properties)

        #expect(outgoing?.keys.sorted() == [
            "$app_build", "$app_version", "$device_model", "$geoip_disable", "$is_identified", "$lib",
            "$lib_version", "$os_name", "$os_version", "$process_person_profile", "build", "from_background",
            "previous_build", "previous_version", "version",
        ])
        #expect(outgoing?["$is_identified"] as? Bool == false)
        #expect(outgoing?["$process_person_profile"] as? Bool == false)
        #expect(outgoing?["$geoip_disable"] as? Bool == true)
    }

    /// Anything the SDK might send on its own that is not an opening or a departure is dropped.
    @Test(arguments: ["Button Clicked", "$exception", "$identify", "$set", "$survey_completed",
                      "$feature_flag_called", "$snapshot", "Application Crashed", "Application Closed"])
    func otherEventsAreDropped(event: String) {
        #expect(UsageEventRule.outgoingProperties(event: event, of: deviceFacts) == nil)
    }

    /// A screen is counted under its fixed name, whatever else came along.
    @Test
    func screenPassesUnderItsFixedName() throws {
        var properties = deviceFacts
        properties["$screen_name"] = "Server Form"
        properties["server"] = "vault.example"

        let outgoing = try #require(UsageEventRule.outgoingProperties(event: "$screen", of: properties))

        #expect(outgoing["$screen_name"] as? String == "Server Form")
        #expect(outgoing["server"] == nil)
        #expect(outgoing["$device_name"] == nil)
        #expect(outgoing["$locale"] == nil)
        #expect(outgoing["$timezone"] == nil)
        #expect(outgoing["$app_namespace"] == nil)
        #expect(outgoing["$screen_height"] == nil)
        #expect(outgoing["$nested"] == nil)
        #expect(outgoing["$device_model"] as? String == "iPhone")
    }

    /// A screen name that is not one of the app's, or no name, or no name that is plain text, is not counted.
    @Test(arguments: ["Connect?server=vault.example", "Events/2026-11-25/Sentry", "Playback (1)",
                      "", "Vault", "Servers ", " Playback"])
    func unknownScreenIsDropped(name: String) {
        #expect(UsageEventRule.outgoingProperties(event: "$screen",
                                                  of: ["$screen_name": name]) == nil)
    }

    @Test
    func screenWithoutAPlainNameIsDropped() {
        #expect(UsageEventRule.outgoingProperties(event: "$screen", of: deviceFacts) == nil)
        #expect(UsageEventRule.outgoingProperties(event: "$screen", of: ["$screen_name": 3]) == nil)
    }

    /// Every screen the app has is passed under exactly its own name, and none carries a varying detail.
    @Test
    func everyScreenOfTheAppIsCountedUnderItsFixedName() {
        let names = UsageScreen.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.contains("/") && !$0.contains("?") && !$0.hasPrefix(" ") })
        for screen in UsageScreen.allCases {
            let outgoing = UsageEventRule.outgoingProperties(event: "$screen",
                                                             of: ["$screen_name": screen.rawValue])
            #expect(outgoing?["$screen_name"] as? String == screen.rawValue)
        }
    }

    /// A value that is not plain text or a number does not pass, even under an allowed name.
    @Test
    func nestedAndLongValuesStayBehind() {
        let properties: [String: Any] = ["$app_version": ["1.0"], "$os_name": Date(), "$lib": "ok",
                                         "$os_version": String(repeating: "9", count: 200)]
        let outgoing = UsageEventRule.outgoingProperties(event: "Application Backgrounded", of: properties)
        #expect(outgoing?["$app_version"] == nil)
        #expect(outgoing?["$os_name"] == nil)
        #expect(outgoing?["$os_version"] == nil)
        #expect(outgoing?["$lib"] as? String == "ok")
    }

    /// Only event batches, to the one address, while statistics is on. Everything else the SDK asks for stays home.
    @Test
    func gateLetsOnlyEventsThrough() {
        let address = TrafficGate.host
        let host = address.host
        let door = address.path + "/batch"

        #expect(host == "apps.air.build")
        #expect(address.scheme == "https")
        #expect(TrafficGate.allows(host: host, path: door, isSharing: true))
        #expect(TrafficGate.allows(host: host, path: door + "/", isSharing: true))

        // A path that merely contains the door's name, or adds to it.
        #expect(!TrafficGate.allows(host: host, path: "/batch", isSharing: true))
        #expect(!TrafficGate.allows(host: host, path: door + "/more", isSharing: true))
        #expect(!TrafficGate.allows(host: host, path: door + "?x=1", isSharing: true))

        // The SDK's own questions, which the host does not answer anyway.
        #expect(!TrafficGate.allows(host: host, path: address.path + "/array/<token>/config", isSharing: true))
        #expect(!TrafficGate.allows(host: host, path: address.path + "/flags", isSharing: true))
        #expect(!TrafficGate.allows(host: host, path: address.path + "/s/", isSharing: true))
        #expect(!TrafficGate.allows(host: host, path: address.path + "/i/v1/e", isSharing: true))

        // Statistics off: nothing leaves, not even what was waiting.
        #expect(!TrafficGate.allows(host: host, path: door, isSharing: false))

        // Another address that merely contains the host's name, or none.
        #expect(!TrafficGate.allows(host: "apps.air.build.example.com", path: door, isSharing: true))
        #expect(!TrafficGate.allows(host: "example.com", path: door, isSharing: true))
        #expect(!TrafficGate.allows(host: nil, path: door, isSharing: true))
    }

    /// The gate is installed on the session the SDK is given, and nothing else.
    @Test
    func gateConfigurationCarriesTheGate() throws {
        let configuration = TrafficGate.configuration()
        let gates = try #require(configuration.protocolClasses)
        #expect(gates.count == 1)
        #expect(gates.first == TrafficGateProtocol.self)
    }

    /// The switch starts on, stays as it was left, and does nothing when moved to where it already is.
    @MainActor
    @Test
    func statisticsSwitchSticks() {
        let defaults = UserDefaults(suiteName: "UsageAnalyticsTests.\(UUID().uuidString)")!
        let usage = UsageAnalytics(defaults: defaults)
        #expect(usage.isSharing)

        // Nothing is stored until the person moves the switch.
        #expect(defaults.object(forKey: "usageAnalytics.sharing") == nil)
        usage.setSharing(true)
        #expect(defaults.object(forKey: "usageAnalytics.sharing") == nil)

        usage.setSharing(false)
        #expect(!usage.isSharing)
        #expect(defaults.object(forKey: "usageAnalytics.sharing") as? Bool == false)

        let relaunched = UsageAnalytics(defaults: defaults)
        #expect(!relaunched.isSharing)
        relaunched.setSharing(true)
        #expect(relaunched.isSharing)
        #expect(defaults.object(forKey: "usageAnalytics.sharing") as? Bool == true)
        #expect(UsageAnalytics(defaults: defaults).isSharing)
    }

    /// While statistics is off, a request on the SDK's own session is refused on this device, without the network.
    @Test
    func offSwitchStopsTheSdkSession() async throws {
        let restore = borrowSwitchAndCarrier()
        defer { restore() }
        let standard = UserDefaults.standard

        let session = URLSession(configuration: TrafficGate.configuration())
        let door = TrafficGate.host.appendingPathComponent("batch")

        standard.set(false, forKey: "usageAnalytics.sharing")
        let whileOff = await outcome(session, url: door)
        #expect(whileOff.map(isRefusal) == true, Comment("off: \(describe(whileOff))"))

        // And on, the same session still refuses everything that is not an event batch.
        standard.set(true, forKey: "usageAnalytics.sharing")
        let notAnEvent = await outcome(session, url: TrafficGate.host.appendingPathComponent("flags"))
        #expect(notAnEvent.map(isRefusal) == true, Comment("flags: \(describe(notAnEvent))"))
        let elsewhere = await outcome(session, url: URL(string: "https://apps.air.build/v1/ingest/crashes")!)
        #expect(elsewhere.map(isRefusal) == true, Comment("elsewhere: \(describe(elsewhere))"))
    }

    /// An allowed batch really leaves: the same address, method, type and body arrive at the host,
    /// and the host's answer comes back to the SDK. Refusing was already checked; being carried was not,
    /// and for one build the carrier was never started, so every batch waited until it timed out.
    @Test
    func allowedBatchIsCarriedThrough() async throws {
        let restore = borrowSwitchAndCarrier()
        defer { restore() }
        let standard = UserDefaults.standard

        StatisticsHostStub.asked = []
        TrafficGateProtocol.forwarding = StatisticsHostStub.session
        let session = URLSession(configuration: TrafficGate.configuration())
        let door = TrafficGate.host.appendingPathComponent("batch")
        let body = Data(#"{"api_key":"<redacted>","batch":[{"event":"$screen"}]}"#.utf8)

        standard.set(true, forKey: "usageAnalytics.sharing")
        var request = URLRequest(url: door)
        request.httpMethod = "POST"
        // The SDK's own limit: a batch that is not carried by then is as good as lost.
        request.timeoutInterval = 10
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: body)

        #expect((response as? HTTPURLResponse)?.statusCode == StatisticsHostStub.status)
        #expect(data == StatisticsHostStub.answer)
        #expect(StatisticsHostStub.asked.count == 1,
                Comment("the host was asked \(StatisticsHostStub.asked.count) times"))
        if let asked = StatisticsHostStub.asked.first {
            #expect(asked.url == door)
            #expect(asked.method == "POST")
            #expect(asked.contentType == "application/json; charset=utf-8")
            #expect(asked.body == body, Comment("\(asked.body.count) of \(body.count) bytes arrived"))
        }

        // The same session, statistics off: nothing more is asked of the host.
        standard.set(false, forKey: "usageAnalytics.sharing")
        let whileOff = await outcome(session, url: door)
        #expect(whileOff.map(isRefusal) == true, Comment("off: \(describe(whileOff))"))
        #expect(StatisticsHostStub.asked.count == 1)
    }

    /// The app's own switch and carrier, to move for a moment. Everything else in the app
    /// sees the moved values until the returned closure runs.
    private func borrowSwitchAndCarrier() -> @Sendable () -> Void {
        let had = UserDefaults.standard.object(forKey: "usageAnalytics.sharing") as? Bool
        let carrier = TrafficGateProtocol.forwarding
        return {
            TrafficGateProtocol.forwarding = carrier
            if let had { UserDefaults.standard.set(had, forKey: "usageAnalytics.sharing") }
            else { UserDefaults.standard.removeObject(forKey: "usageAnalytics.sharing") }
        }
    }

    /// The error a request ended with, or nil when it went through.
    private func outcome(_ session: URLSession, url: URL) async -> NSError? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            _ = try await session.data(for: request)
            return nil
        } catch {
            return error as NSError
        }
    }

    private func describe(_ error: NSError?) -> String {
        guard let error else { return "the request went through" }
        let inner = error.userInfo[NSURLErrorFailingURLErrorKey].map { " inner=\($0)" } ?? ""
        return "\(error.domain) \(error.code)\(inner)"
    }

    /// The gate's own error, as the system hands it back: direct, or wrapped with the original beside it.
    private func isRefusal(_ error: NSError?) -> Bool {
        guard let error else { return false }
        let inner = error.userInfo[NSURLErrorFailingURLErrorKey] as? NSError ?? error
        return inner.domain == TrafficGate.refused.domain && inner.code == TrafficGate.refused.code
    }
}

/// Stands where the statistics host is: answers at once and keeps every request it was asked.
private final class StatisticsHostStub: URLProtocol, @unchecked Sendable {
    struct Asked {
        let url: URL?
        let method: String?
        let contentType: String?
        let body: Data
    }

    /// What this host has been asked since the test using it emptied the list.
    nonisolated(unsafe) static var asked: [Asked] = []

    static let status = 200
    static let answer = Data(#"{"status":1}"#.utf8)

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatisticsHostStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? TrafficGateProtocol.body(of: request) ?? Data()
        Self.asked.append(Asked(url: request.url, method: request.httpMethod,
                                contentType: request.value(forHTTPHeaderField: "Content-Type"), body: body))
        let response = HTTPURLResponse(url: request.url ?? TrafficGate.host, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.answer)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
