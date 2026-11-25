import SwiftUI

/// The feedback form, counted as a screen like the app's own ones.
struct FeedbackSheet: View {
    var body: some View {
        FeedbackView()
            .usageScreen(.feedback)
    }
}
