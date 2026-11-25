import Foundation
import Testing
@testable import WatchpostApp

/// What the person with a server meets: the connection rules Apple enforces before any request
/// leaves the phone, the privacy declarations shipped in the app, and the pages the app links to.
struct AppConfigurationTests {
    private static func transportSecurity() throws -> [String: Any] {
        try #require(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])
    }

    /// A server is wherever its owner runs it: a phone on the same network by address, a `.local`
    /// name, or a public name over plain HTTP. One key allows all of them, and the key beside it
    /// in earlier builds (`NSAllowsLocalNetworking`) silently turned that permission off again on
    /// iOS 10 and later, which left only local addresses and HTTPS working.
    @Test
    func plainHTTPIsAllowedForEveryHost() throws {
        let rules = try Self.transportSecurity()
        #expect(rules["NSAllowsArbitraryLoads"] as? Bool == true)
        #expect(rules["NSAllowsLocalNetworking"] == nil)
    }

    /// The same rule as the phone applies it: a plain-HTTP request to a public name is not refused
    /// before it starts. Having no route to the network is some other error, and passes; only the
    /// refusal counts. The HTTPS request shows whether the phone could reach the network at all.
    /// Apple's own captive.apple.com is no probe here: the phone lets it through plain HTTP whatever
    /// the settings say.
    @Test
    func publicPlainHTTPIsNotRefused() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let hosts = ["example.com", "neverssl.com"]
        if let secure = URL(string: "https://example.com/") {
            print("[transport security] https \(secure.host ?? ""): \(await Self.outcome(of: secure, in: session))")
        }
        for host in hosts {
            let plain = try #require(URL(string: "http://\(host)/"))
            let outcome = await Self.outcome(of: plain, in: session)
            print("[transport security] http \(host): \(outcome)")
            #expect(outcome != "refused by App Transport Security")
        }
    }

    private static func outcome(of url: URL, in session: URLSession) async -> String {
        do {
            let (_, response) = try await session.data(from: url)
            return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
        } catch let error as URLError {
            return error.code == .appTransportSecurityRequiresSecureConnection
                ? "refused by App Transport Security"
                : "error \(error.errorCode) (\(error.code))"
        } catch {
            return "error \(error)"
        }
    }

    /// Apple reads the app's privacy declarations only from a file with this exact name; an earlier
    /// build shipped the same declarations under another name, where Apple does not look.
    @Test
    func privacyManifestCarriesTheNameAppleReads() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        #expect(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "privacymanifest") == nil)

        let manifest = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        let declared = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = declared.first { ($0["NSPrivacyAccessedAPIType"] as? String) == "NSPrivacyAccessedAPICategoryUserDefaults" }
        #expect((reasons?["NSPrivacyAccessedAPITypeReasons"] as? [String]) == ["CA92.1"])
    }

    /// The manifest names what leaves the device, and no more: crash reports, screen counts, feedback with its
    /// images, the device identifier they travel with, and tip purchases. Each is declared as linked to the
    /// person, which is how Apple defines data that goes with a device identifier: statistics and crash
    /// reports each keep a per-install number, feedback and crashes share one device-proof key, and a
    /// purchase report is Apple's own signed record of one transaction. None of it is declared as tracking.
    @Test
    func privacyManifestNamesWhatIsSentAndTracksNobody() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(manifest["NSPrivacyTrackingDomains"] as? [String] == [])

        let analytics = "NSPrivacyCollectedDataTypePurposeAnalytics"
        let functionality = "NSPrivacyCollectedDataTypePurposeAppFunctionality"
        let expected: [String: [String]] = [
            "NSPrivacyCollectedDataTypeCrashData": [functionality],
            "NSPrivacyCollectedDataTypeProductInteraction": [analytics],
            "NSPrivacyCollectedDataTypeCustomerSupport": [functionality],
            "NSPrivacyCollectedDataTypePhotosorVideos": [functionality],
            "NSPrivacyCollectedDataTypePurchaseHistory": [analytics],
            "NSPrivacyCollectedDataTypeDeviceID": [analytics, functionality],
        ]

        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(collected.count == expected.count)
        for type in collected {
            let name = try #require(type["NSPrivacyCollectedDataType"] as? String, "\(type)")
            let purposes = try #require(expected[name], "the manifest declares \(name), which this test does not know")
            #expect(type["NSPrivacyCollectedDataTypeLinked"] as? Bool == true, "\(name)")
            #expect(type["NSPrivacyCollectedDataTypeTracking"] as? Bool == false, "\(name)")
            #expect(type["NSPrivacyCollectedDataTypePurposes"] as? [String] == purposes, "\(name)")
        }
    }

    /// The link in the app must lead to the published page: a web address, never the placeholder
    /// the source carries until the page is live.
    @Test
    func privacyPolicyAddressIsAPublishedPage() {
        let page = SupportPages.privacyPolicy
        #expect(page.scheme == "https")
        #expect(page.host?.isEmpty == false)
        #expect(page.host?.hasSuffix(".invalid") == false, "the placeholder address is still in the source")
    }
}
