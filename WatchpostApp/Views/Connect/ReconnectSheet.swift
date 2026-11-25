import SwiftUI

/// RootView presents this when the current server stops accepting its session.
struct ReconnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @FocusState private var focusedField: ConnectForm.Field?

    @State private var reconnecting = false
    @State private var failure: ConnectFailure?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("The session on this server has ended.", comment: "Explanation in the sign-in-again sheet")
                        .font(.body)
                        .foregroundStyle(Color.labelPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.currentRecord?.hostLabel ?? Display.missing)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                        .padding(.bottom, Metrics.groupSpacing)

                    ConnectForm(model: model,
                                focus: $focusedField,
                                passwordOnly: true,
                                reconnecting: reconnecting,
                                submit: reconnect)

                    ConnectActionButton(connecting: reconnecting,
                                        enabled: !model.passwordText.isEmpty,
                                        cancelsWhileConnecting: false,
                                        identifier: "reconnect.submit",
                                        action: reconnect)
                        .padding(.top, 20)

                    if let failure {
                        // This page asks for the password only, so its failure line does not send
                        // the person to check an address that is not on screen, nor, when the phone
                        // did not get through to a server on its own network, a password the server
                        // never saw. That failure brings the connect page's line and the way to Settings.
                        ConnectFailureView(failure: failure, passwordOnly: true)
                            .padding(.top, 12)
                    }

                    Button("Open in browser") {
                        if let page = model.serverPage {
                            openURL(page)
                        }
                    }
                    .buttonStyle(PlainActionButtonStyle())
                    .frame(maxWidth: .infinity)
                    .disabled(reconnecting || model.serverPage == nil)
                    .accessibilityIdentifier("reconnect.browser")
                    .padding(.top, 12)
                }
                .padding(.horizontal, Metrics.side)
                .padding(.top, 16)
                .padding(.bottom, Metrics.groupSpacing)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.canvas.ignoresSafeArea())
            .navigationTitle(Text("Sign in again", comment: "Title of the session-expired sheet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.dismissSessionNotice()
                    }
                    .disabled(reconnecting)
                }
            }
        }
        .interactiveDismissDisabled(reconnecting)
        .accessibilityIdentifier("reconnect.sheet")
        .onDisappear {
            // Also when the sheet goes away for another reason (the server was switched, or the
            // person went back to the connect screen): the password typed here stays here.
            model.passwordText = ""
            model.showPassword = false
        }
        .onChange(of: model.passwordText) { _, _ in
            if failure != nil {
                failure = nil
            }
        }
    }

    private func reconnect() {
        guard !reconnecting, !model.passwordText.isEmpty else { return }
        reconnecting = true
        failure = nil
        let password = model.passwordText

        Task { @MainActor in
            let result = await model.reconnect(password: password)
            reconnecting = false
            // Kept as the model named it, `.localNetworkUnreachable` among the rest: for that one the
            // failure view below has the connect page's line and the way to Settings.
            if let result { failure = result }
        }
    }
}
