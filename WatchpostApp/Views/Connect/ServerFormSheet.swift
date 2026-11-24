import SwiftUI

/// The connect form in its own navigation stack, for adding a server or
/// changing a saved connection. A successful connect dismisses through onDone.
struct ServerFormSheet: View {
    let record: ServerRecord?
    let onDone: () -> Void

    @Environment(AppModel.self) private var model
    @FocusState private var focusedField: ConnectForm.Field?
    @State private var finished = false

    init(record: ServerRecord? = nil, onDone: @escaping () -> Void = {}) {
        self.record = record
        self.onDone = onDone
    }

    private var isConnecting: Bool {
        model.connectState == .connecting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ConnectForm(model: model, focus: $focusedField) { model.connect() }

                    ConnectActionButton(connecting: isConnecting,
                                        enabled: model.canSubmit,
                                        cancelsWhileConnecting: true,
                                        identifier: "connect.submit") {
                        if isConnecting {
                            model.cancelConnect()
                        } else {
                            model.connect()
                        }
                    }
                    .padding(.top, 20)

                    if case .failed(let failure) = model.connectState {
                        ConnectFailureView(failure: failure, onEditAddress: { focusedField = .address })
                            .padding(.top, 12)
                    }
                }
                .padding(.horizontal, Metrics.side)
                .padding(.top, 16)
                .padding(.bottom, Metrics.groupSpacing)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.canvas.ignoresSafeArea())
            .navigationTitle(record == nil ? Text("Add server", comment: "Title of the add-server sheet") : Text("Edit connection", comment: "Title of the edit-server sheet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        finish()
                    }
                    .accessibilityIdentifier("connect.sheet.cancel")
                }
            }
        }
        .accessibilityIdentifier("connect.edit-sheet")
        .onAppear {
            if let record {
                model.edit(record)
            } else {
                model.openNewServerForm()
            }
        }
        .onChange(of: model.mode) { _, newMode in
            if case .server = newMode {
                finish()
            }
        }
        .onChange(of: model.connectCompletions) { _, _ in
            // Editing the current server in place keeps the same mode, so the successful
            // end of its request is the other dismissal signal. "Cancel connecting" is not one.
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        model.cancelConnect()
        onDone()
    }
}
