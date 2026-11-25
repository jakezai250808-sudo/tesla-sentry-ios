import Foundation
import PostHog
import SwiftUI

/// The screens usage statistics counts. Each is a fixed name: which screen was opened,
/// never what is on it.
enum UsageScreen: String, CaseIterable, Sendable {
    case connect = "Connect"
    case events = "Events"
    case playback = "Playback"
    case export = "Export"
    case servers = "Servers"
    case serverForm = "Server Form"
    case filter = "Filter"
    case feedback = "Feedback"
    case support = "Support the Developer"
}

/// The whole rule for what one usage event may carry, besides the SDK's own envelope
/// (a random per-install identifier, the event's own number and the time). The SDK's session number
/// is a property, which the rule below drops.
enum UsageEventRule {
    static let screenEvent = "$screen"
    static let screenName = "$screen_name"

    /// The app's own install, update, openings and departures, as the statistics SDK names them.
    static let appEvents: Set<String> = [
        "Application Installed", "Application Updated", "Application Opened", "Application Backgrounded",
    ]

    /// The properties that may pass: which app version, on which system and screen.
    /// Everything else the SDK gathers about the device is dropped here, before anything is stored or sent.
    static let passedProperties: Set<String> = [
        "$app_version", "$app_build", "$os_name", "$os_version", "$device_model", "$device_type",
        "$lib", "$lib_version", "version", "build", "previous_version", "previous_build", "from_background",
    ]

    /// The properties that go out with this event, or nil when usage statistics does not count it.
    static func outgoingProperties(event: String, of properties: [String: Any]) -> [String: Any]? {
        var kept: [String: Any] = [
            // No person, no profile, no place: the event stays a count.
            "$is_identified": false, "$process_person_profile": false, "$geoip_disable": true,
        ]
        if event == screenEvent {
            guard let name = properties[screenName] as? String, UsageScreen(rawValue: name) != nil else { return nil }
            kept[screenName] = name
        } else {
            guard appEvents.contains(event) else { return nil }
        }
        for (key, value) in properties where passedProperties.contains(key) && isPlain(value) {
            kept[key] = value
        }
        return kept
    }

    /// Text that is not a paragraph, a number or yes/no. Anything nested stays behind.
    static func isPlain(_ value: Any) -> Bool {
        switch value {
        case let text as String: text.count <= 64
        case is NSNumber: true
        default: false
        }
    }
}

/// What the statistics SDK keeps on this device between launches: what it has not sent yet, its
/// install number and its settings. SDK 3.98.2 keeps all of it in one folder inside the app's own
/// Application Support folder, named after the project. Older versions kept it loose beside that
/// folder, one file or folder each named `posthog.`.
enum StatisticsStore {
    static let prefix = "posthog."

    /// The other thing it keeps: which app version and build it last saw, written on every launch,
    /// statistics on or off, to tell an update from a first open.
    static let preferenceKeys = ["PHGVersionKey", "PHGBuildKeyV2"]

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "")
    }

    /// Deletes it all: the SDK's folder, whatever an older version left loose, and its two notes
    /// in preferences. Started again after this, the SDK knows nothing of earlier use: this
    /// install gets a new number and an empty queue. Nothing else there is touched. Returns the
    /// names that were removed.
    @discardableResult
    static func discard(in directory: URL = directory, project: String = FeedbackConfig.appKey,
                        defaults: UserDefaults = .standard) -> [String] {
        for key in preferenceKeys {
            defaults.removeObject(forKey: key)
        }
        let files = FileManager.default
        guard let items = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return items
            .filter { $0.lastPathComponent == project || $0.lastPathComponent.hasPrefix(prefix) }
            .filter { (try? files.removeItem(at: $0)) != nil }
            .map(\.lastPathComponent)
    }
}

/// The statistics SDK's network gate. Only what usage statistics sends, to its one address,
/// gets through, and nothing at all once statistics is off, not even what was already waiting.
enum TrafficGate {
    /// The only address the statistics SDK may talk to.
    static let host = URL(string: "https://apps.air.build/traffic")!

    /// What the SDK is told when it is not allowed through.
    static let refused = NSError(domain: "WatchpostApp.TrafficGate", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "Not allowed by the usage statistics setting."])

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrafficGateProtocol.self]
        return configuration
    }

    /// The only request the SDK may make: an event batch to the host, as
    /// `https://apps.air.build/traffic/batch`.
    static let batchPaths: Set<String> = {
        let door = host.path + "/batch"
        return [door, door + "/"]
    }()

    /// Whether one request may leave this device.
    static func allows(host: String?, path: String, isSharing: Bool) -> Bool {
        guard isSharing, host == Self.host.host else { return false }
        return batchPaths.contains(path)
    }
}

