import SwiftUI

struct ConnectScreen: View {
    @Environment(AppModel.self) private var model

    @FocusState private var focusedField: ConnectForm.Field?
    @State private var editingRecord: ServerRecord?
    @State private var recordPendingRemoval: ServerRecord?
    @State private var showsRemoveConfirmation = false
    @State private var savedAttemptID: UUID?
    @State private var showsFeedback = false
    @State private var showsSupport = false

    private var isConnecting: Bool {
        model.connectState == .connecting
    }

    private var visibleRecords: [ServerRecord] {
        Array(model.store.records.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(3))
    }

    private var failedSavedRecord: ServerRecord? {
        guard case .failed = model.connectState,
              let savedAttemptID,
              let target = model.connectTarget,
              target.recordID == savedAttemptID else { return nil }
        return model.store.record(id: target.recordID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                appMark
                    .padding(.bottom, Metrics.groupSpacing)

                Text("Connect to your server", comment: "Title of the connect screen")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Color.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connect.title")
                    .padding(.bottom, 8)

                Text("See the recordings on your own server.", comment: "Explanation under the connect-screen title")
                    .font(.body)
                    .foregroundStyle(Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Metrics.groupSpacing)

                ConnectForm(model: model, focus: $focusedField) { model.connect() }

                ConnectActionButton(connecting: isConnecting,
                                    enabled: model.canSubmit,
                                    cancelsWhileConnecting: true,
                                    identifier: "connect.submit") {
                    if isConnecting {
                        model.cancelConnect()
                    } else {
                        savedAttemptID = nil
                        model.connect()
                    }
                }
                .padding(.top, 20)

                if failedSavedRecord == nil, case .failed(let failure) = model.connectState {
                    ConnectFailureView(failure: failure, onEditAddress: { focusedField = .address })
                        .padding(.top, 12)
                }

                Button("Try demo") {
                    savedAttemptID = nil
                    model.enterDemo()
                }
                .buttonStyle(PlainActionButtonStyle())
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("connect.demo")
                .padding(.top, 12)

                if !visibleRecords.isEmpty {
                    savedServers
                        .padding(.top, Metrics.groupSpacing)
                }

                supportLinks
                    .padding(.top, Metrics.groupSpacing)
            }
            .padding(.horizontal, Metrics.side)
            .padding(.top, 16)
            .padding(.bottom, Metrics.groupSpacing)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $editingRecord, onDismiss: { model.cancelConnect() }) { record in
            ServerFormSheet(record: record) { editingRecord = nil }
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
        .onChange(of: model.addressText) { _, _ in savedAttemptID = nil }
        .onChange(of: model.passwordText) { _, _ in savedAttemptID = nil }
        .usageScreen(.connect)
    }

    /// Where the privacy policy, feedback and the tips are, one tap away: centred under the
    /// demo button, in the system's own link look, with a full-size tap target around each.
    /// They share a line when they fit and take one each when they do not; stacked, they have no dots.
    private var supportLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                privacyLink

                linkSeparator

                feedbackLink

                linkSeparator

                supportLink
            }
            VStack(spacing: 0) {
                privacyLink
                feedbackLink
                supportLink
            }
        }
        .font(.footnote)
    }

    private var privacyLink: some View {
        Link(destination: SupportPages.privacyPolicy) {
            Text(privacyPolicyTitle)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .accessibilityIdentifier("connect.privacy")
    }

    private var feedbackLink: some View {
        footerAction(String(localized: "Send feedback", comment: "Link that opens the feedback form"),
                     identifier: "connect.feedback") { showsFeedback = true }
    }

    private var supportLink: some View {
        footerAction(String(localized: "Support the developer", comment: "Link that opens the tips page"),
                     identifier: "connect.support") { showsSupport = true }
    }

    private var privacyPolicyTitle: String {
        String(localized: "Privacy Policy", comment: "Link to the app's privacy policy")
    }

    /// The dot between two links, hidden from VoiceOver.
    private var linkSeparator: some View {
        Text(verbatim: "\u{2022}")
            .accessibilityHidden(true)
    }

    private func footerAction(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(Color.action)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .accessibilityIdentifier(identifier)
    }

    private var appMark: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 28))
                .foregroundStyle(Color.action)
                .accessibilityHidden(true)
            Text("Watchpost", comment: "The app's name")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.labelPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Watchpost", comment: "The app's name"))
        .accessibilityIdentifier("connect.mark")
    }

    private var savedServers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved servers", comment: "Heading above servers saved on this phone")
                .font(.headline)
                .foregroundStyle(Color.labelPrimary)

            VStack(spacing: 0) {
                ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                    SavedServerRow(
                        record: record,
                        online: model.currentRecord?.id == record.id && model.serverIsOnline == true,
                        anyConnectionRunning: isConnecting,
                        thisConnectionRunning: isConnecting && model.connectTarget?.recordID == record.id,
                        horizontalPadding: Metrics.inner,
                        identifier: "connect.saved.\(record.id.uuidString)",
                        moreIdentifier: "connect.saved.\(record.id.uuidString).more",
                        onConnect: {
                            savedAttemptID = record.id
                            model.connect(to: record)
                        },
                        onEdit: { editingRecord = record },
                        onRemove: {
                            recordPendingRemoval = record
                            showsRemoveConfirmation = true
                        }
                    )

                    if index < visibleRecords.count - 1 {
                        Rectangle()
                            .fill(Color.separatorToken)
                            .frame(height: 1)
                            .padding(.leading, Metrics.inner)
                    }
                }
            }
            .card()

            if let record = failedSavedRecord, case .failed(let failure) = model.connectState {
                ConnectFailureView(failure: failure)
                Button("Edit connection") {
                    editingRecord = record
                }
                .buttonStyle(PlainActionButtonStyle())
            }
        }
        .accessibilityIdentifier("connect.saved")
    }
}
