import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct PlaybackScreen: View {
    let event: RecordedEvent

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var playback: PlaybackModel?
    /// The one export the toolbar asked for. It carries the export and the minute shown with it,
    /// so the sheet is handed both and never looks for an export stored a moment earlier.
    @State private var exportRequest: ExportRequest?
    @State private var showFullScreen = false
    @ScaledMetric(relativeTo: .footnote) private var timeWidth: CGFloat = 44
    @ScaledMetric(relativeTo: .footnote) private var triggerLabelHeight: CGFloat = 20

    /// What the toolbar asks for: the export and the minute shown with it.
    private struct ExportRequest: Identifiable {
        let export: ExportModel
        let clip: String

        var id: ObjectIdentifier { ObjectIdentifier(export) }
    }

    init(event: RecordedEvent) {
        self.event = event
    }

    /// What the navigation bar calls the event: when it happened, or, for the real recording, what it is.
    /// The recording has no date of its own, and the moment the demo gives it is only where it sits in the list.
    private var title: Text {
        if event.isRealSample {
            return Text("Real recording sample", comment: "Title of the demo's real recording, which has no date of its own")
        }
        return Text(verbatim: Display.shortStamp(playback?.event.start ?? event.start))
    }

    /// The tag over the picture while the demo shows it: which kind of demo footage this is.
    private var footageBadge: DemoBadge.Kind? {
        guard model.isDemo else { return nil }
        return event.isRealSample ? .realClip : .footage
    }

    var body: some View {
        Group {
            if let playback {
                playbackScreen(playback)
            } else {
                Color.canvas
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .tint(Color.action)
                    }
            }
        }
        .background(Color.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard let playback, let export = playback.exportModel() else { return }
                    exportRequest = ExportRequest(export: export, clip: clipLabel(playback))
                } label: {
                    Label("Export and share", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .disabled(playback?.video == nil)
                .accessibilityLabel("Export and share")
                .accessibilityIdentifier("playback.export")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isDemo {
                demoRow(camera: playback?.camera ?? event.trigger.camera)
            }
        }
        .task {
            if let playback {
                // Showing the full-screen player makes this screen disappear and come back, which
                // ends this task; a load that was cut short by that is started again here.
                if playback.isUnloaded { playback.retry() }
                return
            }
            guard let source = model.source else { return }
            let created = PlaybackModel(event: event, source: source, preferredQuality: model.preferredQuality)
            created.onQualityChosen = { quality in
                model.setPreferredQuality(quality)
            }
            playback = created
            await created.open()
        }
        .onDisappear {
            // The full-screen player covers this screen too, and that must not stop what it plays.
            if !showFullScreen { playback?.close() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                playback?.player.pause()
            }
        }
        .sheet(item: $exportRequest) { request in
            ExportSheet(export: request.export, clip: request.clip)
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let playback {
                FullScreenPlayerView(player: playback.player, badge: footageBadge) {
                    showFullScreen = false
                }
                // Edge to edge: otherwise the screen's own background shows above and below the player.
                .ignoresSafeArea()
            }
        }
        .usageScreen(.playback)
    }

    private func demoRow(camera: Camera) -> some View {
        HStack(spacing: 8) {
            DemoBadge(kind: .data)
            demoWords(camera: camera)
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)
        }
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.canvas)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("playback.demo-badge")
    }

    /// What the row says after the badge: the footage's kind, and the camera when there is one to name.
    private func demoWords(camera: Camera) -> Text {
        if event.isRealSample {
            return Text("Real recording sample", comment: "The picture is the demo's real recording")
        }
        return Text("Demo footage", comment: "The picture is sample footage")
            + Text(" · ", comment: "Separator between demo footage and the camera name")
            + Text(camera.title)
    }

    /// What VoiceOver calls the picture.
    private func videoLabel(_ playback: PlaybackModel) -> Text {
        if event.isRealSample {
            return Text("Real recording sample, six camera views in a grid",
                        comment: "VoiceOver name of the demo's real recording video")
        }
        return Text(playback.camera.title)
            + Text(" picture", comment: "Appended to a camera name in the video's VoiceOver label")
    }

    private func playbackScreen(_ playback: PlaybackModel) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    videoArea(playback, width: proxy.size.width,
                              maximumHeight: max(proxy.size.height - 220, 44))
                    controls(playback)
                }
            }
        }
    }

    private func videoArea(_ playback: PlaybackModel, width: CGFloat, maximumHeight: CGFloat) -> some View {
        let aspect: CGFloat = if let size = playback.videoSize, size.width > 0, size.height > 0 {
            size.width / size.height
        } else {
            4.0 / 3.0
        }
        let height = min(width / aspect, maximumHeight)
        let canPlay = playback.video != nil && playback.problem == nil

        return ZStack {
            ZStack {
                Color.videoCanvas
                VideoLayerView(player: playback.player)

                if playback.video != nil && playback.videoSize == nil && playback.problem == nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else if playback.isBuffering && playback.videoSize != nil {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }

                if canPlay, playback.videoSize != nil, !playback.isPlaying,
                   !playback.isBuffering, !playback.ended {
                    Circle()
                        .fill(Color.videoOverlay)
                        .frame(width: 72, height: 72)
                    Image(systemName: "play.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if canPlay {
                    playback.togglePlay()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(videoLabel(playback))
            .accessibilityAddTraits(canPlay ? .isButton : [])
            .accessibilityHidden(playback.problem != nil || playback.video == nil)

            if let footageBadge {
                VStack {
                    HStack {
                        // The real recording carries a camera's name in each top corner of its own, so its tag
                        // goes to the top right, clear of both; a drawn clip has no such name.
                        if !event.isRealSample { Spacer() }
                        DemoBadge(kind: footageBadge)
                            .accessibilityIdentifier("playback.demo-footage")
                        if event.isRealSample { Spacer() }
                    }
                    .padding(8)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            if playback.video == nil {
                Text("No footage from this camera in this minute",
                     comment: "The selected camera has no file for the current minute")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(Metrics.side)
                    .accessibilityIdentifier("playback.problem")
            } else if let problem = playback.problem {
                problemView(playback, problem: problem)
            }

            if playback.ended, canPlay, playback.videoSize != nil {
                Button {
                    playback.replay()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(PlaybackCircleStyle())
                .accessibilityLabel("Replay")
                .accessibilityIdentifier("playback.replay")
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        showFullScreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(OverlayIconButtonStyle())
                    // Usable once there is a picture: until then the clip is still being opened, and
                    // covering this screen would cut that short.
                    .disabled(!canPlay || playback.videoSize == nil)
                    .accessibilityLabel("Enter full screen")
                    .accessibilityIdentifier("playback.fullscreen")
                }
                .padding(8)
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .accessibilityIdentifier("playback.video")
    }

    @ViewBuilder
    private func problemView(_ playback: PlaybackModel, problem: PlaybackProblem) -> some View {
        VStack(spacing: 12) {
            // The real recording has nothing in its place: when its file is missing or cannot be read,
            // the only way on is back, as for a clip the server no longer has.
            if problem == .removed || event.isRealSample {
                missingWords
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("playback.problem")

                Button {
                    dismiss()
                } label: {
                    Text("Back to events", comment: "Leave playback after the clip was removed")
                }
                .buttonStyle(OverlayTextButtonStyle())
                .accessibilityIdentifier("playback.back")
            } else {
                if model.serverIsOnline == false {
                    Text("Not connected to the server", comment: "The last server request did not answer")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("playback.problem")
                } else {
                    Text("Can't play this clip", comment: "The recording exists but could not be played")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("playback.problem")
                }

                Button {
                    playback.retry()
                } label: {
                    Text("Retry", comment: "Try playing the clip again")
                }
                .buttonStyle(OverlayTextButtonStyle())
                .accessibilityIdentifier("playback.retry")

                Text("Try another quality", comment: "Suggests the quality menu when playback failed")
                    .font(.footnote)
                    .foregroundStyle(.white)
            }
        }
        .padding(Metrics.side)
    }

    /// Why nothing is shown, when the clip is gone.
    private var missingWords: Text {
        event.isRealSample
            ? Text("This sample recording can't be played.",
                  comment: "The demo's real recording is not in the app or cannot be read")
            : Text("This clip is no longer available", comment: "The recording was removed since the list loaded")
    }

    private func controls(_ playback: PlaybackModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            timeline(playback)
                .padding(.top, Metrics.inner)

            transportControls(playback)
                .padding(.top, 8)

            clipSwitcher(playback)
                .padding(.top, 8)

            if event.isRealSample {
                // All six cameras are already in the one picture: there is no other camera to switch to.
                Text("This video combines six camera views in a grid. You can't switch between cameras.",
                     comment: "Why the demo's real recording has no camera switcher")
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("playback.precomposed")
            } else {
                CameraSwitcher(cameras: playback.eventCameras, selected: playback.camera,
                               available: Set(playback.groupCameras)) { camera in
                    playback.select(camera)
                }
                .padding(.top, 8)

                qualityMenu(playback)
                    .padding(.top, 8)
            }

            if let notice = qualityNotice(playback) {
                Text(verbatim: notice)
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("playback.quality-notice")
            }

            if playback.triggerCameraMissing {
                Text(verbatim: String(format: String(localized: "Trigger camera not available. Opened %@ instead.",
                                                   comment: "The trigger camera has no footage; the actual camera name follows"),
                                      playback.camera.title))
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .accessibilityIdentifier("playback.stand-in")
            }

            if let seconds = event.realSampleSeconds {
                // No reason, place or time to show: the recording has none, and the credit says whose it is.
                sampleCredit(seconds)
                    .padding(.top, Metrics.groupSpacing)
            } else {
                metadata(playback)
                    .padding(.top, Metrics.groupSpacing)
            }

            TelemetryPanel(telemetry: playback.telemetry, sample: playback.sample) {
                playback.retryTelemetry()
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, Metrics.side)
        .padding(.bottom, Metrics.groupSpacing)
        .frame(maxWidth: 600, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func timeline(_ playback: PlaybackModel) -> some View {
        VStack(spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                HStack {
                    timeLabel(Display.playback(playback.currentTime), alignment: .leading)
                    Spacer()
                    timeLabel(Display.playback(playback.duration), alignment: .trailing)
                }
                slider(playback)
                if let trigger = playback.triggerOffset {
                    triggerLabel(trigger, duration: playback.duration)
                }
            } else {
                HStack(spacing: 12) {
                    timeLabel(Display.playback(playback.currentTime), alignment: .leading)
                        .frame(width: timeWidth, alignment: .leading)
                    slider(playback)
                    timeLabel(Display.playback(playback.duration), alignment: .trailing)
                        .frame(width: timeWidth, alignment: .trailing)
                }
                if let trigger = playback.triggerOffset {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: timeWidth)
                        triggerLabel(trigger, duration: playback.duration)
                        Color.clear.frame(width: timeWidth)
                    }
                }
            }
        }
    }

    private func timeLabel(_ value: String, alignment: TextAlignment) -> some View {
        Text(verbatim: value)
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(Color.labelSecondary)
            .multilineTextAlignment(alignment)
    }

    @ViewBuilder
    private func triggerLabel(_ trigger: TimeInterval, duration: TimeInterval) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            triggerText(trigger)
                .font(.footnote)
                .foregroundStyle(Color.action)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("playback.trigger")
        } else {
            GeometryReader { proxy in
                triggerText(trigger)
                    .font(.footnote)
                    .foregroundStyle(Color.action)
                    .fixedSize()
                    .position(x: proxy.size.width * triggerFraction(trigger, duration: duration),
                              y: proxy.size.height / 2)
                    .accessibilityIdentifier("playback.trigger")
            }
            .frame(height: triggerLabelHeight)
        }
    }

    private func triggerText(_ trigger: TimeInterval) -> Text {
        Text("Trigger", comment: "The event's trigger point on the timeline")
            + Text(verbatim: " \(Display.playback(trigger))")
    }

    private func slider(_ playback: PlaybackModel) -> some View {
        let position = Binding(
            get: { playback.currentTime },
            set: { playback.seek(to: $0) }
        )

        return ZStack {
            if let trigger = playback.triggerOffset, playback.duration > 0 {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.action)
                        .frame(width: 6, height: 18)
                        .position(x: proxy.size.width * triggerFraction(trigger, duration: playback.duration),
                                  y: proxy.size.height / 2)
                }
            }

            Slider(value: position, in: 0...max(playback.duration, 0.001))
                .tint(Color.action)
                .accessibilityIdentifier("playback.slider")
                .accessibilityLabel(Text("Position"))
                .accessibilityValue(Text(Display.seconds(playback.currentTime))
                                    + Text(", ", comment: "Separator between the current position and total duration for VoiceOver")
                                    + Text("of", comment: "Said between the current position and total duration for VoiceOver")
                                    + Text(verbatim: " ")
                                    + Text(Display.seconds(playback.duration)))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: playback.skip(1)
                    case .decrement: playback.skip(-1)
                    @unknown default: break
                    }
                }
                .disabled(playback.video == nil || playback.problem != nil)
        }
        .frame(height: 44)
    }

    private func triggerFraction(_ trigger: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(trigger / duration, 0), 1))
    }

    private func transportControls(_ playback: PlaybackModel) -> some View {
        let enabled = playback.video != nil && playback.problem == nil

        return HStack(spacing: 24) {
            Button {
                playback.skip(-10)
            } label: {
                Image(systemName: "gobackward.10")
            }
            .modifier(TransportIconStyle(enabled: enabled))
            .accessibilityLabel("Back 10 seconds")
            .accessibilityIdentifier("playback.back10")
            .disabled(!enabled)

            Button {
                playback.togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .modifier(TransportIconStyle(enabled: enabled))
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("playback.playpause")
            .disabled(!enabled)

            Button {
                playback.skip(10)
            } label: {
                Image(systemName: "goforward.10")
            }
            .modifier(TransportIconStyle(enabled: enabled))
            .accessibilityLabel("Forward 10 seconds")
            .accessibilityIdentifier("playback.forward10")
            .disabled(!enabled)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(minHeight: 44)
    }

    private func clipSwitcher(_ playback: PlaybackModel) -> some View {
        HStack(spacing: 8) {
            Button {
                playback.goToPreviousGroup()
            } label: {
                Image(systemName: "chevron.left")
                    .modifier(TransportIconStyle(enabled: playback.hasPreviousGroup))
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .disabled(!playback.hasPreviousGroup)
            .accessibilityLabel("Previous clip")
            .accessibilityValue(Text(verbatim: adjacentStart(playback, offset: -1) ?? ""))
            .accessibilityIdentifier("playback.prev")

            Text(verbatim: clipLabel(playback))
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(Color.labelPrimary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("playback.clip")

            Button {
                playback.goToNextGroup()
            } label: {
                Image(systemName: "chevron.right")
                    .modifier(TransportIconStyle(enabled: playback.hasNextGroup))
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .disabled(!playback.hasNextGroup)
            .accessibilityLabel("Next clip")
            .accessibilityValue(Text(verbatim: adjacentStart(playback, offset: 1) ?? ""))
            .accessibilityIdentifier("playback.next")
        }
        .frame(minHeight: 44)
    }

    private func qualityMenu(_ playback: PlaybackModel) -> some View {
        HStack {
            Spacer()
            Menu {
                ForEach(Quality.menuOrder, id: \.self) { quality in
                    Button {
                        playback.select(quality: quality)
                    } label: {
                        if quality == playback.quality {
                            Label {
                                Text(verbatim: quality.title)
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(verbatim: quality.title)
                        }
                    }
                    .accessibilityAddTraits(quality == playback.quality ? .isSelected : [])
                    .accessibilityIdentifier("playback.quality.\(quality.rawValue)")
                }
            } label: {
                qualityLabel(playback.quality)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Quality"))
            .accessibilityValue(Text(verbatim: playback.quality.title))
            .accessibilityIdentifier("playback.quality")
        }
    }

    @ViewBuilder
    private func qualityLabel(_ quality: Quality) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Quality", comment: "Video quality menu")
                        .foregroundStyle(Color.labelSecondary)
                    HStack(spacing: 6) {
                        Text(verbatim: quality.title)
                            .foregroundStyle(Color.action)
                        qualityChevron
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Text("Quality", comment: "Video quality menu")
                        .foregroundStyle(Color.labelSecondary)
                    Text(verbatim: quality.title)
                        .foregroundStyle(Color.action)
                    qualityChevron
                }
            }
        }
        .font(.subheadline)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }

    private var qualityChevron: some View {
        Image(systemName: "chevron.down")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.action)
    }

    private func qualityNotice(_ playback: PlaybackModel) -> String? {
        if playback.waitingForQuality, playback.playingQuality == .original, playback.quality != .original {
            return String(localized: "Playing original quality; switching soon",
                          comment: "The original is playing while the requested quality is prepared")
        }
        if playback.waitingForQuality, playback.playingQuality != .original,
           playback.playingQuality != playback.quality {
            return String(format: String(localized: "Playing %@; %@ is being prepared",
                                          comment: "First the playing quality, then the requested quality"),
                          playback.playingQuality.title, playback.quality.title)
        }
        if playback.qualityUnavailable {
            return String(format: String(localized: "Couldn't switch to %@. Still playing %@.",
                                          comment: "First the requested quality, then the quality still playing"),
                          playback.quality.title, playback.playingQuality.title)
        }
        return nil
    }

    private func metadata(_ playback: PlaybackModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: playback.reason.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.labelPrimary)
                .accessibilityIdentifier("playback.reason")

            Text(verbatim: Display.place(city: playback.event.meta.city, street: playback.event.meta.street))
                .font(.subheadline)
                .foregroundStyle(Color.labelSecondary)
                .accessibilityIdentifier("playback.place")

            Text(verbatim: Display.fullDate(playback.event.start))
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)
        }
    }

    /// What the real recording is and whose it is. The clip itself carries the credit too, in its last row.
    private func sampleCredit(_ seconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: Display.sampleSummary(seconds))
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.labelPrimary)
                .accessibilityIdentifier("playback.sample")

            CreditLink(words: Text("Footage: Tesla FSD Drive (5 min, 6 cameras), published by cfahlgren1",
                                   comment: "Credit for the demo's real recording: the data set's name and its publisher"),
                       page: DemoClipSource.RealSample.source)
                .accessibilityIdentifier("playback.sample.source")

            CreditLink(words: Text("Creative Commons Attribution 4.0 International license (CC BY 4.0)",
                                   comment: "Link to the licence of the demo's real recording; it opens in Safari"),
                       page: DemoClipSource.RealSample.license)
                .accessibilityIdentifier("playback.sample.license")

            Text("Watchpost shortened the footage, combined six camera views in a grid, and added camera labels and credits.",
                 comment: "What was changed from the original recording")
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clipLabel(_ playback: PlaybackModel) -> String {
        // The real recording is named by how long it is: the demo's clock has nothing to do with it.
        if let seconds = event.realSampleSeconds { return Display.sampleLength(seconds) }
        guard let group = playback.group else { return Display.missing }
        if playback.duration > 0 {
            return Display.span(from: group.start, to: group.start.addingTimeInterval(playback.duration))
        }
        return Display.minutes(group.start)
    }

    private func adjacentStart(_ playback: PlaybackModel, offset: Int) -> String? {
        let index = playback.groupIndex + offset
        guard playback.event.groups.indices.contains(index) else { return nil }
        return Display.minutes(playback.event.groups[index].start)
    }
}

