import SwiftUI

/// The App Store's confirmation of one tip, as a small ticket: the amount, when, and the
/// number the App Store's own purchase history shows.
struct ThankYouTicket: View {
    let ticket: TipReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.inner) {
                row(String(localized: "Tip amount", comment: "Thank-you ticket: label above the amount"),
                    value: ticket.displayPrice, isEmphasized: true)
                    .accessibilityIdentifier("thanks.amount")
                row(String(localized: "Tip date", comment: "Thank-you ticket: label above the date"),
                    value: ticket.purchasedAt.formatted(date: .abbreviated, time: .shortened))
                row(String(localized: "App Store transaction number", comment: "Thank-you ticket: label above the App Store's number for the purchase"),
                    value: String(ticket.transactionID), keepsToOneLine: true)
                    .accessibilityIdentifier("thanks.transaction")
            }
            .padding(Metrics.inner)
        }
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thanks.ticket")
    }

    private func row(_ title: String, value: String, isEmphasized: Bool = false, keepsToOneLine: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)
            Text(value)
                .font(isEmphasized ? .title.weight(.bold) : .body.weight(.medium))
                .foregroundStyle(Color.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                // A transaction number shrinks a little rather than being broken across two lines.
                .lineLimit(keepsToOneLine ? 1 : nil)
                .minimumScaleFactor(keepsToOneLine ? 0.6 : 1)
        }
    }
}

/// The thank-you after a tip: the ticket, where Apple's own receipt is, and a way out.
struct ThankYouContent: View {
    let ticket: TipReceipt
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.groupSpacing) {
            Text("Your support keeps Watchpost going.", comment: "Line under the thank-you title after a tip")
                .font(.body)
                .foregroundStyle(Color.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ThankYouTicket(ticket: ticket)

            Text("This ticket is Watchpost's own record. The App Store keeps the receipt in your purchase history.",
                 comment: "Explanation under the thank-you ticket: the app made this record, Apple keeps the receipt")
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Done", action: onDone)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("thanks.done")
        }
    }
}

/// The thank-you on its own, over whatever is on screen, for a tip the App Store confirmed
/// while the tips page was closed.
struct ThankYouSheet: View {
    let ticket: TipReceipt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ThankYouContent(ticket: ticket, onDone: { dismiss() })
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.side)
                    .padding(.bottom, Metrics.side)
            }
            .navigationTitle("Thank you")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("thanks.sheet")
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
