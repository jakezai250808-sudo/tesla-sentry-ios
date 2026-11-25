import Foundation
import StoreKit

/// One tip as the App Store lists it for this buyer.
struct TipProduct: Equatable, Identifiable, Sendable {
    let id: String
    /// The price exactly as the App Store writes it: "¥6.00", "$0.99".
    let displayPrice: String
    /// The same price as a plain number in the buyer's currency, when the store gives one.
    let amount: Decimal?
    /// The buyer's currency, as "CNY", when the store gives one.
    let currencyCode: String?
}

/// What the App Store confirms about one purchase.
struct TipReceipt: Equatable, Sendable {
    let productID: String
    /// The App Store's number for the purchase, which its purchase history shows too.
    let transactionID: UInt64
    let purchasedAt: Date
    let displayPrice: String
    let amount: Decimal?
    let currencyCode: String?
}

enum TipPurchaseOutcome: Equatable, Sendable {
    case bought(TipReceipt)
    /// The App Store is still waiting, for an Ask to Buy approval. Nothing is bought yet.
    case pending
    /// The person closed the App Store sheet.
    case cancelled
}

/// Why the store could not do what was asked.
enum TipStoreProblem: Error, Equatable, Sendable {
    /// The App Store does not list this tip for this buyer.
    case missingProduct
    /// The App Store's answer could not be verified, so it is not trusted.
    case unverified
}

/// The App Store's later word on tips, both from one listener.
struct LaterTips: Sendable {
    /// Tips it confirms, as when Ask to Buy is approved. Each is reported and finished before it arrives.
    var purchases: AsyncStream<TipReceipt>
    /// Tips it takes back, a refund, by the App Store's number for the purchase. Covers refunds of tips
    /// this device finished, which only the full history still lists.
    /// Each is reported and finished before it arrives.
    var refunds: AsyncStream<UInt64>
}

/// What the tips need from the App Store. `StoreKitTipStore` is the real one; tests use a fake.
protocol TipStore: Sendable {
    func products() async throws -> [TipProduct]
    /// Buys one tip. Returns once the App Store sheet is gone.
    func purchase(_ productID: String) async throws -> TipPurchaseOutcome
    /// Tips the App Store still holds unfinished for this Apple account, because they were
    /// bought on another device or while the app was closed. Each is reported and finished.
    func unfinishedTips() async -> [TipReceipt]
    /// Tips the App Store took back and still lists for this Apple account, by its number for the purchase.
    func refundedTips() async -> [UInt64]
    /// Asks for the listener. Asking starts it, once.
    var laterTips: LaterTips { get }
}

extension TipStore {
    func refundedTips() async -> [UInt64] { [] }
}

/// The App Store behind the tips. Every purchase it hands out is reported to the
/// purchase feed and finished. One the App Store could not verify is left unfinished
/// and not trusted, as StoreKit asks. One Apple took back, a refund, is reported and
/// finished too, but it is no tip here: it never shows a thank-you or becomes the ticket,
/// and when it is the ticket, the ticket is gone. Watchpost has no accounts, so Apple is
/// given no account to record with a purchase.
struct StoreKitTipStore: TipStore {
    let productIDs: [String]

    func products() async throws -> [TipProduct] {
        let found = try await Product.products(for: productIDs)
        // The app's order, cheapest first; a tip this storefront does not sell is left out.
        return productIDs.compactMap { id in found.first { $0.id == id } }.map(Self.listing)
    }

    func purchase(_ productID: String) async throws -> TipPurchaseOutcome {
        let found = try await Product.products(for: [productID])
        guard let product = found.first else { throw TipStoreProblem.missingProduct }
        switch try await product.purchase() {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { throw TipStoreProblem.unverified }
            PurchaseReporter.report(verification)
            await transaction.finish()
            return .bought(Self.receipt(transaction, pricedAs: product))
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    /// A tip is a consumable, and Apple leaves consumables out of the current entitlements: read from
    /// there this always came back empty, so Restore could never find a tip. The unfinished list is
    /// where Apple says to look. One the App Store has already revoked is left for `refundedTips`.
    func unfinishedTips() async -> [TipReceipt] {
        var receipts: [TipReceipt] = []
        for await verification in Transaction.unfinished {
            guard case .verified(let transaction) = verification,
                  productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil else { continue }
            PurchaseReporter.report(verification)
            let receipt = Self.receipt(transaction, pricedAs: nil)
            await transaction.finish()
            receipts.append(receipt)
        }
        return receipts
    }

    /// A refund stays in the full history with the day it was revoked, and the current entitlements
    /// drop it: read from there this always came back empty too, so a refund was only ever heard of
    /// through the listener. Only revoked tips are touched here; a purchase still unfinished is left
    /// whole for `unfinishedTips`, which turns it into the ticket.
    func refundedTips() async -> [UInt64] {
        var numbers: [UInt64] = []
        var seen: Set<UInt64> = []
        for await verification in Transaction.all {
            guard case .verified(let transaction) = verification,
                  productIDs.contains(transaction.productID),
                  transaction.revocationDate != nil,
                  seen.insert(transaction.id).inserted else { continue }
            PurchaseReporter.report(verification)
            await transaction.finish()
            numbers.append(transaction.id)
        }
        return numbers
    }

    /// One listener, two streams. It starts when this is first read, which the app does once at launch
    /// and not at all while unit tests run the app.
    var laterTips: LaterTips {
        let purchases = AsyncStream<TipReceipt>.makeStream()
        let refunds = AsyncStream<UInt64>.makeStream()
        let task = Task.detached {
            for await verification in Transaction.updates {
                guard case .verified(let transaction) = verification else { continue }
                PurchaseReporter.report(verification)
                let isTip = productIDs.contains(transaction.productID)
                let receipt = isTip && transaction.revocationDate == nil
                    ? Self.receipt(transaction, pricedAs: nil) : nil
                await transaction.finish()
                if let receipt {
                    purchases.continuation.yield(receipt)
                } else if isTip {
                    refunds.continuation.yield(transaction.id)
                }
            }
            purchases.continuation.finish()
            refunds.continuation.finish()
        }
        refunds.continuation.onTermination = { _ in task.cancel() }
        purchases.continuation.onTermination = { _ in task.cancel() }
        return LaterTips(purchases: purchases.stream, refunds: refunds.stream)
    }

    private static func listing(_ product: Product) -> TipProduct {
        let code = product.priceFormatStyle.currencyCode
        return TipProduct(id: product.id, displayPrice: product.displayPrice,
                          amount: product.price, currencyCode: code.isEmpty ? nil : code)
    }

    private static func receipt(_ transaction: Transaction, pricedAs product: Product?) -> TipReceipt {
        let currency = transaction.currency ?? product.map { Locale.Currency($0.priceFormatStyle.currencyCode) }
        let amount = transaction.price ?? product?.price
        let written = amount.map { priceText($0, currency: currency) }
        return TipReceipt(
            productID: transaction.productID,
            transactionID: transaction.id,
            purchasedAt: transaction.purchaseDate,
            // What the App Store writes for the listing when it is known, else for this purchase.
            displayPrice: product?.displayPrice ?? written ?? "",
            amount: amount,
            currencyCode: currency?.identifier
        )
    }

    /// A price in its currency, or as a plain number when the App Store did not say which.
    private static func priceText(_ amount: Decimal, currency: Locale.Currency?) -> String {
        guard let currency else { return amount.formatted() }
        return amount.formatted(Decimal.FormatStyle.Currency(code: currency.identifier))
    }
}
