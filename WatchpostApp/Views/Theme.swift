import AVFoundation
import AVKit
import SwiftUI
import UIKit

// The design's palette. Each color has a light and a dark value and follows the appearance.

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    private init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    /// Form and events screens.
    static let canvas = Color(light: 0xF2F2F7, dark: 0x000000)
    /// Grouped forms, the list of records, the telemetry panel.
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let labelPrimary = Color(light: 0x1C1C1E, dark: 0xF5F5F7)
    /// Explanations, times, units.
    static let labelSecondary = Color(light: 0x62626B, dark: 0xAEAEB8)
    static let separatorToken = Color(light: 0xD1D1D6, dark: 0x3A3A3C)
    /// Links, what is selected, the played part of the slider.
    static let action = Color(light: 0x005FCC, dark: 0x64AAFF)
    /// The solid main button; its label is white.
    static let primaryFill = Color(light: 0x005FCC, dark: 0x0A65D9)
    /// The main button while it cannot run: neutral, not blue. 4.8:1 and 6.3:1 with the grey label.
    static let fillDisabled = Color(light: 0xE5E5EA, dark: 0x2C2C2E)
    /// A filter chip or camera chip that is on.
    static let selectionFill = Color(light: 0xE8F1FF, dark: 0x152C49)
    /// A known-good state, always with words.
    static let success = Color(light: 0x146C43, dark: 0x6BDC9A)
    /// Storage above 85% or sync behind, always with words.
    static let warning = Color(light: 0x805500, dark: 0xFFD166)
    /// A form or a load that failed.
    static let errorToken = Color(light: 0xBA1A1A, dark: 0xFFB4AB)
    /// Behind footage, the same in both appearances.
    static let videoCanvas = Color(light: 0x000000, dark: 0x000000)
    /// Only playback controls and the demo tag on footage: black at 72%.
    static let videoOverlay = Color.black.opacity(0.72)
}

enum Metrics {
    static let side: CGFloat = 20
    static let inner: CGFloat = 16
    static let groupSpacing: CGFloat = 24
    static let corner: CGFloat = 16
    static let primaryHeight: CGFloat = 50
    static let primaryCorner: CGFloat = 14
    static let thumbSize = CGSize(width: 112, height: 84)
    static let thumbCorner: CGFloat = 10
    static let rowMinHeight: CGFloat = 116
    static let fieldMinHeight: CGFloat = 52
    static let chipHeight: CGFloat = 44
    static let badgeHeight: CGFloat = 28
    static let triggerMarker: CGFloat = 6
}

// MARK: Buttons

/// The solid main button. Ready, it is blue with white words. Not ready, it turns neutral instead of
/// only dimming: a grey fill with grey words at full strength, so an action that cannot run yet
/// (nothing chosen, a form not filled in) never looks available.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : Color.labelSecondary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Metrics.primaryHeight)
            .background(isEnabled ? Color.primaryFill : Color.fillDisabled,
                        in: RoundedRectangle(cornerRadius: Metrics.primaryCorner, style: .continuous))
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The second choice on a screen, as plain action-colored words.
struct PlainActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.action)
            .opacity(isEnabled ? 1 : 0.45)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// A white rounded chip, as the camera buttons and the filter menus.
struct ChipStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.action : Color.labelPrimary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: Metrics.chipHeight)
            .padding(.horizontal, 12)
            .background(selected ? Color.selectionFill : Color.surface,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The round icon buttons over footage.
struct OverlayIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Color.videoOverlay, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

// MARK: Shared pieces

/// The word that says what is demo: the events screen's title line, or the tag on footage.
struct DemoBadge: View {
    enum Kind {
        case data
        case footage
        /// The demo's one real recording, tagged the same size as the drawn footage.
        case realClip
    }

    var kind: Kind = .footage

    var body: some View {
        switch kind {
        case .data:
            Text("Demo data", comment: "The tag marking sample content: top of the events screen, playback and the export sheet")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.action)
                // A navigation bar offers this label less than its width; it must stay on one line.
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isStaticText)
        case .footage:
            pictureTag(Text("Demo clip", comment: "Tag in the corner of a demo picture or video"))
        case .realClip:
            // Short on the same grounds as "Demo clip": it sits in a thumbnail, and over a picture of its own.
            pictureTag(Text("Real recording", comment: "Tag in the corner of the demo's one real recording, on its thumbnail and over its video"))
        }
    }

    /// White on black at 72%, on one line: it sits over a picture.
    private func pictureTag(_ words: Text) -> some View {
        words
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .frame(minHeight: Metrics.badgeHeight)
            .background(Color.videoOverlay, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// A green dot and the word "online", or no dot and the words that are true instead.
struct PresenceLabel: View {
    let text: String
    var online = false

    var body: some View {
        HStack(spacing: 6) {
            if online {
                Circle().fill(Color.success).frame(width: 8, height: 8)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(online ? Color.success : Color.labelSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The still picture of a clip: the trigger camera's frame, or a frame at a moment of the clip.
struct Thumbnail: View {
    let request: MediaRequest?
    /// What the picture is of, said by VoiceOver and drawn while nothing is there.
    let name: String
    /// The tag in the picture's corner, for the demo's footage; nil for a server's.
    var badge: DemoBadge.Kind?
    var size = Metrics.thumbSize

    @Environment(AppModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.labelSecondary.opacity(0.18)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if request != nil {
                ProgressView().tint(Color.labelSecondary)
            }
            if let badge {
                VStack {
                    Spacer()
                    HStack {
                        DemoBadge(kind: badge)
                        Spacer()
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbCorner, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image == nil ? "\(name), \(String(localized: "no picture", comment: "Said after a clip name when its picture could not be loaded"))" : name)
        .task(id: request) {
            guard let request else {
                image = nil
                return
            }
            image = await model.image(for: request)
        }
    }
}

/// The video itself, fitted to its own shape inside the space given.
struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .clear
        view.videoLayer.videoGravity = .resizeAspect
        view.videoLayer.player = player
        return view
    }

    func updateUIView(_ uiView: LayerView, context: Context) {
        if uiView.videoLayer.player !== player {
            uiView.videoLayer.player = player
        }
    }
}

/// The system's own player, with its transport and its fullscreen button.
/// It shows the same playback as the inline picture: one player, two windows.
struct SystemPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    /// True while covering the whole screen: the system controls are wanted then.
    var showsControls = true

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsControls
        controller.videoGravity = .resizeAspect
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.showsPlaybackControls = showsControls
    }
}

extension View {
    /// A white rounded group on the canvas, inset by the design's side margin.
    func card() -> some View {
        self
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
    }

    func pageSidePadding() -> some View {
        padding(.horizontal, Metrics.side)
    }
}

/// The three moments a list can be in when it has nothing yet.
enum EmptyStateKind {
    case loading
    case offline
    case nothingMatches
}
