#if canImport(StoreKitTest)
import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import WatchpostApp

/// The real store against StoreKit Testing, which stands in for the App Store with the tips that
/// `Tips.storekit`, beside this file, lists. The fake store answers as the App Store would, but it
/// cannot say which of Apple's lists a consumable is in, and the fix to Restore rests on exactly that:
/// Apple leaves consumables out of the current entitlements, so the store reads unfinished tips from
/// the unfinished list and refunds from the full history. Here Apple's own lists answer.
/// One test at a time, because a session belongs to the whole process.
@Suite(.serialized)
struct StoreKitTipStoreTests {
    /// The tips as Xcode lists them, found beside this file wherever the sources are checked out.
    /// StoreKit Testing reads the file from disk.
    private static let configuration = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Tips.storekit")

    /// A tip is a consumable, and Apple leaves consumables out of the current entitlements, finished or
    /// not. So Restore, which used to read the current entitlements, could never find a tip. The App
    /// Store holds a tip bought outside the app, as on another device, unfinished: it is in no current
    /// entitlement, and in the unfinished list, where the store looks now. It is reported, finished and
    /// brought back once; a second look finds nothing.
    @Test
    func tipBoughtElsewhereIsInNoEntitlementAndIsRestoredFromTheUnfinishedList() async throws {
        try await withStoreKitTesting { run in
            let productID = TipPurchases.productIDs[1]
            // Bought outside the app, as on another device. The App Store holds it unfinished here.
            let boughtElsewhere = try await run.session.buyProduct(identifier: productID)

            // What the fix rests on: unfinished as it is, the tip is in no current entitlement.
            let entitled = await listed(in: Transaction.currentEntitlements)
            #expect(Set(entitled.map(\.productID)).isDisjoint(with: TipPurchases.productIDs))
            #expect(!entitled.contains(where: { $0.id == boughtElsewhere.id }))
            // It is the unfinished list that names it.
            let unfinished = await listed(in: Transaction.unfinished)
            #expect(unfinished.map(\.id) == [boughtElsewhere.id])

            // Restore finds exactly that tip, and reports it once, verified.
            let found = await run.store.unfinishedTips()
            #expect(found.map(\.productID) == [boughtElsewhere.productID])
            #expect(found.map(\.transactionID) == [boughtElsewhere.id])
            #expect(run.reported.get() == [Reported(verified: true, productID: productID, transactionID: boughtElsewhere.id)])

            // The first look finished the tip, so a second finds nothing and reports nothing more.
            let again = await run.store.unfinishedTips()
            #expect(again.isEmpty)
            #expect(run.reported.get().count == 1)
        }
    }

    /// A tip bought in the app is confirmed by the App Store and reported once, as the purchase it is,
    /// and the receipt names that purchase. Its refund is not made here: StoreKit Testing hands over in
    /// no list a tip bought and finished in the app and then refunded, so that is left to a real device.
    @Test
    func tipBoughtInTheAppIsConfirmedAndReportedOnce() async throws {
        try await withStoreKitTesting { run in
            let productID = TipPurchases.productIDs[2]
            let outcome = try await run.store.purchase(productID)
            let receipt = try #require(confirmedReceipt(of: outcome))
            #expect(receipt.productID == productID)
            #expect(run.reported.get() == [Reported(verified: true, productID: productID, transactionID: receipt.transactionID)])

            // Nothing has been taken back, so the history lists no revoked tip, and Restore finds no refund.
            let takenBack = await run.store.refundedTips()
            #expect(takenBack.isEmpty)
            #expect(run.reported.get().count == 1)
        }
    }

