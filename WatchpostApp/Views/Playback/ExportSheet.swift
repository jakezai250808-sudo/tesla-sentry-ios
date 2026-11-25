import SwiftUI
import UIKit

/// One export, kept across sheet presentations so an interrupted wait can resume the same server job.
struct ExportSheet: View {
    let export: ExportModel
    /// The minute shown on screen, already formatted with a real end only when its length is known.
    let clip: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if model.isDemo {
                        HStack(spacing: 8) {
                            DemoBadge(kind: .data)
                                .accessibilityIdentifier("export.demo-badge")
                            // What goes out here is the real recording itself, not a demo minute with a watermark.
                            if export.event.isRealSample {
                                DemoBadge(kind: .realClip)
                            }
                        }
                    }

                    context

                    phaseContent
                }
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.side)
                .padding(.bottom, Metrics.side)
            }
            .navigationTitle("Export and share")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("export.sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if export.isWorking {
                            export.stopWaiting()
                        }
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Cancel")
                    .accessibilityIdentifier("export.close")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .task { await export.open() }
        .onChange(of: export.phase, initial: true) { _, phase in
            detent = Self.detent(for: phase)
        }
        .onDisappear {
            // The server has no cancel API: ending the sheet only ends this wait.
            if export.isWorking {
                export.stopWaiting()
            }
        }
        .usageScreen(.export)
    }

    private static func detent(for phase: ExportModel.Phase) -> PresentationDetent {
        switch phase {
        case .idle, .checking:
            .medium
        case .generating, .downloading, .ready, .failed, .stoppedWaiting:
            .large
        }
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: 8) {
            if export.event.isRealSample {
                // No camera and no quality to name: the file goes out as it ships.
                Text(verbatim: clip)
                    .font(.subheadline)
                    .foregroundStyle(Color.labelPrimary)

                Text("The real recording as it is in the app, credit included. Nothing is added.",
                     comment: "Explains the fixed scope of an export of the demo's real recording")
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
            } else {
                HStack(spacing: 0) {
                    Text(export.video.camera.title)
                    Text(" · ", comment: "Separator between camera, clip and quality")
                    Text(verbatim: clip)
                    Text(" · ", comment: "Separator between camera, clip and quality")
                    Text(verbatim: export.quality.title)
                }
                .font(.subheadline)
                .foregroundStyle(Color.labelPrimary)

                Text("One minute, one camera, with a watermark.", comment: "Explains the fixed scope of an export")
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("export.context")
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch export.phase {
        case .checking:
            HStack(spacing: 12) {
                generateButton
                    .disabled(true)
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.action)
            }

        case .idle:
            if export.watermarkUnavailable {
                watermarkUnavailable
            } else {
                generateButton
                    .disabled(!export.canGenerate)
            }

        case let .generating(percent):
            let detail = percent.map { String(format: "%d %%", $0) }
            progress(title: "Exporting…", fraction: Self.fraction(percent: percent), detail: detail)

        case let .downloading(received, total):
            progress(title: "Downloading…", fraction: Self.fraction(received: received, total: total),
                     detail: downloadDetail(received: received, total: total))

        case .ready:
            ready

        case let .failed(failure):
            if failure == .watermarkUnavailable {
                watermarkUnavailable
            } else {
                failureContent(expired: failure == .expired)
            }

        case .stoppedWaiting:
            VStack(alignment: .leading, spacing: 16) {
                Text("Stopped waiting. The server may still be generating.",
                     comment: "The sheet was closed while an export was running")
                    .font(.body)
                    .foregroundStyle(Color.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    export.start()
                } label: {
                    Text("Wait again", comment: "Resume waiting for the existing export job")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("export.wait-again")

                Button {
                    export.discardJob()
                    export.start()
                } label: {
                    Text("Start over", comment: "Forget the old export job and make a new one")
                }
                .buttonStyle(PlainActionButtonStyle())
                .accessibilityIdentifier("export.start-over")
            }
        }
    }

    private var generateButton: some View {
        Button {
            export.start()
        } label: {
            Text("Generate video", comment: "Start exporting the current minute with a watermark")
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityIdentifier("export.generate")
    }

    private var watermarkUnavailable: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your server can't add a watermark right now",
                 comment: "The server lacks what it needs for a watermarked export")
                .font(.subheadline)
                .foregroundStyle(Color.errorToken)
                .fixedSize(horizontal: false, vertical: true)

            generateButton
                .disabled(true)

            if let page = model.serverPage {
                Button {
                    UIApplication.shared.open(page)
                } label: {
                    Label("Open in browser", systemImage: "safari")
                }
                .buttonStyle(PlainActionButtonStyle())
                .accessibilityIdentifier("export.browser")
            }
        }
    }

    private func progress(title: LocalizedStringKey, fraction: Double?, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.labelPrimary)

            if let fraction {
                ProgressView(value: fraction, total: 100)
                    .tint(Color.action)
                    .accessibilityIdentifier("export.progress")
                    .accessibilityValue(Text(verbatim: detail ?? ""))
            } else {
                ProgressView()
                    .tint(Color.action)
                    .accessibilityIdentifier("export.progress")
            }

            if let detail {
                Text(verbatim: detail)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Color.labelSecondary)
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Video ready", comment: "The watermarked export has finished downloading")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.labelPrimary)

            if let url = export.fileURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("export.share")
            }

            Button {
                dismiss()
            } label: {
                Text("Done", comment: "Close the export sheet after sharing")
            }
            .buttonStyle(PlainActionButtonStyle())
            .accessibilityIdentifier("export.done")
        }
    }

    private func failureContent(expired: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if expired {
                Text("The export is no longer on the server. Generate it again.",
                     comment: "The export job expired before it was downloaded")
                    .font(.body)
                    .foregroundStyle(Color.errorToken)
                    .accessibilityIdentifier("export.failure")
            } else {
                Text("Export failed. Try again later.", comment: "A general export or download failure")
                    .font(.body)
                    .foregroundStyle(Color.errorToken)
                    .accessibilityIdentifier("export.failure")
            }

            Button {
                export.retry()
            } label: {
                Text("Retry", comment: "Try the export or download again")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("export.retry")
        }
    }

    private func downloadDetail(received: Int64, total: Int64?) -> String {
        let receivedText = Self.byteText(received)
        guard let total else { return receivedText }
        return "\(receivedText) / \(Self.byteText(total))"
    }

    private static func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    private static func fraction(percent: Int?) -> Double? {
        guard let percent, (0...100).contains(percent) else { return nil }
        return Double(percent)
    }

    private static func fraction(received: Int64, total: Int64?) -> Double? {
        guard let total, total > 0, received >= 0, received <= total else { return nil }
        return Double(received) / Double(total) * 100
    }
}
