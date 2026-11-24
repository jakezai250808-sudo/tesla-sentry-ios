import Foundation

// Telemetry: the numbers the car wrote into the clip (SEI), read back by the
// server as one row per few frames.

enum TurnSignal: Int, Codable, Sendable, Hashable {
    case off = 0
    case left = 1
    case right = 2

    var title: String {
        switch self {
        case .off: String(localized: "Off", comment: "Turn signal value: not signalling")
        case .left: String(localized: "Left", comment: "Turn signal value: left indicator")
        case .right: String(localized: "Right", comment: "Turn signal value: right indicator")
        }
    }
}

/// The readings at one moment of a clip. A nil is "not recorded": the screen
/// shows a dash for it, never a made-up zero.
struct TelemetrySample: Hashable, Codable, Sendable {
    /// Seconds from the start of the clip.
    var time: TimeInterval
    /// "P", "D", "R" or "N".
    var gear: String?
    var speedKmh: Double?
    /// 0–100.
    var throttlePercent: Double?
    /// Steering angle in degrees, signed as the car reports it.
    var steeringDegrees: Double?
    /// The pedal is only ever recorded as pressed or not; there is no percentage.
    var brake: Bool?
    var turnSignal: TurnSignal?
    var autopilotState: Int?
    var latitude: Double?
    var longitude: Double?
    var heading: Double?
}

/// One clip's samples, in time order.
struct TelemetryTrack: Hashable, Codable, Sendable {
    var samples: [TelemetrySample]

    init(samples: [TelemetrySample]) {
        self.samples = samples.sorted { $0.time < $1.time }
    }

    /// Typical gap between two samples.
    var spacing: TimeInterval {
        guard samples.count > 1 else { return 0 }
        let gaps = zip(samples, samples.dropFirst()).map { $1.time - $0.time }.filter { $0 > 0 }
        guard !gaps.isEmpty else { return 0 }
        let sorted = gaps.sorted()
        return sorted[sorted.count / 2]
    }

    /// A sample counts as current for this long: a few normal gaps, and at least a second.
    var tolerance: TimeInterval { max(1, spacing * 2.5) }

    /// The last sample at or before `time`, when one is close enough to still
    /// describe that moment. Nil means "nothing recorded around here".
    func sample(at time: TimeInterval) -> TelemetrySample? {
        guard !samples.isEmpty else { return nil }
        guard time >= 0 else { return samples[0].time <= tolerance ? samples[0] : nil }

        // First index whose time is greater than `time`.
        var low = 0
        var high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].time <= time {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low - 1
        if index >= 0 {
            let candidate = samples[index]
            return time - candidate.time <= tolerance ? candidate : nil
        }
        // Before the first sample: use it only if it is right there.
        return samples[0].time <= tolerance ? samples[0] : nil
    }
}

/// What the telemetry panel knows about the clip being played.
enum TelemetryState: Hashable, Sendable {
    case loading
    /// The server answered but this clip carries no telemetry (parked sentry clips usually don't).
    case none
    /// The request failed; the video plays on.
    case unavailable
    case loaded(TelemetryTrack)
}

extension TelemetryState {
    var track: TelemetryTrack? {
        if case .loaded(let track) = self { return track }
        return nil
    }
}

/// What a telemetry request came back with.
enum TelemetryOutcome: Hashable, Sendable {
    /// The clip has no telemetry recorded in it.
    case none
    case track(TelemetryTrack)
}