    /// A refund of a tip is in no current entitlement either, for the same reason: no consumable ever
    /// is, and one taken back is not either. The store used to read refunds from there too, so a refund
    /// was only ever heard of through the listener. A refund stays in the full history with the day it
    /// was revoked, which is where the store looks now: Restore finds exactly that tip there, and
    /// nothing to bring back, because a refund is no purchase.
    ///
    /// The tip is bought outside the app, as on another device: StoreKit Testing refunds a purchase made
    /// that way, and Apple documents no other. A tip bought and finished in the app and then refunded,
    /// StoreKit Testing hands over in no list at all, so that shape is left to a real device.
    @Test
    func refundOfATipBoughtElsewhereIsFoundInTheFullHistoryAndInNoEntitlement() async throws {
        try await withStoreKitTesting { run in
            let productID = TipPurchases.productIDs[2]
            let boughtElsewhere = try await run.session.buyProduct(identifier: productID)
            let transactionID = boughtElsewhere.id

            // Nothing has been taken back, so the history lists no revoked tip.
            let before = await run.store.refundedTips()
            #expect(before.isEmpty)

            try run.session.refundTransaction(identifier: UInt(transactionID))
            // The App Store has taken the tip back by now. Apple's unfinished list is read until it says so.
            let settled = await waitUntilTakenBack(transactionID)
            try #require(settled, "StoreKit Testing does not list the tip as taken back")

            // Taken back as it is, the tip is in no current entitlement.
            let entitled = await listed(in: Transaction.currentEntitlements)
            #expect(!entitled.contains(where: { $0.id == transactionID }))

            // The full history still lists it. Restore names it once, and reports it once as what it is now.
            let refunded = await run.store.refundedTips()
            #expect(refunded == [transactionID])
            #expect(run.reported.get() == [Reported(verified: true, productID: productID,
                                                    transactionID: transactionID, revoked: true)])

            // A refund is not a purchase: Restore brings nothing back for it.
            let unfinished = await run.store.unfinishedTips()
            #expect(unfinished.isEmpty)
        }
    }

    /// A refund reaches the app only through the listener, and it arrives as the refund it now is,
    /// never as a purchase: the store reports it as what it is, names the tip it takes back, so the
    /// ticket goes when the refund is of the ticket, and finishes it. Apple does not promise to hand one
    /// transaction over once, so what is checked is every word of the listener, not how many words.
    ///
    /// Disabled, left to a real device with the sandbox: StoreKit Testing does not hand a refund to
    /// the listener the way Apple says it does. The tip is bought outside the app, as on another
    /// device, the only purchase `refundTransaction` covers, and the listener takes that purchase from
    /// the App Store, reports it and finishes it. The refund that follows reaches the running listener
    /// not at all, and is in no list either once the tip is finished. A refund made before the listener
    /// starts, as at launch, it handed to a listener starting later in three different ways and not at
    /// all in the full suite. A tip bought in the app and refunded, finished or not, is in no list.
    /// So the listener's word on a refund is not exercised here.
    @Test(.disabled("StoreKit Testing does not hand a refund to the listener; left to a real device"))
    func listenerHearsTheRefundOfATipBoughtElsewhere() async throws {
        try await withStoreKitTesting { run in
            // Asking for the listener starts it. This keeps what it says.
            let heard = run.listen(to: run.store.laterTips)
            let productID = TipPurchases.productIDs[0]

            // Bought outside the app, as on another device. The App Store tells the listener, which
            // reports it once as the purchase it is, and finishes it.
            let boughtElsewhere = try await run.session.buyProduct(identifier: productID)
            let transactionID = boughtElsewhere.id
            let confirmed = await waitUntil(timeout: .seconds(5)) {
                heard.purchases.get().contains { $0.transactionID == transactionID }
            }
            #expect(confirmed, Comment("The listener did not deliver the purchase made outside the app"))
            #expect(heard.purchases.get().map(\.productID) == [productID])
            #expect(run.reported.get() == [Reported(verified: true, productID: productID, transactionID: transactionID)])
            let purchasesBefore = heard.purchases.get().count

            // Taken back while the listener runs.
            try run.session.refundTransaction(identifier: UInt(transactionID))

            let heardIt = await waitUntil(timeout: .seconds(5)) { heard.refunds.get().contains(transactionID) }
            #expect(heardIt, Comment("The listener did not hear the refund"))
            #expect(heard.refunds.get().allSatisfy { $0 == transactionID })
            // It came as what it is now: no second purchase.
            #expect(heard.purchases.get().count == purchasesBefore)
            let takenBack = Reported(verified: true, productID: productID, transactionID: transactionID, revoked: true)
            #expect(run.reported.get().last == takenBack)
            #expect(run.reported.get().filter { $0.revoked } == [takenBack])

            // The listener finished it: Apple's unfinished list does not hold it.
            let unfinished = await listed(in: Transaction.unfinished)
            #expect(unfinished.allSatisfy { $0.id != transactionID })
        }
    }

    /// Ask to Buy: nothing is bought until the approver says yes. The purchase comes back pending and
    /// the store reports nothing. Once approved, the App Store delivers the purchase to the listener,
    /// which reports it and hands it on as the tip's receipt: that is the only way an approved tip arrives.
    @Test
    func approvedAskToBuyPurchaseArrivesFromTheListener() async throws {
        try await withStoreKitTesting { run in
            run.session.askToBuyEnabled = true
            let heard = run.listen(to: run.store.laterTips)
            let productID = TipPurchases.productIDs[2]

            let outcome = try await run.store.purchase(productID)
            #expect(outcome == .pending)
            #expect(run.reported.get().isEmpty)

            let waiting = await askToBuyPurchase(of: productID, in: run.session)
            let pending = try #require(waiting, "StoreKit Testing lists no purchase waiting for approval")
            try run.session.approveAskToBuyTransaction(identifier: pending.identifier)

            let transactionID = UInt64(pending.identifier)
            let arrived = await waitUntil(timeout: .seconds(5)) {
                heard.purchases.get().contains(where: { $0.transactionID == transactionID })
            }
            #expect(arrived, Comment("The listener did not deliver the approved purchase"))
            #expect(heard.purchases.get().map(\.productID) == [productID])
            #expect(heard.refunds.get().isEmpty)
            #expect(run.reported.get().last == Reported(verified: true, productID: productID, transactionID: transactionID))
        }
    }

    /// An answer the App Store could not verify is trusted with nothing: not reported, not finished, and
    /// not turned into a ticket by Restore either. StoreKit asks that such a transaction be left
    /// unfinished, so it is still there afterwards. StoreKit Testing can fail the verification on
    /// purpose, which is how such an answer is produced here.
    @Test
    func unverifiedPurchaseIsNeitherTrustedNorFinished() async throws {
        try await withStoreKitTesting { run in
            try await run.session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
            let productID = TipPurchases.productIDs[0]

            // The store says the answer could not be verified, and buys nothing.
            var thrown: (any Error)?
            do {
                _ = try await run.store.purchase(productID)
            } catch {
                thrown = error
            }
            #expect((thrown as? TipStoreProblem) == .unverified)
            #expect(run.reported.get().isEmpty)

            // Left unfinished, as StoreKit asks.
            let unfinished = await listed(in: Transaction.unfinished)
            #expect(unfinished.map(\.productID) == [productID])

            // Restore does not pick it up either: nothing comes back, and nothing is reported.
            let found = await run.store.unfinishedTips()
            #expect(found.isEmpty)
            #expect(run.reported.get().isEmpty)
            let takenBack = await run.store.refundedTips()
            #expect(takenBack.isEmpty)
            #expect(run.reported.get().isEmpty)
        }
    }

    /// Runs `body` with the real store over a StoreKit Testing session started from the configuration
    /// file, empty and with no sheets to answer. Nothing a test buys is ever sent to the purchase feed:
    /// for as long as the run lasts the store's reports are counted instead, and the run's end puts
    /// the feed back.
    private func withStoreKitTesting(_ body: (StoreKitTestRun) async throws -> Void,
                                     fileID: String = #fileID, filePath: String = #filePath,
                                     line: Int = #line, column: Int = #column) async throws {
        let session = try SKTestSession(contentsOf: Self.configuration)
        session.disableDialogs = true
        session.clearTransactions()
        let reported = Box<[Reported]>([])
        let feed = PurchaseReporter.sender
        PurchaseReporter.sender = { result in reported.update { $0.append(Reported(result)) } }
        let run = StoreKitTestRun(session: session, reported: reported, feed: feed,
                                  sourceLocation: SourceLocation(fileID: fileID, filePath: filePath,
                                                                 line: line, column: column))
        do {
            try await body(run)
        } catch {
            await run.end()
            throw error
        }
        await run.end()
    }
}

