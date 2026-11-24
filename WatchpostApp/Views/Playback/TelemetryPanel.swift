import SwiftUI

/// The readings for the frame on screen. Missing values stay dashes, including for VoiceOver's "No data".
struct TelemetryPanel: View {
    let telemetry: TelemetryState
    let sample: TelemetrySample?
    let retry: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var noData: String {
        String(localized: "No data", comment: "VoiceOver value for a telemetry field that was not recorded")
    }

    private var speedText: String {
        guard let speed = sample?.speedKmh else { return Display.missing }
        return String(format: "%.0f", speed)
    }

    private var gearText: String {
        sample?.gear ?? Display.missing
    }

    private var brakeText: String {
        guard let brake = sample?.brake else { return Display.missing }
        return brake
            ? String(localized: "on", comment: "Brake pedal is pressed")
            : String(localized: "off", comment: "Brake pedal is not pressed")
    }

    private var throttleText: String {
        guard let throttle = sample?.throttlePercent else { return Display.missing }
        return String(format: "%d %%", Int(throttle))
    }

    private var steeringText: String {
        guard let steering = sample?.steeringDegrees else { return Display.missing }
        return String(format: "%d°", Int(steering))
    }

    private var turnSignalText: String {
        sample?.turnSignal?.title ?? Display.missing
    }

    private var turnSignalIcon: String? {
        switch sample?.turnSignal {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .off, nil: nil
        }
    }

    private var gridColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), alignment: .leading)]
        }
        return [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Telemetry", comment: "Title of the vehicle readings panel")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.labelPrimary)

            switch telemetry {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.action)
                    Text("Loading telemetry…", comment: "The readings for this clip are still loading")
                        .font(.footnote)
                        .foregroundStyle(Color.labelSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("playback.telemetry.state")

            case .none:
                Text("No telemetry for this clip", comment: "The clip has no recorded telemetry")
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
                    .accessibilityIdentifier("playback.telemetry.state")
                readings

            case .unavailable:
                unavailableState

            case .loaded:
                readings
            }
        }
        .padding(Metrics.inner)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playback.telemetry")
    }

    @ViewBuilder
    private var unavailableState: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    unavailableMessage
                    retryButton
                }
            } else {
                HStack(spacing: 12) {
                    unavailableMessage
                    retryButton
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("playback.telemetry.state")
    }

    private var unavailableMessage: some View {
        Text("Telemetry unavailable", comment: "Telemetry could not be loaded; playback can continue")
            .font(.footnote)
            .foregroundStyle(Color.labelSecondary)
    }

    private var retryButton: some View {
        Button(action: retry) {
            Label("Retry", systemImage: "arrow.clockwise")
        }
        .buttonStyle(PlainActionButtonStyle())
        .accessibilityIdentifier("playback.telemetry.retry")
    }

    private var readings: some View {
        VStack(alignment: .leading, spacing: 16) {
            speedometer

            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
                TelemetryField(label: "Brake", value: brakeText,
                               color: sample?.brake == true ? Color.errorToken : Color.labelSecondary)

                TelemetryField(label: "Accelerator", value: throttleText, color: Color.labelPrimary)
                TelemetryField(label: "Steering", value: steeringText, color: Color.labelPrimary,
                               icon: "steeringwheel")
                TelemetryField(label: "Turn signal", value: turnSignalText, color: Color.labelPrimary,
                               icon: turnSignalIcon)
            }
        }
    }

    @ViewBuilder
    private var speedometer: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                speedReading
                gearReading
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                speedReading
                Spacer(minLength: 16)
                gearReading
            }
        }
    }

    private var speedReading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: speedText)
                .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(verbatim: "km/h")
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)
        }
        .foregroundStyle(Color.labelPrimary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Speed"))
        .accessibilityValue(Text(verbatim: sample?.speedKmh == nil ? noData : "\(speedText) km/h"))
    }

    private var gearReading: some View {
        Text(verbatim: gearText)
            .font(.title2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Color.labelPrimary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Gear"))
            .accessibilityValue(Text(verbatim: sample?.gear == nil ? noData : gearText))
    }
}

private struct TelemetryField: View {
    let label: LocalizedStringKey
    let value: String
    let color: Color
    var icon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)

            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.body)
                        .foregroundStyle(Color.labelSecondary)
                        .accessibilityHidden(true)
                }
                Text(verbatim: value)
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value == Display.missing ? noData : value))
    }

    private var noData: String {
        String(localized: "No data", comment: "VoiceOver value for a telemetry field that was not recorded")
    }
}
