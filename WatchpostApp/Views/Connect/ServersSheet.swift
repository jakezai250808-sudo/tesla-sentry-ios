import SwiftUI

/// A saved server and its deliberately limited presence information. Other
/// servers are never probed just to fill this label.
struct ServerPresenceLabel: View {
    let online: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: online ? "checkmark.circle" : "wifi.exclamationmark")
                .font(.footnote.weight(.medium))
                .foregroundStyle(online ? Color.success : Color.labelSecondary)
                .accessibilityHidden(true)

            if online {
                Text("Online", comment: "The current server answered the last request")
            } else {
                Text("Offline", comment: "No current connection to this saved server")
            }
        }
        .font(.footnote)
        .foregroundStyle(online ? Color.success : Color.labelSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(online ? Text("Online", comment: "The current server answered the last request") : Text("Offline", comment: "No current connection to this saved server"))
    }
}

/// The row used on the connect screen and in the servers sheet. Its main
/// button is one VoiceOver element; More is a separate, named action.
struct SavedServerRow: View {
    let record: ServerRecord
    let online: Bool
    let anyConnectionRunning: Bool
    let thisConnectionRunning: Bool
    let horizontalPadding: CGFloat
    let identifier: String
    let moreIdentifier: String
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onConnect) {
                rowContent
            }
            .buttonStyle(.plain)
            .disabled(anyConnectionRunning)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(record.hostLabel), \(presenceText)"))
            .accessibilityHint(Text("Connects to this server", comment: "VoiceOver hint for a saved-server row"))
            .accessibilityIdentifier(identifier)

            SavedServerMenu(disabled: anyConnectionRunning,
                            identifier: moreIdentifier,
                            onEdit: onEdit,
                            onRemove: onRemove)
        }
        .frame(maxWidth: .infinity)
    }

    private var presenceText: String {
        if thisConnectionRunning {
            String(localized: "Connecting…", comment: "VoiceOver state while this saved server is being connected to")
        } else if online {
            String(localized: "Online", comment: "The current server answered the last request")
        } else {
            String(localized: "Offline", comment: "No current connection to this saved server")
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                host
                rowPresence
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.fieldMinHeight, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 10) {
                host
                Spacer(minLength: 8)
                rowPresence
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.fieldMinHeight, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
    }

    private var host: some View {
        Text(record.hostLabel)
            .font(.body)
            .foregroundStyle(Color.labelPrimary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var rowPresence: some View {
        if thisConnectionRunning {
            HStack(spacing: 6) {
                rowSpinner
                Text("Connecting…", comment: "Saved-server row while its connection attempt is running")
                    .font(.footnote)
                    .foregroundStyle(Color.action)
            }
        } else {
            ServerPresenceLabel(online: online)
        }
    }

    private var rowSpinner: some View {
        ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
    }
}

private struct SavedServerMenu: View {
    let disabled: Bool
    let identifier: String
    let onEdit: () -> Void
    let onRemove: () -> Void

    /// The dots follow the text size up to this point and then stay inside the 44-point target.
    private static let largestSymbol: CGFloat = 24
    @ScaledMetric(relativeTo: .title3) private var symbolSize = 20.0

    var body: some View {
        Menu {
            Button("Edit connection", action: onEdit)
            Button("Remove", role: .destructive, action: onRemove)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: min(symbolSize, Self.largestSymbol), weight: .medium))
                .foregroundStyle(Color.labelPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(Text("More", comment: "More-actions menu on a saved-server row"))
        .accessibilityIdentifier(identifier)
    }
}

/// The full saved-server list, opened from the events screen.
struct ServersSheet: View {
    private enum FormSheet: Identifiable {
        case add
        case edit(ServerRecord)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let record): record.id.uuidString
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var formSheet: FormSheet?
    @State private var recordPendingRemoval: ServerRecord?
    @State private var usage = UsageAnalytics.shared
    @State private var showsFeedback = false
    @State private var showsSupport = false
    @State private var showsRemoveConfirmation = false

    private var isConnecting: Bool {
        model.connectState == .connecting
    }

    private var otherRecords: [ServerRecord] {
        model.store.records
            .filter { $0.id != model.currentRecord?.id }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                currentSection
                savedSection
                actionsSection
                privacySection
                supportSection
                creditSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.cancelConnect()
                        dismiss()
                    }
                }
            }
            .accessibilityIdentifier("servers.sheet")
        }
        .sheet(item: $formSheet, onDismiss: { model.cancelConnect() }) { item in
            switch item {
            case .add:
                ServerFormSheet(record: nil) { formSheet = nil }
            case .edit(let record):
                ServerFormSheet(record: record) { formSheet = nil }
            }
        }
        .sheet(isPresented: $showsFeedback) {
            FeedbackSheet()
        }
        .sheet(isPresented: $showsSupport) {
            SupportDeveloperSheet()
        }
        .confirmationDialog("Remove this server?", isPresented: $showsRemoveConfirmation, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let record = recordPendingRemoval {
                    model.remove(record)
                }
                recordPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { recordPendingRemoval = nil }
        } message: {
            Text("This only removes it from this phone. Nothing on the server is deleted.", comment: "Confirmation that removing a saved server does not delete recordings")
        }
        .onChange(of: model.mode) { _, newMode in
            if case .server = newMode {
                formSheet = nil
                dismiss()
            }
        }
        .onChange(of: model.sessionExpired) { _, expired in
            if expired {
                model.cancelConnect()
                formSheet = nil
                dismiss()
            }
        }
        .onDisappear {
            // Swiping the sheet away is like Done: no attempt keeps running out of sight,
            // and its failure is not shown the next time a form opens.
            model.cancelConnect()
        }
        .usageScreen(.servers)
    }

    private var currentSection: some View {
        Section {
            if model.isDemo {
                HStack(spacing: 12) {
                    Text("Demo", comment: "Current row while viewing the built-in demo")
                        .font(.body)
                        .foregroundStyle(Color.labelPrimary)
                    Spacer()
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.action)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: Metrics.fieldMinHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Demo", comment: "Current row while viewing the built-in demo"))
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("servers.demo")
            }

            if let record = model.currentRecord {
                currentServerRow(record)
            }
        } header: {
            Text("Current", comment: "Section containing the server or demo now in use")
        }
    }

    private func currentServerRow(_ record: ServerRecord) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    currentHost(record)
                    currentPresence
                }
                .frame(maxWidth: .infinity, minHeight: Metrics.fieldMinHeight, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    currentHost(record)
                    Spacer(minLength: 8)
                    currentPresence
                }
                .frame(minHeight: Metrics.fieldMinHeight)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("servers.current")
    }

    private func currentHost(_ record: ServerRecord) -> some View {
        Text(record.hostLabel)
            .font(.body)
            .foregroundStyle(Color.labelPrimary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var currentPresence: some View {
        if let online = model.serverIsOnline {
            ServerPresenceLabel(online: online)
        }
    }

    /// Only when there is something to show: a saved server, or a failed attempt to reach one.
    private var showsSavedSection: Bool {
        if !otherRecords.isEmpty { return true }
        guard case .failed = model.connectState, let target = model.connectTarget else { return false }
        return model.store.record(id: target.recordID) != nil
    }

    @ViewBuilder
    private var savedSection: some View {
        if showsSavedSection {
            savedSectionContent
        }
    }

    private var savedSectionContent: some View {
        Section {
            ForEach(otherRecords) { record in
                SavedServerRow(
                    record: record,
                    online: false,
                    anyConnectionRunning: isConnecting,
                    thisConnectionRunning: isConnecting && model.connectTarget?.recordID == record.id,
                    horizontalPadding: 0,
                    identifier: "servers.item.\(record.id.uuidString)",
                    moreIdentifier: "servers.item.\(record.id.uuidString).more",
                    onConnect: { model.connect(to: record) },
                    onEdit: { formSheet = .edit(record) },
                    onRemove: {
                        recordPendingRemoval = record
                        showsRemoveConfirmation = true
                    }
                )
            }

            if case .failed(let failure) = model.connectState,
               let target = model.connectTarget,
               let record = model.store.record(id: target.recordID) {
                ConnectFailureView(failure: failure)
                Button("Edit connection") {
                    formSheet = .edit(record)
                }
                .buttonStyle(PlainActionButtonStyle())
            }
        } header: {
            Text("Saved servers", comment: "Section containing other saved servers")
        }
    }
    private var actionsSection: some View {
        Section {
            Button {
                formSheet = .add
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle")
                        .font(.body)
                        .foregroundStyle(Color.action)
                        .accessibilityHidden(true)
                    Text("Add server…", comment: "Row that opens the add-server form")
                        .font(.body)
                        .foregroundStyle(Color.labelPrimary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)
            .accessibilityIdentifier("servers.add")

            if model.mode != .connect {
                Button {
                    model.cancelConnect()
                    model.returnToConnect()
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.body)
                            .foregroundStyle(Color.action)
                            .accessibilityHidden(true)
                        Text("Back to connect screen", comment: "Row that leaves demo or the current server for the connect screen")
                            .font(.body)
                            .foregroundStyle(Color.labelPrimary)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("servers.back")
            }
        }
    }

    /// The policy in the same place on every screen: one tap, opened by the system browser.
    /// The usage statistics switch sits beside it, where someone looking for it will look.
    private var privacySection: some View {
        Section {
            Link("Privacy Policy", destination: SupportPages.privacyPolicy)
                .accessibilityIdentifier("servers.privacy")
            Toggle("Share anonymous usage statistics", isOn: Binding(
                get: { usage.isSharing },
                set: { usage.setSharing($0) }
            ))
            .accessibilityIdentifier("servers.statistics")
        } footer: {
            Text("Counts which screens are opened and how often the app runs. Never the server address, the password or the recordings.",
                 comment: "Servers page: what the usage statistics switch covers")
        }
    }

    /// A word to the developer: what went wrong, or a voluntary tip. Both open as sheets.
    private var supportSection: some View {
        Section {
            Button {
                showsFeedback = true
            } label: {
                Label(String(localized: "Send feedback", comment: "Row that opens the feedback form"),
                      systemImage: "exclamationmark.bubble")
            }
            .accessibilityIdentifier("servers.feedback")

            Button {
                showsSupport = true
            } label: {
                Label(String(localized: "Support the developer", comment: "Row that opens the tips page"),
                      systemImage: "heart")
            }
            .accessibilityIdentifier("servers.support")
        }
    }

    private var creditSection: some View {
        Section {
            MadeWithAirBuild()
        }
    }
}