private struct TransportIconStyle: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(Color.action)
            .opacity(enabled ? 1 : 0.4)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private struct PlaybackCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(Color.videoOverlay, in: Circle())
    }
}

private struct OverlayTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .background(Color.videoOverlay, in: Capsule())
            .contentShape(Rectangle())
    }
}

/// One line of the credit under the real recording: it opens the recording's page in Safari.
private struct CreditLink: View {
    let words: Text
    let page: URL

    var body: some View {
        Button {
            UIApplication.shared.open(page)
        } label: {
            words
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PlainActionButtonStyle())
    }
}

private struct FullScreenPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    /// The tag over the picture while the demo shows it.
    let badge: DemoBadge.Kind?
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> FullScreenPlayerViewController {
        FullScreenPlayerViewController(player: player, badge: badge, onClose: onClose)
    }

    func updateUIViewController(_ controller: FullScreenPlayerViewController, context: Context) {
        controller.update(player: player)
    }
}

final class FullScreenPlayerViewController: UIViewController {
    private let playerController = AVPlayerViewController()
    /// The tag over the picture while the demo shows it.
    private let badge: DemoBadge.Kind?
    private var onClose: () -> Void

    init(player: AVPlayer, badge: DemoBadge.Kind?, onClose: @escaping () -> Void) {
        self.badge = badge
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        playerController.player = player
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .allButUpsideDown
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Color.videoCanvas)
        playerController.showsPlaybackControls = true
        playerController.videoGravity = .resizeAspect
        playerController.updatesNowPlayingInfoCenter = false

        addChild(playerController)
        view.addSubview(playerController.view)
        playerController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        playerController.didMove(toParent: self)

        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "xmark",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
                        for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor(Color.videoOverlay)
        button.layer.cornerRadius = 22
        button.accessibilityLabel = String(localized: "Exit full screen", comment: "Close the full-screen player")
        button.accessibilityIdentifier = "playback.fullscreen.close"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(UIAction { [weak self] _ in self?.onClose() }, for: .touchUpInside)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])

        if let badge {
            let demo = UIHostingController(rootView: FullScreenDemoBadge(badge: badge))
            demo.view.backgroundColor = .clear
            demo.view.isUserInteractionEnabled = false
            addChild(demo)
            view.addSubview(demo.view)
            demo.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                demo.view.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 8),
                demo.view.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            demo.didMove(toParent: self)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    func update(player: AVPlayer) {
        if playerController.player !== player {
            playerController.player = player
        }
    }
}

private struct FullScreenDemoBadge: View {
    /// Which kind of demo footage is on screen.
    let badge: DemoBadge.Kind

    var body: some View {
        DemoBadge(kind: badge)
            .accessibilityIdentifier("playback.fullscreen.demo-badge")
    }
}
