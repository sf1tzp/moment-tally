import SwiftUI
import MomentTallyCore

/// The Log tab: a day-sectioned, scrollable list of the week's moments.
/// Clicking a row expands it into an inline `TimeSpanEditorView`.
package struct LogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openAppSection) private var openAppSection
    /// The id of the span currently expanded for editing (one at a time).
    @State private var editingID: Int?
    /// The filter field's raw text (#51); parsed fresh each render.
    @State private var filterText = ""

    package init() {}

    package var body: some View {
        let history = model.history
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                WeekNavigatorView()
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
                } else {
                    ScrollView {
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
                }
            }
            // The Calendar redirects here instead of editing in place (#130):
            // onAppear covers the tab switch, onChange the already-visible
            // case, and the isLoading edge a hand-off that moved the week
            // first (#69) — the span only arrives when its reload lands.
            .onAppear { consumePendingEdit(proxy) }
            .onChange(of: model.history.pendingLogEditID) { consumePendingEdit(proxy) }
            .onChange(of: model.history.isLoading) { consumePendingEdit(proxy) }
        }
        .task { await history.loadIfNeeded() }
    }

    /// Open the span another tab handed off (#130): drop a filter that would
    /// hide it, expand its editor, and scroll its row into view. The id stays
    /// pending until the span is actually in the loaded week, so a hand-off
    /// racing its own reload (#69) isn't dropped on the floor.
    private func consumePendingEdit(_ proxy: ScrollViewProxy) {
        guard let id = model.history.pendingLogEditID else { return }
        guard let span = model.history.spans.first(where: { $0.id == id }) else { return }
        model.history.pendingLogEditID = nil
        if !filter.isEmpty, !filter.matches(span) { filterText = "" }
        // No session claim here — for a running span, `requestLogEdit(of:)`
        // claimed it back at the sender, ahead of this render.
        editingID = id
        // Scroll once the row list (and the expanded editor) has laid out.
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
    }

    // MARK: Filtering (#51)

    private var filter: LogFilter { LogFilter.parse(filterText) }

    /// The week's spans narrowed by the filter field (all of them when it's
    /// empty). Client-side over the already-loaded week.
    private var filteredSpans: [TimeSpan] {
        let filter = filter
        return filter.isEmpty ? model.history.spans
                              : model.history.spans.filter(filter.matches)
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
        .frame(maxWidth: .infinity)
    }

    private var noMatchState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No moments match “\(filterText.trimmingCharacters(in: .whitespaces))”")
                .foregroundStyle(.secondary)
            Button("Clear Filter") { filterText = "" }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
