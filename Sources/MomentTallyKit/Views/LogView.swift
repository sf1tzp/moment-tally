import SwiftUI
import MomentTallyCore

/// The Log tab: a day-sectioned, scrollable list of the week's moments.
/// Clicking a row expands it into an inline `TimeSpanEditorView`.
///
/// The list is narrowed by one `LogFilter` (#51, #298) in two layers: the
/// chips another surface handed over (`HistoryModel.logFilter` — a legend
/// value from History, a day from the Calendar) and the text typed here.
/// The chips row sits above the field, each removable, so a short list
/// says why.
package struct LogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openAppSection) private var openAppSection
    /// The portrait iPad arrangement (#280) hosts the Log inside one
    /// screen-long scroll: the rows drop their own ScrollView and the
    /// hand-off scroll (#130) goes through the ancestor's proxy.
    @Environment(\.outerScroll) private var outerScroll
    /// The id of the span currently expanded for editing (one at a time).
    @State private var editingID: Int?
    /// The filter field's raw text (#51); parsed fresh each render and
    /// composed over the model's chips (#298).
    @State private var filterText = ""

    package init() {}

    package var body: some View {
        Group {
            if let outerScroll {
                content(scrolledBy: outerScroll)
            } else {
                ScrollViewReader { proxy in
                    content(scrolledBy: proxy)
                }
            }
        }
        .task { await model.history.loadIfNeeded() }
    }

    private func content(scrolledBy proxy: ScrollViewProxy) -> some View {
        let history = model.history
        return VStack(spacing: 0) {
            WeekNavigatorView()
            filterChips
            filterField
            Divider()

            if let error = history.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            if history.spans.isEmpty && !history.isLoading {
                emptyState
            } else if filteredSpans.isEmpty && !history.isLoading {
                // The week has spans; the filter just matches none of them.
                noMatchState
            } else if outerScroll != nil {
                rows
            } else {
                ScrollView {
                    rows
                }
            }
        }
        // The Calendar redirects here instead of editing in place (#130):
        // onAppear covers the tab switch, onChange the already-visible
        // case, and the isLoading edge a hand-off that moved the week
        // first (#69) — the span only arrives when its reload lands.
        .onAppear { consumePendingEdit(proxy) }
        .onChange(of: model.history.pendingLogEditID) { consumePendingEdit(proxy) }
        .onChange(of: model.history.isLoading) { consumePendingEdit(proxy) }
        // A hand-off (#298) replaces the chips itself; the typed text is
        // this view's, so it is dropped here — the list shows what the
        // sender asked for, nothing narrower.
        .onChange(of: model.history.logHandoffCount) { filterText = "" }
    }

    /// The week's rows under pinned day headers. Pinning is relative to
    /// whichever ScrollView encloses the stack — the Log's own, or the
    /// portrait arrangement's outer one.
    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: 0,
                   pinnedViews: .sectionHeaders) {
            // Newest day first, matching the newest-first span order.
            ForEach(daysWithSpans, id: \.day.start) { group in
                Section {
                    ForEach(group.spans) { span in
                        row(for: span)
                            .id(span.id)
                        Divider().padding(.leading, 12)
                    }
                } header: {
                    dayHeader(group.day)
                }
            }
        }
    }

    /// Open the span another tab handed off (#130): drop a filter that would
    /// hide it, expand its editor, and scroll its row into view. The id stays
    /// pending until the span is actually in the loaded week, so a hand-off
    /// racing its own reload (#69) isn't dropped on the floor.
    private func consumePendingEdit(_ proxy: ScrollViewProxy) {
        guard let id = model.history.pendingLogEditID else { return }
        guard let span = model.history.spans.first(where: { $0.id == id }) else { return }
        model.history.pendingLogEditID = nil
        // The hand-off already dropped the typed text; the chips go too if
        // they hide the row (a hand-off that set both asked for the row
        // inside the filter, so normally they keep it).
        if !filter.matches(span) {
            filterText = ""
            if !model.history.logFilter.matches(span) { clearChips() }
        }
        // No session claim here — for a running span, `requestLog(editing:)`
        // claimed it back at the sender, ahead of this render.
        editingID = id
        // Scroll once the row list (and the expanded editor) has laid out.
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
    }

    // MARK: Filtering (#51, #298)

    /// The chips with the field's text parsed over them.
    private var filter: LogFilter { model.history.logFilter.withText(filterText) }

    private func clearChips() {
        withAnimation(.snappy) { model.history.logFilter = LogFilter() }
    }

    private func clearFilter() {
        filterText = ""
        clearChips()
    }

    /// The week's spans narrowed by the filter field (all of them when it's
    /// empty). Client-side over the already-loaded week.
    private var filteredSpans: [TimeSpan] {
        let filter = filter
        return filter.isEmpty ? model.history.spans
                              : model.history.spans.filter { filter.matches($0) }
    }

    /// The hand-off's chips (#298): one per label in its tag colour, one
    /// for the window, each with its own ×. Only rendered while there are
    /// any, so the plain Log keeps its shape.
    @ViewBuilder
    private var filterChips: some View {
        let chips = model.history.logFilter
        if chips.hasStructure {
            FlowLayout(spacing: 4) {
                if let window = chips.window {
                    FilterChip(text: Self.windowLabel(window),
                               symbol: "calendar",
                               color: Color.accentColor,
                               help: "Moments overlapping this window — click × to show the whole week") {
                        withAnimation(.snappy) { model.history.logFilter.window = nil }
                    }
                }
                ForEach(chips.labels, id: \.self) { label in
                    FilterChip(text: label.value.isEmpty ? "\(label.key): (no value)"
                                                         : "\(label.key): \(label.value)",
                               symbol: nil,
                               color: model.tagColor(for: label.key, value: label.value),
                               help: "Moments marked \(label.key): \(label.value) — click × to drop this mark from the filter") {
                        withAnimation(.snappy) {
                            model.history.logFilter.labels.removeAll { $0 == label }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filter chips")
        }
    }

    /// "Tue 22" for a whole calendar day, "Tue 22 · 13:00 – 17:00" for a
    /// run of hours inside one, both ends dated when the window crosses
    /// midnight.
    private static func windowLabel(_ window: DateInterval) -> String {
        let calendar = Calendar.current
        let day = Date.FormatStyle.dateTime.weekday(.abbreviated).day()
        let startDay = calendar.startOfDay(for: window.start)
        if window.start == startDay,
           window.end == calendar.date(byAdding: .day, value: 1, to: startDay) {
            return window.start.formatted(day)
        }
        let clock = TimeSpan.clock
        // A window ending exactly at midnight still belongs to its day.
        let lastMoment = window.end.addingTimeInterval(-1)
        if calendar.isDate(lastMoment, inSameDayAs: window.start) {
            return "\(window.start.formatted(day)) · \(clock.string(from: window.start)) – \(clock.string(from: window.end))"
        }
        return "\(window.start.formatted(day)) \(clock.string(from: window.start)) – "
            + "\(lastMoment.formatted(day)) \(clock.string(from: window.end))"
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(filter.isEmpty ? AnyShapeStyle(.secondary)
                                                : AnyShapeStyle(Color.accentColor))
            TextField("Filter — client:a, or text to search", text: $filterText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .help("key:value keeps moments whose value for that key starts with the text — quote it (key:\"value\") for an exact match; several AND together; other words search marks and notes.")
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Days of the week that have at least one filtered span starting in
    /// them, newest first, each with its spans (already sorted newest first).
    private var daysWithSpans: [(day: DateInterval, spans: [TimeSpan])] {
        let filtered = filteredSpans
        return model.history.days.reversed().compactMap { day in
            let spans = filtered.filter { day.contains($0.start) }
            return spans.isEmpty ? nil : (day, spans)
        }
    }

    private func dayHeader(_ day: DateInterval) -> some View {
        HStack {
            Text(day.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(formatDuration(dayTotalSeconds(in: day)))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// The day header's total over the *filtered* set, so per-day sums stay
    /// meaningful under a filter ("time on client:a per day this week").
    /// Same clipping semantics as `HistoryModel.totalSeconds(in:)`: overnight
    /// spans contribute to each day they touch.
    private func dayTotalSeconds(in day: DateInterval) -> TimeInterval {
        filteredSpans.reduce(0) { $0 + model.history.clippedSeconds(of: $1, in: day) }
    }

    @ViewBuilder
    private func row(for span: TimeSpan) -> some View {
        if editingID == span.id {
            TimeSpanEditorView(span: span,
                               onDone: { editingID = nil },
                               // New Timer hands the panel to the span it
                               // started — its (running) row expands here.
                               onOpen: { editingID = $0.id })
                .background(Color.accentColor.opacity(0.06))
        } else {
            HStack(spacing: 0) {
                Button {
                    editingID = span.id
                    // Expanding a running row claims the shared edit session
                    // (see TimeSpanEditorView) — an explicit user action, so
                    // it may take the session from another surface's editor.
                    if span.isRunning {
                        Task { await model.beginEditing(span) }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(span.timeRangeLabel)
                                .font(.callout.monospacedDigit())
                            Text(span.isRunning
                                 ? "running"
                                 : formatDuration(span.durationSeconds))
                                .font(.caption)
                                .foregroundStyle(span.isRunning ? .orange : .secondary)
                        }
                        .frame(width: 110, alignment: .leading)

                        VStack(alignment: .leading, spacing: 3) {
                            if !span.labels.isEmpty {
                                // Matched pills first, so what the filter hit
                                // stays visible when a row's tags run long.
                                FlowLayout(spacing: 4) {
                                    ForEach(filter.highlightedFirst(span.labels),
                                            id: \.self) { tag in
                                        TagPill(key: tag.key, value: tag.value,
                                                color: model.tagColor(for: tag.key, value: tag.value))
                                    }
                                }
                            }
                            if !span.note.isEmpty {
                                Text(span.note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to edit")

                HStack(spacing: 2) {
                    // Lifecycle actions on the collapsed row (#170) — the
                    // common recoveries shouldn't require expanding the
                    // editor first. Finished rows offer Re-Open and New
                    // Timer, acting on the span's saved fields (there are no
                    // drafts while collapsed); running rows offer Stop, the
                    // same plain funnel as the popover's stop button.
                    if span.isRunning {
                        Button {
                            Task { await model.stop(id: span.id) }
                        } label: {
                            Image(systemName: "stop.circle")
                        }
                        .buttonStyle(HoverIconButtonStyle())
                        .disabled(model.isBusy)
                        .help("Stop")
                    } else {
                        Button {
                            Task { await model.reopen(id: span.id, start: span.start,
                                                      tags: span.labels, note: span.note) }
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(HoverIconButtonStyle())
                        .disabled(model.isBusy)
                        .help("Re-open — this becomes the running timer again, absorbing the gap since it stopped")

                        Button {
                            Task { await model.start(tags: span.labels) }
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(HoverIconButtonStyle())
                        .disabled(model.isBusy)
                        .help("Start a new timer with these marks")
                    }

                    // Tags with no matching saved set can become one, right
                    // where the pattern is noticed — the Tag Sets pane opens
                    // on the new set with only the name left to fill in.
                    if !span.labels.isEmpty, !model.hasTagSet(matching: span.labels) {
                        Button {
                            model.newTagSet(from: span.labels)
                            openAppSection(.tagSets)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(HoverIconButtonStyle())
                        .help("Save these marks as a tally")
                    }
                }
                .padding(.trailing, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No moments this week")
                .foregroundStyle(.secondary)
            Spacer()
        }
        // The Spacers fill a standalone Log; embedded (#280) they have
        // nothing to fill, so the floor keeps the state from collapsing.
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var noMatchState: some View {
        let text = filterText.trimmingCharacters(in: .whitespaces)
        return VStack(spacing: 8) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(text.isEmpty ? "No moments match the filter"
                              : "No moments match “\(text)”")
                .foregroundStyle(.secondary)
            Button("Clear Filter") { clearFilter() }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// One removable chip of the Log's structured filter (#298): a label in its
/// tag colour, or the window on the accent — the `TagPill` shape with an ×
/// at its trailing end.
private struct FilterChip: View {
    let text: String
    let symbol: String?
    let color: Color
    let help: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
                .font(.caption2)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(text) from the filter")
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(color))
        .foregroundStyle(color.contrastingTextColor)
        .help(help)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}
