import SwiftUI
import UIKit

/// The app turns with the phone only while the full-screen player is up. Every
/// other screen is portrait, so leaving full screen brings the phone back to
/// portrait by itself (the orientations in Info.plist are what the player may use).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let root = window?.rootViewController else { return .portrait }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top.showsFullScreenPlayer ? .allButUpsideDown : .portrait
    }
}

private extension UIViewController {
    var showsFullScreenPlayer: Bool {
        self is FullScreenPlayerViewController || children.contains { $0.showsFullScreenPlayer }
    }
}

@main
struct AirbuildApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var tips = TipPurchases.shared

    init() {
        // Unit tests drive the app without reporting anything, like the usage statistics do.
        guard !AppRuntime.isRunningTests else { return }
        // Crash reports go first: they are the only thing that can explain a launch that goes wrong.
        AirCrashReports.start(apiKey: FeedbackConfig.appKey,
                              endpoint: "https://apps.air.build/v1/ingest/crashes",
                              teamID: FeedbackConfig.teamID)
        UsageAnalytics.shared.start()
        TipPurchases.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // The thank-you for a tip the App Store confirmed while the tips page was closed.
                .sheet(isPresented: Binding(
                    get: { tips.showsTicket },
                    set: { if !$0 { tips.hasShownTicket() } }
                )) {
                    if let ticket = tips.ticket {
                        ThankYouSheet(ticket: ticket)
                    }
                }
        }
    }
}
