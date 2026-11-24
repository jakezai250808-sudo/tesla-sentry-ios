import Foundation
import UIKit

/// Which events the list shows.
struct EventFilter: Equatable, Sendable {
    var category: ClipCategory = .sentry
    /// A calendar day, at the start of that day.
    var day: Date?
    /// Sentry only: one of the three groups of reasons.
    var bucket: SentryBucket?
    /// Saved clips only: one known reason.
    var reason: TriggerReasonID?

    var isFiltering: Bool { day != nil || bucket != nil || reason != nil }

    func matches(_ event: RecordedEvent, calendar: Calendar = .current) -> Bool {
        guard event.category == category else { return false }
        if let day, !calendar.isDate(event.start, inSameDayAs: day) { return false }
        switch category {
        case .sentry:
            if let bucket { return TriggerReasons.bucket(for: event.meta.reason) == bucket }
        case .saved:
            if let reason { return TriggerReasons.label(for: event.meta.reason).knownID == reason }
        case .recent:
            // Recent clips carry no reason; a reason filter would hide everything.
            return reason == nil
        }
        return true
    }

    /// The known reasons that occur in a category's events, in table order.
    static func reasons(in events: [RecordedEvent], category: ClipCategory) -> [TriggerReasonID] {
        let present = Set(events.filter { $0.category == category }.compactMap { TriggerReasons.label(for: $0.meta.reason).knownID })
        return TriggerReasonID.allCases.filter { present.contains($0) }
    }

    /// Moving to another category keeps the day; a reason that means nothing
    /// there (every sentry bucket, a saved reason under Recent) goes back to "all".
    mutating func changeCategory(to newCategory: ClipCategory) -> Bool {
        var changed = false
        if category != newCategory {
            category = newCategory
            changed = true
        }
        if bucket != nil {
            bucket = nil
            changed = true
        }
        if newCategory != .saved, reason != nil {
            reason = nil
            changed = true
        }
        return changed
    }
}

/// The events of one day, under a header.
struct EventDay: Identifiable, Equatable {
    let day: Date
    let events: [RecordedEvent]
    var id: Date { day }

    static func group(_ events: [RecordedEvent], calendar: Calendar = .current) -> [EventDay] {
        var order: [Date] = []
        var byDay: [Date: [RecordedEvent]] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.start)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(event)
        }
        return order.map { EventDay(day: $0, events: byDay[$0] ?? []) }
    }
}

/// Dates and numbers as the screens show them.
enum Display {
    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HHmm")
        return formatter.string(from: date)
    }

    static func minutes(_ date: Date) -> String { clock(date) }

    static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "今天 · 11月24日", or "11月23日 · 周日" for any other day.
    static func dayHeader(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let numbered = DateFormatter()
        numbered.locale = .current
        numbered.setLocalizedDateFormatFromTemplate("MMMd")
        let date = numbered.string(from: day)
        if calendar.isDate(day, inSameDayAs: now) {
            return String(localized: "Today · \(date)", comment: "Section header for the current day. The date is already formatted, e.g. Nov 24")
        }
        let weekday = DateFormatter()
        weekday.locale = .current
        weekday.setLocalizedDateFormatFromTemplate("EEEE")
        return String(localized: "\(date) · \(weekday.string(from: day))", comment: "Section header for another day, e.g. Nov 23 · Sunday")
    }

    /// "14:28–14:29" for a clip that runs from one minute to the next.
    static func span(from start: Date, to end: Date) -> String {
        "\(clock(start))–\(clock(end))"
    }

    /// Short, for the navigation bar: "11月24日 14:28".
    static func shortStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        return formatter.string(from: date)
    }

    /// How long ago, in words the system already has ("2 hr ago", "yesterday").
    static func ago(_ seconds: TimeInterval, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = .current
        formatter.unitsStyle = .short
        return formatter.localizedString(fromTimeInterval: -seconds)
    }

    /// Whole GB for anything from a gigabyte up, whole MB below: "32 GB".
    static func storage(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.allowsNonnumericFormatting = false
        if bytes >= 1 << 30 {
            formatter.allowedUnits = [.useGB, .useTB]
        } else {
            formatter.allowedUnits = [.useMB]
        }
        return formatter.string(fromByteCount: bytes)
    }

    /// "0:12" or "1:05".
    static func playback(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "27秒" for VoiceOver and the trigger marker.
    static func seconds(_ value: TimeInterval) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = .current
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.usesGroupingSeparator = false
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: max(value, 0), unit: UnitDuration.seconds))
    }

    /// A place as the event row shows it: "City · Street" where words are spaced, "城市·街道"
    /// where they are not, whichever is there, or the dash.
    static func place(city: String?, street: String?, bundle: Bundle = .main) -> String {
        switch (city, street) {
        case let (city?, street?):
            let format = String(localized: "%1$@ · %2$@",
                                bundle: bundle,
                                comment: "A city and a street shown together, e.g. Sample City · Sample Car Park A")
            return String(format: format, city, street)
        case let (city?, nil): return city
        case let (nil, street?): return street
        case (nil, nil): return missing
    }
    }

    /// Shown wherever a value was not recorded. Never a made-up zero.
    static let missing = "—"
}
