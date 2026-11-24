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

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
