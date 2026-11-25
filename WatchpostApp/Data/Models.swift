import Foundation

// The app's own model of what a server holds. Everything here is a plain value:
// the networking code parses the server's JSON into these types once, and the
// demo source builds the same types from bundled files.

/// One of the three recording categories the app shows (the server also has
/// DriveClips; that is a later iteration).
enum ClipCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case sentry = "SentryClips"
    case saved = "SavedClips"
    case recent = "RecentClips"
}

/// A camera, identified by the suffix the server uses in clip file names.
///
/// Names follow where the camera sits on the car (decided by product on
/// 2026-11-24): the `*_pillar` files are the B-pillar cameras and the
/// `*_repeater` files are the fender cameras. The server's own web page shows
/// those two pairs the other way round; the README says so.
enum Camera: String, CaseIterable, Codable, Sendable, Hashable {
    case front
    case back
    case leftPillar = "left_pillar"
    case rightPillar = "right_pillar"
    case leftRepeater = "left_repeater"
    case rightRepeater = "right_repeater"

    /// Order of the camera switcher, by where the cameras sit:
    /// 左前翼 前视 右前翼 / 左B柱 后视 右B柱.
    static let displayOrder: [Camera] = [.leftRepeater, .front, .rightRepeater, .leftPillar, .back, .rightPillar]

    /// The camera the first one falls back to when an event has no trigger camera.
    static let fallback = Camera.front

    /// Position in `displayOrder`, for sorting.
    var displayRank: Int {
        switch self {
        case .leftRepeater: 0
        case .front: 1
        case .rightRepeater: 2
        case .leftPillar: 3
        case .back: 4
        case .rightPillar: 5
        }
    }

    /// The `camera` number from `event.json`, which only means something for
    /// sentry events: 0 front, 3 left pillar, 4 right pillar, 5 left repeater,
    /// 6 right repeater, 7 back.
    static func triggerCamera(_ number: Int?) -> Camera? {
        switch number {
        case 0: .front
        case 3: .leftPillar
        case 4: .rightPillar
        case 5: .leftRepeater
        case 6: .rightRepeater
        case 7: .back
        default: nil
        }
    }

    /// The camera of a clip file name such as `2026-11-08_19-43-36-left_pillar.mp4`.
    static func camera(inFileName fileName: String) -> Camera? {
        guard fileName.hasSuffix(".mp4") else { return nil }
        let stem = fileName.dropLast(4)
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        return Camera(rawValue: String(stem[stem.index(after: dash)...]))
    }

    /// Localized short name, e.g. 前视 / Front.
    var title: String {
        switch self {
        case .front: String(localized: "Front", comment: "Camera name: front camera")
        case .back: String(localized: "Rear", comment: "Camera name: rear camera")
        case .leftPillar: String(localized: "Left pillar", comment: "Camera name: camera on the left B-pillar (file suffix left_pillar)")
        case .rightPillar: String(localized: "Right pillar", comment: "Camera name: camera on the right B-pillar (file suffix right_pillar)")
        case .leftRepeater: String(localized: "Left repeater", comment: "Camera name: camera on the left front fender (file suffix left_repeater)")
        case .rightRepeater: String(localized: "Right repeater", comment: "Camera name: camera on the right front fender (file suffix right_repeater)")
        }
    }
}

/// Clip names and `event.json` carry local wall-clock times with no time zone.
/// They are read as the time on the car's clock, taken to be the phone's zone.
enum ClipTime {
    /// A clip's name starts with `yyyy-MM-dd_HH-mm-ss`; `event.json` writes the same clock as `yyyy-MM-ddTHH:mm:ss`.
    static func date(_ text: some StringProtocol) -> Date? {
        guard let components = components(text) else { return nil }
        return date(from: components)
    }

    /// The first 19 characters of a clip file name.
    static func date(fromFileName fileName: String) -> Date? {
        guard fileName.count >= 19 else { return nil }
        return date(fileName.prefix(19))
    }

