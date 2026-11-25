import SwiftUI
import UIKit

/// The root of the demo and server modes. The app's NavigationStack is owned by RootView.
struct EventsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showServers = false
    @State private var showFilter = false

    private var filteredEvents: [RecordedEvent] {
        model.events.filter { model.filter.matches($0) }
    }

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = min(proxy.size.width, Metrics.side * 2 + 600) - Metrics.side * 2
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.isDemo {
                        serverLine
                    }
                    if model.loadState == .failed && !model.events.isEmpty {
                        refreshBanner
                    }
                    StorageSummary()
                    categoryPicker
                    filterChips
                    listContent(contentWidth: contentWidth)
                }
                .padding(.horizontal, Metrics.side)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: Metrics.side * 2 + 600)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await model.refresh() }
            .safeAreaInset(edge: .bottom) {
                if model.isDemo {
                    demoNote
                }
            }
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Events")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Its own item, outside the button's glass background, so it does not read as the
            // button's label.
            if model.isDemo {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarTrailing) { demoBadge }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarTrailing) { demoBadge }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showServers = true
                } label: {
                    // An HStack, not a Label: a navigation bar keeps only a Label's symbol.
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack")
                        Text("Servers", comment: "Events screen button that opens the list of saved servers")
                            .font(.footnote.weight(.medium))
                    }
                }
                .tint(Color.action)
                .accessibilityLabel(serverButtonLabel)
                .accessibilityIdentifier("events.servers")
            }
        }
        .sheet(isPresented: $showFilter) {
            FilterSheet(model.filter)
        }
        .serversSheet(isPresented: $showServers)
        .task { await model.refreshIfNeeded() }
        .usageScreen(.events)
    }

    private var demoBadge: some View {
        DemoBadge(kind: .data)
            .accessibilityIdentifier("events.demo-badge")
    }

    private var serverButtonLabel: Text {
        if let record = model.currentRecord {
            Text("Switch server, current") + Text(" \(record.hostLabel)")
        } else {
            Text("Switch server")
        }
    }

    private var serverLine: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    hostText
                    presence
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    hostText
                    presence
                        .layoutPriority(1)
                }
            }
        }
        .frame(minHeight: 24)
    }

    private var hostText: some View {
        Text(model.currentRecord?.hostLabel ?? Display.missing)
            .font(.subheadline)
            .foregroundStyle(Color.labelPrimary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("events.host")
    }

    @ViewBuilder
    private var presence: some View {
        if model.sessionExpired || model.serverIsOnline == false {
            presenceLabel(icon: "wifi.exclamationmark", text: "Offline", tint: .labelSecondary)
        } else if model.serverIsOnline == true {
            presenceLabel(icon: "checkmark.circle", text: "Online", tint: .success)
        } else if model.loadState == .loading {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Connecting…")
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("events.presence")
        }
    }

    private func presenceLabel(icon: String, text: LocalizedStringKey, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("events.presence")
    }

    /// Over a list that is still on screen after a refresh that did not work. Its two lines are one
    /// element for VoiceOver. When the phone may not have got through to a server on its own network,
    /// the connect page's line and the way to Settings follow underneath, outside that element: a
    /// button inside a combined one cannot be activated on its own.
    private var refreshBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                        .accessibilityHidden(true)
                    Text("Sync failed. Pull to retry")
                }
                .font(.subheadline)
                .foregroundStyle(Color.warning)
                (Text("Last refreshed") + Text(" \(refreshTime)"))
                    .font(.footnote)
                    .foregroundStyle(Color.labelSecondary)
            }
            .accessibilityElement(children: .combine)

            if model.listMayNeedLocalNetworkPermission {
                // The 4 above is for two tight lines; the help reads as its own block 8 under, as on
                // the connect page.
                localNetworkHelp(centered: false)
                    .padding(.top, 4)
            }
        }
        .accessibilityIdentifier("events.banner")
    }

    private var refreshTime: String {
        guard let lastRefresh = model.lastRefresh else { return Display.missing }
        if Calendar.current.isDateInToday(lastRefresh) {
            return Display.clock(lastRefresh)
        }
        return Display.shortStamp(lastRefresh)
    }

    private var categoryBinding: Binding<ClipCategory> {
        Binding(
            get: { model.filter.category },
            set: { model.setCategory($0) }
        )
    }

    private var categoryPicker: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                categoryPickerContent
                    .pickerStyle(.menu)
            } else {
                categoryPickerContent
                    .pickerStyle(.segmented)
            }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("events.segmented")
    }

    private var categoryPickerContent: some View {
        Picker("Category", selection: categoryBinding) {
            ForEach(ClipCategory.allCases, id: \.self) { category in
                Text(category.title)
                    .accessibilityLabel(category.fullTitle)
            }
        }
        .labelsHidden()
    }

    private var filterChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                dayChip.fixedSize(horizontal: true, vertical: false)
                reasonChip.fixedSize(horizontal: true, vertical: false)
            }
            VStack(spacing: 8) {
                dayChip
                reasonChip
            }
        }
    }

    private var dayChip: some View {
        Button {
            showFilter = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.filter.day == nil ? "calendar" : "checkmark")
                    .accessibilityHidden(true)
                Text(dayChipTitle)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(ChipStyle(selected: model.filter.day != nil))
        .accessibilityLabel(Text("Date, ") + Text(dayChipTitle))
        .accessibilityIdentifier("events.filter.day")
    }

    private var reasonChip: some View {
        Button {
            showFilter = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: reasonChipSelected ? "checkmark" : "line.3.horizontal.decrease")
                    .accessibilityHidden(true)
                Text(reasonChipTitle)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(ChipStyle(selected: reasonChipSelected))
        .accessibilityLabel(Text("Reason, ") + Text(reasonChipTitle))
        .accessibilityIdentifier("events.filter.reason")
    }

    private var dayChipTitle: String {
        guard let day = model.filter.day else { return String(localized: "All dates") }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMEd")
        return formatter.string(from: day)
    }

    private var reasonChipSelected: Bool {
        model.filter.bucket != nil || model.filter.reason != nil
    }

    private var reasonChipTitle: String {
        if let bucket = model.filter.bucket {
            return bucket.title
        }
        if let reason = model.filter.reason {
            return reason.title
        }
        return String(localized: "All reasons")
    }

    @ViewBuilder
    private func listContent(contentWidth: CGFloat) -> some View {
        let events = filteredEvents
        if model.events.isEmpty && (model.loadState == .idle || model.loadState == .loading) {
            loadingList(compact: contentWidth < 350)
        } else if model.events.isEmpty && model.loadState == .failed {
            loadFailure
        } else if events.isEmpty && model.filter.isFiltering {
            filterEmpty
        } else if events.isEmpty {
            categoryEmpty
        } else {
            eventDays(EventDay.group(events), compact: contentWidth < 350)
        }
    }

    private func loadingList(compact: Bool) -> some View {
        VStack(spacing: 8) {
            EventSkeletonList(compact: compact)
            Text("Loading…")
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
    }

    private var loadFailure: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 32))
                .foregroundStyle(Color.labelSecondary)
                .accessibilityHidden(true)
            loadFailureMessage
                .font(.subheadline)
                .foregroundStyle(Color.labelPrimary)
                .multilineTextAlignment(.center)
            Button {
                Task { await model.refresh() }
            } label: {
                Text("Retry")
            }
            .buttonStyle(PrimaryButtonStyle())
            .frame(maxWidth: 280)
            .accessibilityIdentifier("events.retry")
            if model.listMayNeedLocalNetworkPermission {
                localNetworkHelp(centered: true)
            }
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("events.empty")
    }

    /// The connect page's line for a phone that may not have got through to a server on its own
    /// network, and the way to the setting it names: under the empty list that could not be loaded,
    /// where all is centred and 12 apart, and leading under the banner, 8 apart as on the connect page.
    private func localNetworkHelp(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: centered ? 12 : 8) {
            Text("If the phone can't see the server, allow Local Network for Watchpost in Settings.", comment: "Help after the phone could not reach a server on its own network")
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)
                .multilineTextAlignment(centered ? .center : .leading)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(PlainActionButtonStyle())
            .accessibilityIdentifier("events.open-settings")
        }
    }

    private var loadFailureMessage: Text {
        if model.listNeedsSignIn {
            Text("Sign in to this server again to view events.")
        } else {
            Text("Couldn't load events.")
        }
    }

    private var categoryEmpty: some View {
        VStack(spacing: 12) {
            Image(systemName: "video")
                .font(.system(size: 32))
                .foregroundStyle(Color.labelSecondary)
                .accessibilityHidden(true)
            Text("No events yet")
                .font(.subheadline)
                .foregroundStyle(Color.labelPrimary)
            Text(model.filter.category.fullTitle)
                .font(.footnote)
                .foregroundStyle(Color.labelSecondary)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("events.empty")
    }

    private var filterEmpty: some View {
        VStack(spacing: 8) {
            Text("No events match this filter")
                .font(.subheadline)
                .foregroundStyle(Color.labelPrimary)
                .multilineTextAlignment(.center)
            Button {
                model.clearFilter()
            } label: {
                Label("Clear filter", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(PlainActionButtonStyle())
            .accessibilityIdentifier("events.clear-filter")
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("events.empty")
    }

    /// The list's cards. The real recording sample has no date of its own, so it is not put under a
    /// day's header: it comes first, in a card of its own, and the days follow.
    private func eventDays(_ days: [EventDay], compact: Bool) -> some View {
        let samples = days.flatMap(\.events).filter(\.isRealSample)
        let dated = days.compactMap { day -> EventDay? in
            let events = day.events.filter { !$0.isRealSample }
            return events.isEmpty ? nil : EventDay(day: day.day, events: events)
        }
        return LazyVStack(alignment: .leading, spacing: 24) {
            if !samples.isEmpty {
                rows(samples, compact: compact)
                    .card()
            }
            ForEach(dated) { day in
                VStack(alignment: .leading, spacing: 8) {
                    dayHeader(day)
                    rows(day.events, compact: compact)
                        .card()
                }
            }
        }
        .padding(.top, 8)
        .accessibilityIdentifier("events.list")
    }

    /// The rows of one card, each followed by the line under it but the last.
    private func rows(_ events: [RecordedEvent], compact: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(events) { event in
                EventRow(event: event, compact: compact)
                if event.id != events.last?.id {
                    EventRowSeparator(compact: compact)
                }
            }
        }
    }

    @ViewBuilder
    private func dayHeader(_ day: EventDay) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                dayTitle(day)
                dayCount(day)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline) {
                dayTitle(day)
                Spacer(minLength: 12)
                dayCount(day)
            }
        }
    }

    private func dayTitle(_ day: EventDay) -> some View {
        Text(Display.dayHeader(day.day))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.labelPrimary)
    }

    private func dayCount(_ day: EventDay) -> some View {
        // English has two forms ("1 clip"); the tables give both the same Chinese wording.
        let count = day.events.count
        let text = count == 1
            ? String(format: String(localized: "%lld clip", comment: "Number of recordings below one day header, one recording"), count)
            : String(format: String(localized: "%lld clips", comment: "Number of recordings below one day header"), count)
        return Text(text)
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(Color.labelSecondary)
    }

    private var demoNote: some View {
        Text("You're viewing sample data. Connect a server for real events.")
            .font(.footnote)
            .foregroundStyle(Color.labelSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, Metrics.side)
            .background(Color.canvas)
            .accessibilityIdentifier("events.demo-note")
    }
}
