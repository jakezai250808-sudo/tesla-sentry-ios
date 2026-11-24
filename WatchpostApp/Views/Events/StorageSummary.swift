import SwiftUI

/// The archive line from the server's live status. Unknown values stay unknown.
struct StorageSummary: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var unavailable: Bool {
        model.statusUnavailable || model.status == nil
    }

    private var archiveValue: String {
        guard !unavailable,
              let used = model.status?.archiveUsedBytes,
              let limit = model.status?.archiveLimitBytes else { return Display.missing }
        return Display.storage(used) + " / " + Display.storage(limit)
    }

    private var nearlyFull: Bool {
        !unavailable && model.status?.isArchiveNearlyFull == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            archiveHeading
            archiveBar
            syncLine
        }
        .padding(Metrics.inner)
        .card()
        .accessibilityIdentifier("events.storage")
    }

    @ViewBuilder
    private var archiveHeading: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                archiveLabels
                archiveValueText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .top) {
                archiveLabels
                Spacer(minLength: 12)
                archiveValueText
            }
        }
    }

    private var archiveLabels: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Archive storage")
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)
            if nearlyFull {
                Text("Low on space")
                    .font(.footnote)
                    .foregroundStyle(Color.warning)
            }
        }
    }

    private var archiveValueText: some View {
        Text(archiveValue)
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(Color.labelPrimary)
            .accessibilityIdentifier("events.storage.value")
    }

    @ViewBuilder
    private var archiveBar: some View {
        if !unavailable, let fraction = model.status?.archiveFraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(nearlyFull ? .warning : .action)
                .frame(height: 4)
                .accessibilityLabel("Archive storage")
                .accessibilityValue(archiveValue)
        } else {
            Color.clear.frame(height: 4)
        }
    }

    @ViewBuilder
    private var syncLine: some View {
        Group {
            if unavailable {
                Text("Unavailable")
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
            } else if model.status?.syncRunning == true {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Syncing")
                        .font(.footnote)
                        .foregroundStyle(Color.labelPrimary)
                }
                .accessibilityElement(children: .combine)
            } else if let seconds = model.status?.lastSyncAgo {
                (Text("Last synced") + Text(" \(Display.ago(seconds))"))
                    .font(.footnote)
                    .foregroundStyle(Color.labelPrimary)
            } else {
                Text(Display.missing)
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
            }
        }
        .accessibilityIdentifier("events.sync")
    }
}