    static func components(_ text: some StringProtocol) -> DateComponents? {
        let digits = Array(text.prefix(19))
        let pattern = "dddd-dd-ddTdd-dd-dd"
        guard digits.count == 19 else { return nil }
        for (index, expected) in pattern.enumerated() {
            let character = digits[index]
            if expected == "d" {
                guard character.isASCII, character.isNumber else { return nil }
            } else if index == 10 {
                // The date and the time: `_` in file names, `T` or a space in event.json.
                guard character == "_" || character == "T" || character == " " else { return nil }
            } else if index == 13 || index == 16 {
                // Inside the time: file names write `-`, event.json writes `:`.
                guard character == "-" || character == ":" else { return nil }
            } else {
                guard character == expected else { return nil }
            }
        }
        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + Int(String(digits[$1]))! }
        }
        let year = number(0..<4)
        let month = number(5..<7)
        let day = number(8..<10)
        let hour = number(11..<13)
        let minute = number(14..<16)
        let second = number(17..<19)
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...60).contains(second) else { return nil }
        return DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    static func date(from components: DateComponents, in zone: TimeZone = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(from: components) else { return nil }
        // `date(from:)` rolls impossible values (31 April, 30 February) over instead of failing, so read them back.
        let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let readBack = calendar.dateComponents(fields, from: date)
        let matches = readBack.year == components.year && readBack.month == components.month
            && readBack.day == components.day && readBack.hour == components.hour
            && readBack.minute == components.minute && readBack.second == components.second
        return matches ? date : nil
    }
}

/// One recorded file of one minute (or so) of one camera.
struct ClipVideo: Hashable, Codable, Sendable, Identifiable {
    /// File name as the server spells it, e.g. `2026-11-08_19-43-36-front.mp4`.
    let file: String
    let camera: Camera
    /// Path on the server: `/media/<category>/<event>/<file>`.
    let path: String
    /// Seconds, when the server reported it (only `/api/timeline` does).
    let duration: TimeInterval?

    var id: String { path }

    /// When this minute starts.
    var start: Date? { ClipTime.date(fromFileName: file) }

    /// The same clip as a still: `/thumb/<category>/<event>/<file>` (add `?t=<seconds>`).
    var thumbnailPath: String { path.replacingPrefix("/media/", with: "/thumb/") }

    /// The same clip for the telemetry API: `/archive/<category>/<event>/<file>`.
    var archivePath: String { path.replacingPrefix("/media/", with: "/archive/") }
}

/// All the cameras' files of one minute of an event.
struct ClipGroup: Hashable, Codable, Sendable, Identifiable {
    let start: Date
    /// At most one file per camera, in `Camera.displayOrder`.
    let videos: [ClipVideo]

    var id: Date { start }

    init(start: Date, videos: [ClipVideo]) {
        self.start = start
        var seen: Set<Camera> = []
        self.videos = videos
            .filter { seen.insert($0.camera).inserted }
            .sorted { $0.camera.displayRank < $1.camera.displayRank }
    }

    func video(for camera: Camera) -> ClipVideo? {
        videos.first { $0.camera == camera }
    }

    var cameras: [Camera] { videos.map(\.camera) }
}

/// What `event.json` in the event folder says. Every field is optional: cars
/// and firmware differ, and the file can be missing altogether.
struct EventMeta: Hashable, Codable, Sendable {
    var reason: String?
    /// The raw `camera` number; see `Camera.triggerCamera(_:)`.
    var cameraNumber: Int?
    var timestamp: Date?
    var city: String?
    var street: String?
    var latitude: Double?
    var longitude: Double?

    static let empty = EventMeta()
}

/// Where an event opens and which camera it opens on.
struct TriggerInfo: Hashable, Codable, Sendable {
    let camera: Camera
    let groupIndex: Int
    /// Seconds into that minute where the trigger is.
    let offset: TimeInterval
    /// The event's timestamp falls inside that minute, so the trigger point is known.
    let isExact: Bool
    /// The trigger camera has no footage in this event and another camera is shown instead.
    let cameraMissing: Bool

    /// Where playback starts: just before the trigger, as the server's web page does.
    var playbackStart: TimeInterval { max(offset - 5, 0) }
}

/// One event: a folder on the server, holding one or more minutes of clips.
struct RecordedEvent: Hashable, Codable, Sendable, Identifiable {
    let category: ClipCategory
    /// Folder name, e.g. `2026-11-08_19-43-36`.
    let name: String
    let meta: EventMeta
    /// Ascending by start time.
    let groups: [ClipGroup]
    let sizeBytes: Int64
    let isLocked: Bool?
    /// Set only by `DemoClipSource`, for the one real recording that ships with the demo.
    /// A server never sets it, and it is never encoded: it is true only of an event the demo made.
    var isRealSample = false

    /// `isRealSample` is left out, so a server's event, which has no such field, still decodes.
    private enum CodingKeys: String, CodingKey { case category, name, meta, groups, sizeBytes, isLocked }

    var id: String { "\(category.rawValue)/\(name)" }

