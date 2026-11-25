import SwiftUI

/// Edits a draft; the list's applied filter changes only when Apply is tapped.
struct FilterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = EventFilter()

    init(_ filter: EventFilter) {
        _draft = State(initialValue: filter)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.isDemo {
                    DemoBadge(kind: .data)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Metrics.side)
                        .padding(.vertical, 8)
                }
                form($draft)
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("filter.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") { apply() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("filter.apply")
                }
            }
        }
        .accessibilityIdentifier("filter.sheet")
        .onChange(of: model.sessionExpired) { _, expired in
            // The sign-in-again sheet is presented by the root; this one makes room for it.
            if expired { dismiss() }
        }
        .usageScreen(.filter)
    }

    private func form(_ draft: Binding<EventFilter>) -> some View {
        Form {
            Section {
                Toggle("All dates", isOn: allDates(draft))
                    .accessibilityIdentifier("filter.all-dates")
                if draft.wrappedValue.day != nil {
                    DatePicker(
                        "Date",
                        selection: Binding(
                            get: { draft.wrappedValue.day ?? Calendar.current.startOfDay(for: Date()) },
                            set: { draft.wrappedValue.day = $0 }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .accessibilityIdentifier("filter.date-picker")
                }
            }
            if draft.wrappedValue.category != .recent {
                Section("Reason") {
                    reasonButton(
                        String(localized: "All reasons"),
                        selected: draft.wrappedValue.bucket == nil && draft.wrappedValue.reason == nil,
                        identifier: "filter.reason.all"
                    ) {
                        draft.wrappedValue.bucket = nil
                        draft.wrappedValue.reason = nil
                    }
                    if draft.wrappedValue.category == .sentry {
                        ForEach(SentryBucket.allCases, id: \.self) { bucket in
                            reasonButton(bucket.title, selected: draft.wrappedValue.bucket == bucket,
                                         identifier: "filter.reason.\(bucket.rawValue)") {
                                draft.wrappedValue.bucket = bucket
                            }
                        }
                    } else {
                        ForEach(EventFilter.reasons(in: model.events, category: .saved), id: \.self) { reason in
                            reasonButton(reason.title, selected: draft.wrappedValue.reason == reason,
                                         identifier: "filter.reason.\(reason.rawValue)") {
                                draft.wrappedValue.reason = reason
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    draft.wrappedValue.day = nil
                    draft.wrappedValue.bucket = nil
                    draft.wrappedValue.reason = nil
                } label: {
                    Label("Clear filter", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PlainActionButtonStyle())
                .accessibilityIdentifier("filter.clear")
            }
        }
    }

    private func allDates(_ draft: Binding<EventFilter>) -> Binding<Bool> {
        Binding(
            get: { draft.wrappedValue.day == nil },
            set: { allDates in
                draft.wrappedValue.day = allDates ? nil : Calendar.current.startOfDay(for: Date())
            }
        )
    }

    private func reasonButton(_ title: String, selected: Bool, identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(Color.labelPrimary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.action)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func apply() {
        model.filter.day = draft.day
        model.filter.bucket = draft.bucket
        model.filter.reason = draft.reason
        dismiss()
    }
}
