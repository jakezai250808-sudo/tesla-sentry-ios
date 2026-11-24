import Foundation

// Reading the server's JSON. The server is a Python program that has grown for
// a while, so nothing here assumes a value is always written the same way: a
// number may come as a string, a field may be missing or an empty object.

/// A JSON value with forgiving accessors.
enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init?(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.compactMap { JSONValue(any: $0) })
        case let object as [String: Any]:
            self = .object(object.mapValues { JSONValue(any: $0) ?? .null })
        default:
            return nil
        }
    }

    /// Parses any JSON, including a bare value. Anything unparsable reads as `.null`.
    init(data: Data) {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let value = JSONValue(any: any) else {
            self = .null
            return
        }
        self = value
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// A string as written, or a whole number spelled out.
    var string: String? {
        switch self {
        case .string(let text): return text
        case .number(let value):
            // A whole number is spelled without ".0"; one too large for Int64 keeps every digit.
            if value == value.rounded(), let whole = Int64(exactly: value) { return "\(whole)" }
            return String(value)
        case .bool(let flag): return flag ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    /// A string with something in it.
    var nonEmptyString: String? {
        guard let text = string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    var double: Double? {
        switch self {
        case .number(let value): value.isFinite ? value : nil
        case .string(let text): Double(text.trimmingCharacters(in: .whitespaces))
        case .bool(let flag): flag ? 1 : 0
        case .null, .array, .object: nil
        }
    }

    var int: Int? { double.flatMap { Int(exactly: $0.rounded()) } }

    var int64: Int64? { double.flatMap { Int64(exactly: $0.rounded()) } }

    var bool: Bool? {
        switch self {
        case .bool(let flag): flag
        case .number(let value): value != 0
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes", "on": true
            case "0", "false", "no", "off": false
            default: nil
            }
        case .null, .array, .object: nil
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// The server said no, in its own words.
struct ServerRefusal: Error, Hashable, Sendable {
    let message: String
}

enum Wire {
    // MARK: Events

    /// `/api/events`: an object with one array per category.
    static func recordedEvents(fromEvents json: JSONValue) -> [RecordedEvent] {
        var events: [RecordedEvent] = []
        for category in ClipCategory.allCases {
            guard let items = json[category.rawValue]?.array else { continue }
            events += items.compactMap { recordedEvent($0, category: category) }
        }
        return newestFirst(events)
    }

    /// `/api/timeline?cat=…`: an array, all one category.
    static func recordedEvents(fromTimeline json: JSONValue, category: ClipCategory) -> [RecordedEvent] {
        newestFirst((json.array ?? []).compactMap { recordedEvent($0, category: category) })
    }

    static func newestFirst(_ events: [RecordedEvent]) -> [RecordedEvent] {
        events.sorted { $0.start == $1.start ? $0.name > $1.name : $0.start > $1.start }
    }

    static func recordedEvent(_ object: JSONValue, category: ClipCategory) -> RecordedEvent? {
        guard let name = object["name"]?.nonEmptyString else { return nil }
        let meta = eventMeta(object["meta"])

        var byStart: [Date: [ClipVideo]] = [:]
        var unplaced: [ClipVideo] = []
        for item in object["videos"]?.array ?? [] {
            guard let video = clipVideo(item, category: category, event: name) else { continue }
            if let start = video.start {
                byStart[start, default: []].append(video)
            } else {
                unplaced.append(video)
            }
        }
        var groups = byStart.keys.sorted().map { ClipGroup(start: $0, videos: byStart[$0] ?? []) }
        if groups.isEmpty, !unplaced.isEmpty {
            groups = [ClipGroup(start: meta.timestamp ?? Date(timeIntervalSince1970: 0), videos: unplaced)]
        }
        // Nothing to play, nothing to list.
        guard !groups.isEmpty else { return nil }

        return RecordedEvent(
            category: category,
            name: name,
            meta: meta,
            groups: groups,
            sizeBytes: object["size"]?.int64 ?? 0,
            isLocked: object["locked"]?.bool
        )
    }

    static func clipVideo(_ object: JSONValue, category: ClipCategory, event: String) -> ClipVideo? {
        let file = object["f"]?.nonEmptyString
            ?? object["url"]?.string.flatMap { URL(string: $0)?.lastPathComponent }
        guard let file, !file.isEmpty, !file.contains("/") else { return nil }
        guard let camera = object["cam"]?.nonEmptyString.flatMap(Camera.init(rawValue:)) ?? Camera.camera(inFileName: file) else { return nil }
        var path = object["url"]?.nonEmptyString ?? ""
        if !path.hasPrefix("/media/") {
            path = "/media/\(category.rawValue)/\(event)/\(file)"
        }
        let duration = object["duration"]?.double.flatMap { $0 > 0 ? $0 : nil }
        return ClipVideo(file: file, camera: camera, path: path, duration: duration)
    }

    /// `event.json` of an event; `{}` when missing.
    static func eventMeta(_ object: JSONValue?) -> EventMeta {
        var meta = EventMeta.empty
        guard let object else { return meta }
        meta.reason = object["reason"]?.nonEmptyString
        meta.cameraNumber = object["camera"]?.int
        meta.timestamp = object["timestamp"]?.string.flatMap { ClipTime.date($0) }
        meta.city = object["city"]?.nonEmptyString
        meta.street = object["street"]?.nonEmptyString
        // Cars that do not record a position write 0.
        meta.latitude = object["est_lat"]?.double.flatMap { $0 != 0 ? $0 : nil }
        meta.longitude = object["est_lon"]?.double.flatMap { $0 != 0 ? $0 : nil }
        return meta
    }

    // MARK: Telemetry

    /// `/api/telemetry`. `ok: false` with `no-sei` is the normal answer for a parked car.
    static func telemetry(_ json: JSONValue) -> TelemetryOutcome {
        guard json["ok"]?.bool == true, let frames = json["frames"]?.array else { return .none }
        let samples = frames.compactMap(telemetrySample)
        return samples.isEmpty ? .none : .track(TelemetryTrack(samples: samples))
    }

    /// `"P"`, `"D"`, `"R"` or `"N"`, written as letters or as the car's number (0 P, 1 D, 2 R, 3 N).
    static func gearName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()
        if ["P", "D", "R", "N"].contains(upper) { return upper }
        switch Int(upper) {
        case 0: return "P"
        case 1: return "D"
        case 2: return "R"
        case 3: return "N"
        default: return nil
        }
    }

    /// One row of 14 numbers: time, gear, speed, throttle, steering, brake, turn signal, autopilot, lat, lon, heading, ax, ay, az.
    static func telemetrySample(_ value: JSONValue) -> TelemetrySample? {
        guard let cells = value.array, cells.count >= 7 else { return nil }
        func cell(_ index: Int) -> JSONValue? { cells.indices.contains(index) ? cells[index] : nil }
        guard let time = cell(0)?.double, time.isFinite else { return nil }
        var sample = TelemetrySample(time: time)
        sample.gear = cell(1)?.string.flatMap(gearName)
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        // Standstill sometimes reads as a small negative speed.
        sample.speedKmh = finite(cell(2)?.double).map { max(0, $0) }
        sample.throttlePercent = finite(cell(3)?.double).map { min(max($0, 0), 100) }
        sample.steeringDegrees = finite(cell(4)?.double)
        sample.brake = cell(5)?.bool
        sample.turnSignal = cell(6)?.int.flatMap(TurnSignal.init(rawValue:))
        sample.autopilotState = cell(7)?.int
        // Cars that do not record a position write 0.
        sample.latitude = finite(cell(8)?.double).flatMap { $0 != 0 ? $0 : nil }
        sample.longitude = finite(cell(9)?.double).flatMap { $0 != 0 ? $0 : nil }
        sample.heading = finite(cell(10)?.double)
        return sample
    }

    // MARK: Status

    /// `/api/live`.
    static func syncStatus(fromLive object: JSONValue?, now: Date = Date()) -> SyncStatus {
        var status = SyncStatus()
        status.measuredAt = now
        guard let object else { return status }
        status.syncRunning = object["running"]?.bool
        status.pendingFiles = object["pending"]?.int
        status.lastSyncAgo = object["ago"]?.double.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        status.ffmpegAvailable = object["sys"]?["ffmpeg"]?.bool
        if let disk = object["disk"], !disk.isNull {
            status.archiveUsedBytes = disk["arc_used"]?.int64
            status.archiveLimitBytes = disk["arc_limit"]?.int64
            status.usbUsedBytes = disk["img_used"]?.int64.flatMap { $0 > 0 ? $0 : nil }
            status.usbCapacityBytes = disk["img_nominal"]?.int64.flatMap { $0 > 0 ? $0 : nil }
            status.diskUsedBytes = disk["disk_used"]?.int64
            status.diskCapacityBytes = disk["disk_total"]?.int64.flatMap { $0 > 0 ? $0 : nil }
        }
        return status
    }

    // MARK: Session and version

    /// `{"v": "2.8.45"}` from `/api/ver`.
    static func version(_ json: JSONValue) -> String? { json["v"]?.nonEmptyString }

    /// `/api/auth/info`: false for a server that needs no password.
    static func requiresPassword(_ json: JSONValue) -> Bool? { json["on"]?.bool }

    /// The `tsf_sess=<exp>.<signature>; Max-Age=…` cookie of a successful login.
    static func sessionToken(setCookie header: String?) -> SessionToken? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard piece.hasPrefix("tsf_sess=") else { continue }
            let value = String(piece.dropFirst("tsf_sess=".count))
            guard value.contains(".") else { return nil }
            let token = SessionToken(value: value, expiresAt: expiry(fromToken: value) ?? maxAge(fromHeader: header))
            return token.value.isEmpty ? nil : token
        }
        return nil
    }

    private static func expiry(fromToken token: String) -> Date? {
        guard let text = token.split(separator: ".").first, let seconds = TimeInterval(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func maxAge(fromHeader header: String) -> Date? {
        for part in header.components(separatedBy: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard piece.lowercased().hasPrefix("max-age=") else { continue }
            guard let seconds = TimeInterval(piece.dropFirst("max-age=".count)) else { return nil }
            return Date().addingTimeInterval(seconds)
        }
        return nil
    }

    // MARK: Playback and export

    /// `{"state": "ready" | "pending" | "cooling" | "failed" | "missing"}`.
    static func playbackSourceState(_ json: JSONValue?) -> PlaybackSourceState {
        guard let json else { return .missing }
        if let state = PlaybackSourceState(rawValue: json["state"]?.string ?? "") { return state }
        return .missing
    }

    /// `/api/font`: `ok` is true when the server has the Chinese font the watermark needs.
    static func fontAvailable(_ json: JSONValue) -> Bool? { json["ok"]?.bool }

    /// The message the server gives with a failure: `error` or `msg` on most answers, `err` on a job's status.
    static func message(_ json: JSONValue?) -> String? {
        json?["error"]?.nonEmptyString ?? json?["msg"]?.nonEmptyString ?? json?["err"]?.nonEmptyString
    }

    /// `POST /api/export/burn`: the job id, or the server's reason for refusing.
    static func exportJobStarted(_ json: JSONValue) -> Result<String, ServerRefusal> {
        if json["ok"]?.bool == true, let id = json["id"]?.nonEmptyString { return .success(id) }
        return .failure(ServerRefusal(message: message(json) ?? ""))
    }

    /// `/api/stitch/status?id=…`.
    static func exportJobStatus(_ json: JSONValue, httpStatus: Int? = nil) -> ExportJobStatus {
        let state: ExportJobState
        switch json["state"]?.string?.lowercased() {
        case "running": state = .running
        case "done": state = .done
        case "error": state = .error
        default:
            // The job is gone (expired or already downloaded): answered as an error with its own text.
            if httpStatus == 404 || message(json) != nil { state = .error } else { state = .unknown }
        }
        let percent = json["pct"]?.int.flatMap { (0...100).contains($0) ? $0 : nil }
        return ExportJobStatus(state: state, percent: percent, message: message(json), sizeBytes: json["size"]?.int64)
    }
}