    var start: Date { groups.first?.start ?? meta.timestamp ?? Date(timeIntervalSince1970: 0) }

    var end: Date {
        guard let last = groups.last else { return meta.timestamp ?? start }
        if let duration = last.videos.compactMap(\.duration).max() {
            return last.start.addingTimeInterval(duration)
        }
        return last.start
    }

    /// How long the real recording sample is, as its source says; nil for every other event.
    var realSampleSeconds: Int? {
        guard isRealSample, let duration = groups.first?.videos.first?.duration else { return nil }
        return Int(duration.rounded())
    }

    /// Every camera that has footage somewhere in this event, in switcher order.
    var cameras: [Camera] {
        Camera.displayOrder.filter { camera in groups.contains { $0.video(for: camera) != nil } }
    }

    var trigger: TriggerInfo { TriggerInfo.derive(meta: meta, groups: groups) }

    /// The still to show in the list: the trigger frame when there is one.
    var cover: (video: ClipVideo, time: TimeInterval)? {
        let trigger = self.trigger
        guard groups.indices.contains(trigger.groupIndex),
              let video = groups[trigger.groupIndex].video(for: trigger.camera) else {
            return groups.first?.videos.first.map { ($0, 1) }
        }
        return (video, trigger.isExact ? trigger.offset : 1)
    }
}

extension TriggerInfo {
    /// Follows the server's own rule for picking the clip to open, with
    /// fallbacks that never show one camera's picture under another camera's name.
    static func derive(meta: EventMeta, groups: [ClipGroup]) -> TriggerInfo {
        guard !groups.isEmpty else {
            return TriggerInfo(camera: .fallback, groupIndex: 0, offset: 0, isExact: false, cameraMissing: false)
        }

        // The minute the event's timestamp falls in: the latest minute that starts no later than it.
        // A clip is up to about 70 s long, so the minute before can reach it too; the latest one wins.
        var containingGroup: Int?
        if let timestamp = meta.timestamp {
            let started = groups.indices.filter { timestamp.timeIntervalSince(groups[$0].start) >= 0 }
            if let latest = started.last, timestamp.timeIntervalSince(groups[latest].start) <= 70 {
                containingGroup = latest
            }
        }

        func info(camera: Camera, groupIndex: Int, missing: Bool) -> TriggerInfo {
            let exact = containingGroup == groupIndex
            var offset: TimeInterval = 0
            if exact, let timestamp = meta.timestamp {
                offset = min(max(timestamp.timeIntervalSince(groups[groupIndex].start), 0), 60)
            }
            return TriggerInfo(camera: camera, groupIndex: groupIndex, offset: offset, isExact: exact, cameraMissing: missing)
        }

        func firstGroup(with camera: Camera, preferring preferred: Int?) -> Int? {
            if let preferred, groups[preferred].video(for: camera) != nil { return preferred }
            return groups.firstIndex { $0.video(for: camera) != nil }
        }

        // Any camera with footage in the preferred minute (else anywhere), switcher order first.
        func substitute(preferred: Int?) -> (camera: Camera, groupIndex: Int) {
            let order = Camera.displayOrder
            if let preferred {
                for camera in order where groups[preferred].video(for: camera) != nil {
                    return (camera, preferred)
                }
            }
            for groupIndex in groups.indices {
                for camera in order where groups[groupIndex].video(for: camera) != nil {
                    return (camera, groupIndex)
                }
            }
            return (.fallback, 0)
        }

        let wanted: Camera?
        if let reason = meta.reason, reason.hasPrefix("sentry_") {
            wanted = Camera.triggerCamera(meta.cameraNumber)
        } else {
            wanted = nil
        }

        // Known trigger camera with footage in the right minute.
        if let camera = wanted, let groupIndex = firstGroup(with: camera, preferring: containingGroup) {
            return info(camera: camera, groupIndex: groupIndex, missing: false)
        }

        // No trigger camera (not a sentry event, or an unknown number): front camera when there is one.
        if wanted == nil, let groupIndex = firstGroup(with: Camera.fallback, preferring: containingGroup) {
            return info(camera: .fallback, groupIndex: groupIndex, missing: false)
        }

        // The trigger camera has no footage here: say so and open something that exists.
        let standIn = substitute(preferred: containingGroup)
        return info(camera: standIn.camera, groupIndex: standIn.groupIndex, missing: wanted != nil)
    }
}

extension String {
    func replacingPrefix(_ prefix: String, with replacement: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return replacement + dropFirst(prefix.count)
    }
}
