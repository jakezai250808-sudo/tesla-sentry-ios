import SwiftUI
import Testing
import UIKit
@testable import WatchpostApp

/// `RootView` on screen. The sign-in-again page is the one sheet the root itself
/// presents. In builds 1 to 4 that page did not get the app's model, so it ended
/// the app the moment it appeared: on launch, and so on every launch after.
@MainActor
struct RootViewTests {
    /// Not the app's service, as in AppModelTests: nothing here touches what the app keeps.
    private static let secrets = SecretStore(service: "com.watchpost.tests.secrets")

    @Test func theSignInAgainPageAppearsWhenTheSavedPasswordNoLongerWorks() async throws {
        // What the server says once its admin password was changed: the cookie is refused,
        // and so is the password the app saved, on the login that follows.
        let transport = RoutingTransport()
        transport.route("/api/ver", endless: .ok(ServerFixtures.version))
        transport.route("/api/auth/info", endless: .ok(ServerFixtures.authInfoOn))
        transport.route("/api/events", endless: .unauthorized())
        transport.route("/login", endless: .status(401))

        let suite = "com.watchpost.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ServerStore(defaults: defaults, secrets: Self.secrets)
        defer {
            for record in store.records { store.remove(record.id) }
            defaults.removePersistentDomain(forName: suite)
        }
        // The server the app was on last time, with the password that used to work.
        let record = ServerRecord(address: try ServerAddress.normalize("192.168.1.50:8080"), preferredQuality: .standard)
        store.save(record)
        store.setPassword("old-password", for: record.id)
        store.lastServerID = record.id

        let model = AppModel(store: store, transport: transport)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIHostingController(rootView: RootView(model: model))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // The app comes up on that server, asks for the list, is refused, and shows the page.
        let shown = await settle(timeout: .seconds(5)) {
            model.sessionExpired && root.presentedViewController != nil
        }
        #expect(shown, "The page asking for the password again is on screen, and the app is still running")
        #expect(transport.sent(to: "/login").count == 1)
    }
}
