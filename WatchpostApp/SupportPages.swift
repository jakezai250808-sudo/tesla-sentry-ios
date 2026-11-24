import Foundation

/// Web pages the app opens for the person using it. Each page carries every language,
/// so there is one address per page.
enum SupportPages {
    /// The privacy policy. The connect screen and the servers list link to it, as Apple requires
    /// a link to the policy inside the app (App Review guideline 5.1.1).
    static let privacyPolicy = URL(string: "https://watchpost.example.invalid/privacy")!
}
