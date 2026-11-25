import SwiftUI

/// One event in a day's card. The whole row is a single NavigationLink and a single VoiceOver element.
struct EventRow: View {
    let event: RecordedEvent
    var compact = false

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var coverSize: CGSize {
        compact ? CGSize(width: 96, height: 72) : Metrics.thumbSize
    }

    /// The tag on the row's picture: which kind of demo footage it is, or none for a server's.
    private var coverBadge: DemoBadge.Kind? {
        guard model.isDemo else { return nil }
        return event.isRealSample ? .realClip : .footage
    }

    private var accessibilityText: Text {
        if let seconds = event.realSampleSeconds {
            return Text("Real recording sample") + Text(", ") + Text(Display.sampleSummary(seconds))
        }
        let reason = TriggerReasons.label(for: event.meta.reason).title
        return Text(Display.clock(event.start))
            + Text(", ")
            + Text(Display.place(city: event.meta.city, street: event.meta.street))
            + Text(", ")
            + Text(reason)
    }

    var body: some View {
        NavigationLink(value: event) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    verticalContent
                } else {
                    horizontalContent
                }
            }
            .padding(.horizontal, Metrics.side)
            .padding(.vertical, 16)
            .frame(minHeight: Metrics.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens the event")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("events.row.\(event.id)")
    }

    private var horizontalContent: some View {
        HStack(spacing: 12) {
            cover
            text
            chevron
        }
    }

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            cover
            HStack(alignment: .top, spacing: 12) {
                text
                chevron
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let seconds = event.realSampleSeconds {
                // No clock time and no place: the real recording has neither, and the moment the demo
                // gives this row is only where it sits in the list.
                Text("Real recording sample")
                    .font(.headline)
                    .foregroundStyle(Color.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Display.sampleSummary(seconds))
                    .font(.subheadline)
                    .foregroundStyle(Color.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Display.clock(event.start))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(Color.labelPrimary)
                // One line in the row, as drawn: a place that runs long steps down a little, then ends
                // with an ellipsis. The whole place is still read by VoiceOver and shown on the playback page.
                Text(Display.place(city: event.meta.city, street: event.meta.street))
                    .font(.subheadline)
                    .foregroundStyle(Color.labelSecondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.9)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text(TriggerReasons.label(for: event.meta.reason).title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.labelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(Color.labelSecondary)
            .accessibilityHidden(true)
    }

    /// The still the source has for the cover, except for the real recording without its own in the app:
    /// the demo's word for "no such picture" is a path to nowhere, and the row then shows no preview.
    private func preview(for cover: (video: ClipVideo, time: TimeInterval)) -> MediaRequest? {
        guard let request = model.source?.thumbnail(for: cover.video, at: cover.time) else { return nil }
        return event.isRealSample && request.url.path == "/dev/null" ? nil : request
    }

    @ViewBuilder
    private var cover: some View {
        // Nothing drawn stands in for the real recording: its own still, or no preview at all.
        if let cover = event.cover, let request = preview(for: cover) {
            Thumbnail(
                request: request,
                name: cover.video.camera.title,
                badge: coverBadge,
                size: coverSize
            )
            .accessibilityHidden(true)
        } else {
            ZStack {
                Color.labelSecondary.opacity(0.12)
                VStack(spacing: 4) {
                    Image(systemName: "video")
                        .font(.system(size: 24))
                        .accessibilityHidden(true)
                    Text("No preview")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.labelSecondary)
            }
            .frame(width: coverSize.width)
            .frame(minHeight: coverSize.height)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.thumbCorner, style: .continuous))
            .accessibilityHidden(true)
        }
    }
}

/// The line between two rows, beginning at the text column rather than cutting through the cover.
struct EventRowSeparator: View {
    var compact = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Color.separatorToken)
            .frame(height: 1 / displayScale)
            .padding(.leading, Metrics.side + (compact ? 96 : 112) + 12)
    }
}

/// Three non-interactive rows in exactly the geometry of EventRow while the first request is running.
struct EventSkeletonList: View {
    var compact = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                EventSkeletonRow(compact: compact)
                if index < 2 {
                    EventRowSeparator(compact: compact)
                }
            }
        }
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading…")
        .accessibilityIdentifier("events.skeleton")
    }
}

private struct EventSkeletonRow: View {
    var compact = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var coverSize: CGSize {
        compact ? CGSize(width: 96, height: 72) : Metrics.thumbSize
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    cover
                    blocks
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    cover
                    blocks
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.labelSecondary.opacity(0.12))
                        .frame(width: 6, height: 12)
                }
            }
        }
        .padding(.horizontal, Metrics.side)
        .padding(.vertical, 16)
        .frame(minHeight: Metrics.rowMinHeight)
    }

    private var cover: some View {
        RoundedRectangle(cornerRadius: Metrics.thumbCorner, style: .continuous)
            .fill(Color.labelSecondary.opacity(0.12))
            .frame(width: coverSize.width, height: coverSize.height)
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.labelSecondary.opacity(0.12))
                .frame(width: 52, height: 17)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.labelSecondary.opacity(0.12))
                .frame(width: 116, height: 15)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.labelSecondary.opacity(0.12))
                .frame(width: 78, height: 13)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
