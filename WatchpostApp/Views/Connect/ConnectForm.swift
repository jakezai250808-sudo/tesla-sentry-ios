import SwiftUI
import UIKit

/// The address and password fields, shared by the screen and the add/edit sheet.
/// The reconnect sheet asks only for its password half.
struct ConnectForm: View {
    enum Field: Hashable {
        case address
        case password
    }

    @Bindable var model: AppModel
    @FocusState.Binding var focus: Field?
    var passwordOnly = false
    var reconnecting = false
    let submit: () -> Void

    /// The reveal symbol follows the text size up to this point and then stays, so it keeps
    /// sitting inside its 44-point target instead of reaching over the help text below it.
    private static let largestRevealSymbol: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var revealSymbolSize = 17.0

    private var isConnecting: Bool {
        reconnecting || model.connectState == .connecting
    }

    private var normalizedAddress: URL? {
        try? ServerAddress.normalize(model.addressText)
    }

    private var showsAddressProblem: Bool {
        !model.addressText.isEmpty && ServerAddress.problem(model.addressText) != nil
    }

    private var canSubmitFromKeyboard: Bool {
        guard !isConnecting else { return false }
        return passwordOnly ? !model.passwordText.isEmpty : model.canSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            card
                .disabled(isConnecting)

            if passwordOnly {
                passwordFooter
                    .padding(.horizontal, Metrics.inner)
                    .padding(.top, 8)
            } else {
                connectFooters
                    .padding(.horizontal, Metrics.inner)
                    .padding(.top, 8)
            }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            if !passwordOnly {
                addressField
                Rectangle()
                    .fill(Color.separatorToken)
                    .frame(height: 1)
            }
            passwordField
        }
        .padding(Metrics.inner)
        .card()
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Server address", comment: "Label above the server address field")
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)
                .accessibilityIdentifier("connect.address")

            TextField(text: $model.addressText,
                      prompt: Text("http://192.168.1.50", comment: "Example shown only while the address field is empty")) {
                Text("Server address", comment: "Accessibility label for the server address field")
            }
            .font(.body)
            .foregroundStyle(Color.labelPrimary)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .focused($focus, equals: .address)
            .onSubmit { focus = .password }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("connect.address.field")
        }
        .frame(minHeight: Metrics.fieldMinHeight, alignment: .leading)
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 4) {
            passwordLabel

            HStack(spacing: 8) {
                passwordInput
                    .font(.body)
                    .foregroundStyle(Color.labelPrimary)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit {
                        if canSubmitFromKeyboard {
                            submit()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier(passwordOnly ? "reconnect.password" : "connect.password.field")
                revealButton
            }
        }
        .frame(minHeight: Metrics.fieldMinHeight, alignment: .leading)
    }

    @ViewBuilder
    private var passwordLabel: some View {
        let label = Text("Admin password", comment: "Label above the administrator password field")
            .font(.footnote)
            .foregroundStyle(Color.labelSecondary)

        if passwordOnly {
            label
        } else {
            label.accessibilityIdentifier("connect.password")
        }
    }

    @ViewBuilder
    private var passwordInput: some View {
        if model.showPassword {
            TextField(text: $model.passwordText,
                      prompt: Text("Enter password", comment: "Prompt in the empty password field")) {
                Text("Admin password", comment: "Accessibility label for the administrator password field")
            }
        } else {
            SecureField(text: $model.passwordText,
                        prompt: Text("Enter password", comment: "Prompt in the empty password field")) {
                Text("Admin password", comment: "Accessibility label for the administrator password field")
            }
        }
    }

    private var revealButton: some View {
        Button {
            model.showPassword.toggle()
        } label: {
            Image(systemName: model.showPassword ? "eye.slash" : "eye")
                .font(.system(size: min(revealSymbolSize, Self.largestRevealSymbol), weight: .medium))
                .foregroundStyle(Color.action)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isConnecting)
        .accessibilityLabel(model.showPassword ? Text("Hide password", comment: "Button that hides the password") : Text("Show password", comment: "Button that reveals the password"))
        .accessibilityIdentifier("connect.reveal")
    }

    private var connectFooters: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Include the port if there is one, for example :8080.", comment: "Help under the server address field")
                .footnoteStyle()

            if showsAddressProblem {
                Text("Enter an address that starts with http:// or https://.", comment: "Validation shown before any request is sent")
                    .font(.footnote)
                    .foregroundStyle(Color.errorToken)
                    .accessibilityIdentifier("connect.address.error")
            }

            if normalizedAddress?.scheme?.lowercased() == "http" {
                Text("This connection is not encrypted. Use it on a network you trust.", comment: "Shown for an HTTP server address")
                    .footnoteStyle()
            }

            passwordFooter
        }
    }

    private var passwordFooter: some View {
        Text("Uses the admin account of your server.", comment: "Help under the password field; the username is always admin")
            .footnoteStyle()
    }
}