final class TrafficGateProtocol: URLProtocol, @unchecked Sendable {
    /// Carries an allowed request the rest of the way. It has no gate, so it cannot loop.
    /// A test swaps it for a session whose host answers without the network.
    nonisolated(unsafe) static var forwarding = URLSession(configuration: URLSessionConfiguration.ephemeral)
    private var forwardTask: URLSessionDataTask?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let allowed = TrafficGate.allows(host: request.url?.host, path: request.url?.path ?? "",
                                         isSharing: UsageAnalytics.isSharingNow)
        guard allowed, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: TrafficGate.refused)
            return
        }
        let forwarded = NSMutableURLRequest(url: url)
        if let method = request.httpMethod { forwarded.httpMethod = method }
        forwarded.allHTTPHeaderFields = request.allHTTPHeaderFields
        forwarded.httpBody = request.httpBody ?? Self.body(of: request)
        forwardTask = Self.forwarding.dataTask(with: forwarded as URLRequest) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            guard let response else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardTask?.resume()
    }

    override func stopLoading() {
        forwardTask?.cancel()
        forwardTask = nil
    }

    /// A body the system hands over as a stream instead of data.
    static func body(of request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let capacity = 16384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Usage statistics: which screens are opened and how often the app runs. There is no
/// account and no name behind it, and nothing from the server the person connected to.
/// The person can turn it off at any time; from then on nothing is sent.
@MainActor
@Observable
final class UsageAnalytics {
    static let shared = UsageAnalytics()

    nonisolated private static let sharingKey = "usageAnalytics.sharing"

    /// The current setting, for any thread: the network gate reads it too.
    nonisolated static var isSharingNow: Bool { readSharing(UserDefaults.standard) }

    private(set) var isSharing: Bool
    private let defaults: UserDefaults
    private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSharing = Self.readSharing(defaults)
    }

    /// Once per launch. Does nothing while unit tests run the app. While the setting is off the
    /// SDK is not started at all, so it keeps nothing and sends nothing.
    func start() {
        guard !started, !AppRuntime.isRunningTests else { return }
        started = true
        if isSharing { startSDK() }
    }

    private func startSDK() {
        let config = PostHogConfig(projectToken: FeedbackConfig.appKey, host: TrafficGate.host.absoluteString)
        // Screen views are sent by hand, each with a fixed name; nothing else is gathered.
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.captureElementInteractions = false
        config.captureSwiftUIElementInteractions = false
        config.sessionReplay = false
        config.surveys = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false
        config.errorTrackingConfig.autoCapture = false
        config.disableGeoIp = true
        config.personProfiles = .never
        config.urlSessionConfiguration = TrafficGate.configuration()
        config.setBeforeSend { event in
            // Statistics is off, or this is not something it counts: nothing is stored or sent.
            guard Self.isSharingNow,
                  let properties = UsageEventRule.outgoingProperties(event: event.event, of: event.properties)
            else { return nil }
            event.properties = properties
            return event
        }
        PostHogSDK.shared.setup(config)
    }

    /// One screen was opened.
    func screen(_ screen: UsageScreen) {
        guard started, isSharing else { return }
        PostHogSDK.shared.screen(screen.rawValue)
    }

    /// The switch, kept for the next launch. Turning it off stops the SDK on the spot: from
    /// that line on the network gate refuses every request the SDK starts, and what it had not
    /// handed to the network yet, with its install number, is deleted. One batch that was already
    /// on its way can still arrive; the privacy page says so. Turning it on again starts it
    /// fresh, under a new number.
    func setSharing(_ sharing: Bool) {
        guard sharing != isSharing else { return }
        // Written first: the network gate reads this, so nothing leaves from here on.
        defaults.set(sharing, forKey: Self.sharingKey)
        isSharing = sharing
        guard started else { return }
        if sharing {
            startSDK()
        } else {
            PostHogSDK.shared.close()
            StatisticsStore.discard()
        }
    }

    nonisolated private static func readSharing(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: sharingKey) == nil ? true : defaults.bool(forKey: sharingKey)
    }

}

private struct UsageScreenModifier: ViewModifier {
    let screen: UsageScreen

    func body(content: Content) -> some View {
        content.onAppear { UsageAnalytics.shared.screen(screen) }
    }
}

extension View {
    /// Counts this screen as opened each time it appears.
    func usageScreen(_ screen: UsageScreen) -> some View {
        modifier(UsageScreenModifier(screen: screen))
    }
}
