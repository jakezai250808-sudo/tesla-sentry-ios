import SwiftUI
import UIKit

// How the camera switcher is laid out: by where the cameras sit on the car and
// by how much room the names need, never by scrolling a camera out of sight.
//
// Six cameras:   左前翼  前视   右前翼          Four cameras:  前视  后视  左前翼  右前翼
//                左B柱   后视   右B柱
// With large text or long names both fold to two columns, then to one.
enum CameraLayout {
    static let spacing: CGFloat = 4
    static let sideMargin: CGFloat = 20
    /// Room on each side of a name inside its chip.
    static let chipPadding: CGFloat = 24

    /// The cameras in rows of `columns`, in `Camera.displayOrder`.
    static func rows(_ cameras: [Camera], columns: Int) -> [[Camera]] {
        guard columns > 0 else { return [] }
        return stride(from: 0, to: cameras.count, by: columns).map { Array(cameras[$0..<min($0 + columns, cameras.count)]) }
    }

    /// How many columns the switcher uses. `width` is the whole width the
    /// switcher may take (the chips keep `sideMargin` free on each side).
    static func columnCount(for cameras: [Camera], width: CGFloat,
                            sizeCategory: UIContentSizeCategory = .large,
                            titles: (Camera) -> String = { $0.title }) -> Int {
        let count = max(cameras.count, 1)
        let preferred: Int
        if count >= 5 {
            preferred = 3
        } else if count == 4 {
            preferred = 4
        } else {
            preferred = count
        }
        // Large text always folds to two columns, as the design says, so a name is never squeezed.
        let largest = sizeCategory.isAccessibilityCategory || sizeCategory >= .extraExtraExtraLarge ? 2 : preferred
        let inner = max(width - 2 * sideMargin, 1)
        let font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 17, weight: .semibold),
            compatibleWith: UITraitCollection(preferredContentSizeCategory: sizeCategory))
        let widest = cameras.map { camera in
            (titles(camera) as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        var columns = min(preferred, largest)
        while columns > 1 {
            let columnWidth = (inner - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            if widest + chipPadding <= columnWidth { break }
            columns -= 1
        }
        return max(columns, 1)
    }
}