private extension Text {
    func footnoteStyle() -> some View {
        font(.footnote)
            .foregroundStyle(Color.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The solid Connect button. During a normal connect attempt the same control
/// cancels it, so it remains enabled even though another submit is not allowed.
/// Where it cannot cancel, as when reconnecting, it is disabled while busy: grey
/// on grey, so the spinner takes the grey of the label, in both appearances.
struct ConnectActionButton: View {
    let connecting: Bool
    let enabled: Bool
    let cancelsWhileConnecting: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if connecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(connecting && !cancelsWhileConnecting ? Color.labelSecondary : .white)
                        .accessibilityHidden(true)
                    Text("Connecting…", comment: "Label while a connection attempt is running")
                } else {
                    Text("Connect", comment: "Main button that connects to the server")
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(connecting ? !cancelsWhileConnecting : !enabled)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier(identifier)
    }

    private var accessibilityText: Text {
        if connecting && cancelsWhileConnecting {
            Text("Cancel connecting", comment: "Accessibility label for Connect while a connection attempt is running")
        } else if connecting {
            Text("Connecting…", comment: "Accessibility label while reconnecting")
        } else {
            Text("Connect", comment: "Main button that connects to the server")
        }
    }
}

/// The recoverable reason a connect attempt failed, and the one action that
/// can fix it when there is one.
struct ConnectFailureView: View {
    let failure: ConnectFailure
    var onEditAddress: (() -> Void)? = nil
    /// The form above asks for the password only (the sign-in-again sheet). The address is not on
    /// screen, so no line names it, and a connection that never got through does not send the person
    /// to check a password the server never saw either.
    var passwordOnly = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch failure {
            case .incompatibleServer:
                line
                if let onEditAddress {
                    Button("Edit address", action: onEditAddress)
                        .buttonStyle(PlainActionButtonStyle())
                }

            case .localNetworkUnreachable:
                line
                Text("If the phone can't see the server, allow Local Network for Watchpost in Settings.", comment: "Help after a local-network connection failed")
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(PlainActionButtonStyle())

            case .lockedOut(let notice):
                line
                // What the server said, as it said it: the wait it names is its own, and the app
                // works none out. Nothing is shown when it wrote no sentence.
                if let sentence = notice.message {
                    Text(sentence)
                        .font(.footnote)
                        .foregroundStyle(Color.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            default:
                line
            }
        }
        .accessibilityIdentifier("connect.failure")
    }

    /// The line, and nothing at all when there is none, so that a cancelled attempt takes no room.
    @ViewBuilder
    private var line: some View {
        if let key = Self.connectionFailureMessage(failure, passwordOnly: passwordOnly) {
            failureMessage(key)
        }
    }

    /// What a failed attempt is explained by, or nil when nothing is: a cancelled attempt is not
    /// a failure, and an address that was never sent is named under the field.
    ///
    /// A connection that never got through, to a public or to a local address, does not make the
    /// password the one to check, as the server never saw it: the line names the address and the
    /// password, or, where only the password was asked for, neither and just "try again". A server
    /// that answered and refused does not say which of the two it did not accept, so there the line
    /// names them both, or the password alone.
    static func connectionFailureMessage(_ failure: ConnectFailure, passwordOnly: Bool) -> LocalizedStringKey? {
        switch failure {
        case .invalidAddress, .cancelled:
            return nil
        case .unreachable, .localNetworkUnreachable:
            return passwordOnly
                ? LocalizedStringKey("Couldn't connect. Try again.")
                : LocalizedStringKey("Couldn't connect. Check the address and password.")
        case .server, .credentialsRejected:
            return passwordOnly
                ? LocalizedStringKey("Couldn't connect. Check the password and try again.")
                : LocalizedStringKey("Couldn't connect. Check the address and password.")
        case .lockedOut:
            return LocalizedStringKey("Too many tries. Try again later.")
        case .incompatibleServer:
            return LocalizedStringKey("This server is not compatible yet.")
        case .certificateRejected:
            return LocalizedStringKey("The server's certificate is not trusted. Check the address or the certificate.")
        }
    }

    private func failureMessage(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.body)
            .foregroundStyle(Color.errorToken)
            .fixedSize(horizontal: false, vertical: true)
    }
}
