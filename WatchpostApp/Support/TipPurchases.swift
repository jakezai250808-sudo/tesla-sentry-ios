import Foundation
import Observation

/// What went wrong on the tips screen, in the person's terms.
enum TipProblem: Equatable {
    /// The App Store could not be reached, or sells none of the tips to this buyer.
    case unavailable
    /// A purchase started but did not complete, so nothing was paid.
    case purchaseFailed
}

/// The three voluntary tips: what they cost, buying one, and the ticket the newest one
/// left. A tip unlocks nothing, so nothing else in the app waits on this.
@MainActor
@Observable
final class TipPurchases {
    enum Phase: Equatable {
        case idle
        /// The App Store sheet is up for this tip.
        case buying(String)
    }

    /// The tips the App Store sells for Watchpost, cheapest first.
    nonisolated static let productIDs = [
        "com.jakezai.watchpost.pwvw.tip.alittle",
        "com.jakezai.watchpost.pwvw.tip.extra",
        "com.jakezai.watchpost.pwvw.tip.generous",
    ]

    static let shared = TipPurchases(productIDs: productIDs, store: StoreKitTipStore(productIDs: productIDs))

    let productIDs: [String]
    private(set) var products: [TipProduct] = []
    private(set) var isLoading = false
    private(set) var phase = Phase.idle
    private(set) var problem: TipProblem?
    /// The newest tip the App Store confirmed here. Nil until the first one.
    private(set) var ticket: TipReceipt?
    /// An earlier tip is still waiting for the App Store's approval.
    private(set) var isAwaitingApproval = false
    /// The last look for older tips found none.
    private(set) var foundNoEarlierTips = false
    /// How many tips the App Store confirmed this launch. The tips page watches it to
    /// show the thank-you itself when the tip was bought there.
    private(set) var confirmations = 0
    /// A tip just went through and its thank-you has not been shown yet.
    var showsTicket = false
    /// The tips page is on screen, so a thank-you is shown there and not over the whole app.
    var isPageOpen = false

    private let store: any TipStore
    private let defaults: UserDefaults
    private var listener: Task<Void, Never>?

    init(productIDs: [String], store: any TipStore, defaults: UserDefaults = .standard) {
        self.productIDs = productIDs
        self.store = store
        self.defaults = defaults
        ticket = TipTicket.load(from: defaults)
    }

    /// Once per launch: keeps listening for purchases the App Store finishes later, and for tips it
    /// takes back. It starts the store's listener, so nothing listens at all until this is called.
    func start() {
        guard listener == nil else { return }
        let later = store.laterTips
        listener = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await receipt in later.purchases { await self?.confirm(receipt) }
                }
                group.addTask {
                    for await number in later.refunds { await self?.takeBack(number) }
                }
            }
        }
    }

    /// Asks the App Store what the tips cost for this buyer. Safe to call on every open.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        problem = nil
        // The page opens with this: what an earlier look for tips found is no news now.
        foundNoEarlierTips = false
        do {
            // The app's own order, whatever order the store answers in.
            let order = productIDs
            products = try await store.products().sorted { lhs, rhs in
                let rank = { (id: String) in order.firstIndex(of: id) ?? order.count }
                return rank(lhs.id) < rank(rhs.id)
            }
            if products.isEmpty { problem = .unavailable }
        } catch {
            problem = .unavailable
        }
        isLoading = false
    }

    func buy(_ product: TipProduct) async {
        guard phase == .idle else { return }
        phase = .buying(product.id)
        problem = nil
        // What a look for earlier tips found says nothing about this purchase.
        foundNoEarlierTips = false
        do {
            switch try await store.purchase(product.id) {
            case .bought(let receipt):
                confirm(receipt)
            case .pending:
                isAwaitingApproval = true
            case .cancelled:
                break
            }
        } catch {
            problem = .purchaseFailed
        }
        phase = .idle
    }

    /// Asks the App Store for tips this Apple account bought that this device has not
    /// seen, so an earlier ticket comes back. Nothing is bought.
    func restoreEarlierTips() async {
        // A tip the App Store took back is no longer the newest tip, whatever else comes back.
        for number in await store.refundedTips() { takeBack(number) }
        let found = await store.unfinishedTips()
        foundNoEarlierTips = found.isEmpty
        // An earlier tip coming back is not a new thank-you.
        if let newest = found.max(by: { $0.purchasedAt < $1.purchasedAt }), isUnseen(newest) {
            ticket = newest
            TipTicket.save(newest, to: defaults)
        }
    }

    func hasShownTicket() {
        showsTicket = false
    }

    /// A tip the App Store just confirmed, bought here or approved after a wait. It is no longer
    /// waiting, it becomes the ticket and its thank-you is queued. The App Store naming the tip
    /// that is already the ticket changes nothing: a thank-you comes once per tip.
    private func confirm(_ receipt: TipReceipt) {
        guard receipt.transactionID != ticket?.transactionID else { return }
        isAwaitingApproval = false
        ticket = receipt
        TipTicket.save(receipt, to: defaults)
        confirmations += 1
        showsTicket = !isPageOpen
    }

    /// The App Store took a tip back. When that tip is the ticket there is no newest tip any more:
    /// its row goes, and no thank-you is waiting for it. Another tip taken back changes nothing here.
    private func takeBack(_ transactionID: UInt64) {
        guard ticket?.transactionID == transactionID else { return }
        ticket = nil
        showsTicket = false
        TipTicket.clear(in: defaults)
    }

    private func isUnseen(_ receipt: TipReceipt) -> Bool {
        guard let ticket else { return true }
        return receipt.purchasedAt > ticket.purchasedAt
    }
}

/// The last ticket, kept on this device so it is still there after a relaunch.
/// The App Store's number is stored as text: it is longer than a number survives some encodings.
enum TipTicket {
    private struct Stored: Codable {
        var productID: String
        var transactionID: String
        var purchasedAt: Date
        var displayPrice: String
        var amount: String?
        var currencyCode: String?
    }

    static let key = "tips.ticket"

    static func load(from defaults: UserDefaults) -> TipReceipt? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return decode(try? JSONDecoder().decode(Stored.self, from: data))
    }

    static func clear(in defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
    }

    static func save(_ receipt: TipReceipt, to defaults: UserDefaults) {
        let stored = Stored(productID: receipt.productID,
                            transactionID: String(receipt.transactionID),
                            purchasedAt: receipt.purchasedAt,
                            displayPrice: receipt.displayPrice,
                            amount: receipt.amount.map { "\($0)" },
                            currencyCode: receipt.currencyCode)
        defaults.set(try? JSONEncoder().encode(stored), forKey: key)
    }

    private static func decode(_ stored: Stored?) -> TipReceipt? {
        guard let stored, let transactionID = UInt64(stored.transactionID) else { return nil }
        return TipReceipt(productID: stored.productID,
                          transactionID: transactionID,
                          purchasedAt: stored.purchasedAt,
                          displayPrice: stored.displayPrice,
                          amount: stored.amount.flatMap { Decimal(string: $0) },
                          currencyCode: stored.currencyCode)
    }
}