/// The receipt when the App Store confirmed the purchase, or nil when it did not.
private func confirmedReceipt(of outcome: TipPurchaseOutcome) -> TipReceipt? {
    guard case .bought(let receipt) = outcome else { return nil }
    return receipt
}

/// Every transaction one of the App Store's lists hands out, trusted or not. What a list contains is a
/// fact about the list, whatever the app is to make of each entry.
private func listed(in list: Transaction.Transactions) async -> [Transaction] {
    var transactions: [Transaction] = []
    for await result in list {
        switch result {
        case .verified(let transaction), .unverified(let transaction, _):
            transactions.append(transaction)
        }
    }
    return transactions
}

/// The purchase the App Store holds for Ask to Buy approval, as StoreKit Testing lists it, or nil when
/// none shows up within a few seconds.
private func askToBuyPurchase(of productID: String, in session: SKTestSession) async -> SKTestTransaction? {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while true {
        let waiting = session.allTransactions().first {
            $0.productIdentifier == productID && $0.pendingAskToBuyConfirmation
        }
        if let waiting {
            return waiting
        }
        guard clock.now < deadline else { return nil }
        try? await clock.sleep(for: .milliseconds(10))
    }
}

/// Whether Apple's unfinished list shows the transaction as taken back, waited for a few seconds.
/// StoreKit Testing applies a refund to its own records at once and to the lists the app reads a moment
/// later, so the first list read right after a refund can still be the old one.
private func waitUntilTakenBack(_ transactionID: UInt64) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(5)
    while true {
        let takenBack = await listed(in: Transaction.unfinished)
            .contains { $0.id == transactionID && $0.revocationDate != nil }
        if takenBack {
            return true
        }
        guard clock.now < deadline else { return false }
        try? await clock.sleep(for: .milliseconds(20))
    }
}

