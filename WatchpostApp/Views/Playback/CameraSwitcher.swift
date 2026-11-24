import SwiftUI
import UIKit

/// Cameras are laid out by their position in the car, folding columns instead of hiding a camera.
struct CameraSwitcher: View {
    let cameras: [Camera]
    let selected: Camera
    let available: Set<Camera>
    let onSelect: (Camera) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var availableWidth: CGFloat = 0

    private var columns: Int {
        guard availableWidth > 0 else { return 1 }
        // CameraLayout expects the whole screen width and reserves the page margins itself.
        let wholeWidth = availableWidth + CameraLayout.sideMargin * 2
        return CameraLayout.columnCount(for: cameras, width: wholeWidth,
                                        sizeCategory: dynamicTypeSize.contentSizeCategory)
    }

    private var rows: [[Camera]] {
        CameraLayout.rows(cameras, columns: columns)
    }

    var body: some View {
        VStack(spacing: CameraLayout.spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: CameraLayout.spacing) {
                    ForEach(row, id: \.self) { camera in
                        cameraButton(camera)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            availableWidth = width
        }
        .accessibilityIdentifier("playback.cameras")
    }

    private func cameraButton(_ camera: Camera) -> some View {
        let isAvailable = available.contains(camera)

        return Button {
            onSelect(camera)
            UIAccessibility.post(notification: .announcement, argument: camera.title)
        } label: {
            Text(camera.title)
                .multilineTextAlignment(.center)
                .opacity(isAvailable ? 1 : 0.4)
        }
        .buttonStyle(ChipStyle(selected: camera == selected))
        .disabled(!isAvailable)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(camera.title))
        .accessibilityValue(Text(verbatim: isAvailable ? "" : String(localized: "No footage", comment: "Camera has no recording in the current minute")))
        .accessibilityAddTraits(camera == selected ? .isSelected : [])
        .accessibilityIdentifier("playback.camera.\(camera.rawValue)")
    }
}

private extension DynamicTypeSize {
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
