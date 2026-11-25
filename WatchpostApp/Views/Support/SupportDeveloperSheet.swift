import SwiftUI

/// The tips page: three voluntary amounts, the button that buys the chosen one, and the
/// thank-you once the App Store confirms it. Connecting, playback and export stay free,
/// and a tip unlocks nothing.
struct SupportDeveloperSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tips = TipPurchases.shared
    /// The row the person chose. Nothing is chosen until they pick one.
    @State private var chosenID: String?
    /// A tip went through while this page was up, so the thank-you shows here.
    @State private var showsThankYou = false

    private var chosen: TipProduct? {
        tips.products.first { $0.id == chosenID }
    }

    private var isBusy: Bool {
        tips.phase != .idle
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.groupSpacing) {
                    if showsThankYou, let ticket = tips.ticket {
                        ThankYouContent(ticket: ticket, onDone: { dismiss() })
                    } else {
                        tipsPage
                    }
                }
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.side)
                .padding(.bottom, Metrics.side)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("support.sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("support.close")
                }
            }
        }
        .usageScreen(.support)
        .task { await tips.load() }
        .onAppear { tips.isPageOpen = true }
        .onDisappear { tips.isPageOpen = false }
        .onChange(of: tips.confirmations) { _, _ in
            showsThankYou = true
        }
        .onChange(of: tips.showsTicket, initial: true) { _, waiting in
            // A thank-you that was still waiting when this page opened is shown here.
            if waiting {
                showsThankYou = true
                tips.hasShownTicket()
            }
        }
    }

    private var title: String {
        showsThankYou
            ? String(localized: "Thank you", comment: "Title of the thank-you after a tip")
            : String(localized: "Support the developer", comment: "Title of the tips page")
    }

    private var tipsPage: some View {
        VStack(alignment: .leading, spacing: Metrics.groupSpacing) {
            Text("Tips are voluntary. Connecting, playback and export stay free, and a tip unlocks nothing.",
                 comment: "First line of the tips page")
                .font(.body)
                .foregroundStyle(Color.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            amounts

            supportButton

            if let ticket = tips.ticket {
                latestTip(ticket)
            }

            if tips.isAwaitingApproval {
                Text("Your tip is waiting for approval in the App Store. The thank-you comes once it goes through.",
                     comment: "Tips page: an Ask to Buy approval is still pending")
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("support.pending")
            }

            if tips.foundNoEarlierTips {
                Text("No earlier tips were found for this Apple Account.",
                     comment: "Tips page: Restore Purchases found nothing")
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("support.restore-empty")
            }

            Button("Restore purchases") {
                Task { await tips.restoreEarlierTips() }
            }
            .buttonStyle(PlainActionButtonStyle())
            .disabled(isBusy)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("support.restore")
        }
    }

    @ViewBuilder
    private var amounts: some View {
        if tips.products.isEmpty, tips.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .accessibilityIdentifier("support.loading")
        } else if tips.products.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tips can't be loaded right now.", comment: "Tips page: the App Store could not be reached")
                    .font(.body)
                    .foregroundStyle(Color.labelPrimary)
                Button("Try again") {
                    Task { await tips.load() }
                }
                .buttonStyle(PlainActionButtonStyle())
                .accessibilityIdentifier("support.retry")
            }
        } else {
            ForEach(Array(tips.products.enumerated()), id: \.element.id) { index, product in
                tierRow(product, number: index)
            }

            if tips.problem == .purchaseFailed {
                Text("The purchase didn't complete, so nothing was paid.",
                     comment: "Tips page: the purchase failed")
                    .font(.footnote)
                    .foregroundStyle(Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("support.failure")
            }
        }
    }

    private func tierRow(_ product: TipProduct, number: Int) -> some View {
        let isChosen = product.id == chosenID
        return Button {
            chosenID = product.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isChosen ? Color.action : Color.labelSecondary)
                    .accessibilityHidden(true)

                if dynamicTypeSize.isAccessibilitySize {
                    // One under the other: side by side, the price would be broken across two lines.
                    VStack(alignment: .leading, spacing: 4) {
                        tierNameText(number)
                        priceText(product)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    tierNameText(number)

                    Spacer(minLength: 8)

                    priceText(product)
                }
            }
            .padding(.horizontal, Metrics.inner)
            .frame(minHeight: 56)
            .background(
                isChosen ? Color.selectionFill : Color.surface,
                in: RoundedRectangle(cornerRadius: Metrics.primaryCorner, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.primaryCorner, style: .continuous)
                    .strokeBorder(isChosen ? Color.action : Color.separatorToken, lineWidth: isChosen ? 1.5 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.primaryCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier("support.tier.\(number)")
    }

    private func tierNameText(_ number: Int) -> some View {
        Text(tierName(number))
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.labelPrimary)
    }

    /// A price always shows whole: it keeps to one line, and the name beside it gives way first.
    private func priceText(_ product: TipProduct) -> some View {
        Text(product.displayPrice)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.labelPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .layoutPriority(1)
    }

    private func tierName(_ number: Int) -> String {
        switch number {
        case 1: String(localized: "More Support", comment: "Name of the middle tip")
        case 2: String(localized: "Extra Support", comment: "Name of the largest tip")
        default: String(localized: "A Little Support", comment: "Name of the smallest tip")
        }
    }

    private var latestTipLabel: some View {
        Text("Latest tip", comment: "Tips page: label before the newest tip on this device")
    }

    private func latestTipValue(_ ticket: TipReceipt) -> some View {
        Text("\(ticket.displayPrice) · \(ticket.purchasedAt.formatted(date: .abbreviated, time: .omitted))")
    }

    private var supportButton: some View {
        Button {
            if let chosen {
                Task { await tips.buy(chosen) }
            }
        } label: {
            if let chosen {
                Text("Support \(chosen.displayPrice)", comment: "Button that buys the chosen tip; the price follows")
            } else {
                Text("Support", comment: "Button on the tips page, before a tip is chosen")
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(chosen == nil || isBusy || tips.products.isEmpty)
        .accessibilityIdentifier("support.buy")
    }

    private func latestTip(_ ticket: TipReceipt) -> some View {
        // Label and value share a line when they fit, and take one each when they do not.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                latestTipLabel
                Spacer(minLength: 12)
                latestTipValue(ticket)
            }
            VStack(alignment: .leading, spacing: 4) {
                latestTipLabel
                latestTipValue(ticket)
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.labelSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("support.latest")
    }
}