/// One report the store would have sent to the purchase feed: which transaction it was about, and
/// whether the App Store had verified it. Nothing is sent from a test; this is what was counted.
private struct Reported: Equatable, Sendable {
    var verified: Bool
    var productID: String
    var transactionID: UInt64
    /// The App Store took this tip back, as after a refund.
    var revoked = false
}

private extension Reported {
    /// What the store was handed.
    init(_ result: VerificationResult<Transaction>) {
        switch result {
        case .verified(let transaction):
            self = Reported(transaction, verified: true)
        case .unverified(let transaction, _):
            self = Reported(transaction, verified: false)
        }
    }

    private init(_ transaction: Transaction, verified: Bool) {
        productID = transaction.productID
        transactionID = transaction.id
        revoked = transaction.revocationDate != nil
        self.verified = verified
    }
}

/// What the store's listener said while a test ran, and the means to ask it to stop.
private struct TipsListener: Sendable {
    /// Tips the App Store confirmed while the test ran.
    let purchases: Box<[TipReceipt]>
    /// Tips the App Store took back while the test ran, by its number for the purchase.
    let refunds: Box<[UInt64]>
    /// Set once the store's listener let go of its purchases stream, which it does only when it stops.
    private let stopped: Box<Bool>
    private let hearingPurchases: Task<Void, Never>
    private let hearingRefunds: Task<Void, Never>

    /// Collects both streams. The store's listener is already running: asking for `laterTips` started it.
    static func collecting(_ later: LaterTips) -> TipsListener {
        let purchases = Box<[TipReceipt]>([])
        let refunds = Box<[UInt64]>([])
        let stopped = Box(false)
        let hearingPurchases = Task {
            for await receipt in later.purchases { purchases.update { $0.append(receipt) } }
            stopped.set(true)
        }
        let hearingRefunds = Task {
            for await number in later.refunds { refunds.update { $0.append(number) } }
        }
        return TipsListener(purchases: purchases, refunds: refunds, stopped: stopped,
                            hearingPurchases: hearingPurchases, hearingRefunds: hearingRefunds)
    }

    /// Asks the store's listener to stop, and waits until it has. The store cancels its listener when
    /// either of its streams ends, so letting go of the refunds stream asks. The listener ends the
    /// purchases stream only once it has stopped, so that is what is waited for. Says whether it did.
    func stop() async -> Bool {
        hearingRefunds.cancel()
        let did = await waitUntil(timeout: .seconds(5)) { stopped.get() }
        hearingPurchases.cancel()
        _ = await hearingPurchases.value
        _ = await hearingRefunds.value
        return did
    }
}

/// One test's run against StoreKit Testing: the session that stands in for the App Store, the real
/// store over it, and where the store's reports go instead of the purchase feed.
private final class StoreKitTestRun: Sendable {
    /// The App Store's stand-in. It lives as long as the run, so that every call of the run goes to the
    /// same test store.
    let session: SKTestSession
    let store = StoreKitTipStore(productIDs: TipPurchases.productIDs)
    /// What the store reported during the run, in order.
    let reported: Box<[Reported]>
    /// Where the purchase feed's reports really go, wired back by `end()`.
    private let feed: @Sendable (VerificationResult<Transaction>) -> Void
    /// Every listener a test started, for `end()` to stop.
    private let listeners = Box<[TipsListener]>([])
    /// The test that started the run, for the issue `end()` records when a listener will not stop.
    private let sourceLocation: SourceLocation

    init(session: SKTestSession, reported: Box<[Reported]>,
         feed: @escaping @Sendable (VerificationResult<Transaction>) -> Void, sourceLocation: SourceLocation) {
        self.session = session
        self.reported = reported
        self.feed = feed
        self.sourceLocation = sourceLocation
    }

    /// Starts collecting what the store's listener says, and remembers the collector for `end()`.
    func listen(to later: LaterTips) -> TipsListener {
        let listener = TipsListener.collecting(later)
        listeners.update { $0.append(listener) }
        return listener
    }

    /// Ends the run. The listeners a test started are stopped first, and only once none is left does the
    /// purchase feed get its destination back: a listener still running could otherwise report what the
    /// next test buys, and that would go out for real. One that will not stop leaves the feed unwired,
    /// and an issue says so. The App Store's stand-in is then left empty and as it was found.
    func end() async {
        var everyListenerStopped = true
        for listener in listeners.get() {
            let stopped = await listener.stop()
            if !stopped { everyListenerStopped = false }
        }

        session.clearTransactions()
        session.askToBuyEnabled = false
        try? await session.setSimulatedError(nil, forAPI: .verification)
        session.resetToDefaultState()

        guard everyListenerStopped else {
            Issue.record("A listener of the store did not stop. The purchase feed stays unwired, so that the listener cannot report for real",
                         sourceLocation: sourceLocation)
            return
        }
        PurchaseReporter.sender = feed
    }
}
#endif
