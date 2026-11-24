import Foundation

// Trigger reasons. `event.json`'s `reason` is free text, so the app matches the
// known values first and otherwise shows the raw text rather than guessing.

/// The reasons the server's own page knows, with the text from copy.md v3 (T01–T11).
enum TriggerReasonID: String, CaseIterable, Sendable, Hashable {
    case sentryAwareObjectDetection = "sentry_aware_object_detection"
    case sentryAwareDoor = "sentry_aware_door"
    case sentryAwareHandle = "sentry_aware_handle"
    case sentryAwareAccel = "sentry_aware_accel"
    case sentryPanic = "sentry_panic"
    case sentryTrigger = "sentry_trigger"
    case dashcamSaved = "user_interaction_dashcam_saved"
    case dashcamMenu = "user_interaction_dashcam_menu"
    case dashcamIconTapped = "user_interaction_dashcam_icon_tapped"
    case dashcamLauncherTapped = "user_interaction_dashcam_launcher_action_tapped"
    case honk = "user_interaction_honk"

    var title: String {
        switch self {
        case .sentryAwareObjectDetection: String(localized: "Sentry aware", comment: "Trigger reason: sentry_aware_object_detection")
        case .sentryAwareDoor, .sentryAwareHandle: String(localized: "Door handle pulled", comment: "Trigger reason: sentry_aware_door / sentry_aware_handle")
        case .sentryAwareAccel, .sentryPanic: String(localized: "Under attack", comment: "Trigger reason: sentry_aware_accel / sentry_panic")
        case .sentryTrigger: String(localized: "Sentry triggered", comment: "Trigger reason: sentry_trigger")
        case .dashcamSaved: String(localized: "Saved manually", comment: "Trigger reason: user_interaction_dashcam_saved")
        case .dashcamMenu: String(localized: "Saved from dashcam menu", comment: "Trigger reason: user_interaction_dashcam_menu")
        case .dashcamIconTapped, .dashcamLauncherTapped: String(localized: "Dashcam icon tapped", comment: "Trigger reason: user_interaction_dashcam_icon_tapped / user_interaction_dashcam_launcher_action_tapped")
        case .honk: String(localized: "Saved by honk", comment: "Trigger reason: user_interaction_honk")
        }
    }
}

/// The three groups the sentry filter offers.
enum SentryBucket: String, CaseIterable, Codable, Sendable, Hashable {
    case aware
    case doorHandle
    case underAttack

    var title: String {
        switch self {
        case .aware: String(localized: "Sentry aware", comment: "Sentry filter: 哨兵警觉")
        case .doorHandle: String(localized: "Door handle pulled", comment: "Sentry filter: 车门拉动")
        case .underAttack: String(localized: "Under attack", comment: "Sentry filter: 遭遇袭击")
        }
    }
}

/// How an event's reason is shown.
enum ReasonLabel: Hashable, Sendable {
    /// One of the known reasons.
    case recorded(TriggerReasonID)
    /// A reason the app has no text for; shown as the server wrote it.
    case raw(String)
    /// No reason recorded.
    case none

    var title: String {
        switch self {
        case .recorded(let id): id.title
        case .raw(let text): text
        case .none: String(localized: "No reason recorded", comment: "Shown when an event has no trigger reason")
        }
    }

    /// The known reason, when the label is one.
    var knownID: TriggerReasonID? {
        if case .recorded(let id) = self { return id }
        return nil
    }
}

enum TriggerReasons {
    static let sentryPrefix = "sentry_"

    /// Exact match first, then a prefix match, in table order.
    static func label(for reason: String?) -> ReasonLabel {
        guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        if let exact = TriggerReasonID(rawValue: reason) { return .recorded(exact) }
        if let prefixed = TriggerReasonID.allCases.first(where: { reason.hasPrefix($0.rawValue) }) {
            return .recorded(prefixed)
        }
        return .raw(reason)
    }

    /// The sentry filter group of a reason; nil for anything that is not a sentry event.
    /// Unknown `sentry_*` values count as "sentry aware", as on the server's page.
    static func bucket(for reason: String?) -> SentryBucket? {
        guard let reason, reason.hasPrefix(sentryPrefix) else { return nil }
        switch label(for: reason) {
        case .recorded(let id):
            switch id {
            case .sentryAwareDoor, .sentryAwareHandle: return .doorHandle
            case .sentryAwareAccel, .sentryPanic: return .underAttack
            // Everything else that starts with `sentry_` counts as sentry aware, as on the server's page.
            default: return .aware
            }
        case .raw, .none:
            return .aware
        }
    }
}
