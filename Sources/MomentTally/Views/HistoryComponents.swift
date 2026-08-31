import SwiftUI
import MomentTallyCore
import MomentTallyKit

// Shared pieces for the three history tabs (Log, Calendar, History/charts).

// MARK: - Week navigator

/// `‹ Today ›  Jan 26 – Feb 1, 2026` — drives `HistoryModel.weekStart`, shown
/// at the top of the Log and Calendar tabs so they stay on the same week.
/// The History/charts tab renders its own header (`HistoryChartsView`): its
/// range picker can swap the week controls out entirely (#163), but it reuses
/// `WeekControlsView` so the stepping cluster stays one implementation.
struct WeekNavigatorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        HStack(spacing: 8) {
            WeekControlsView()

            Text(history.weekLabel)
                .font(.headline)

            Spacer()

            if history.isLoading {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await history.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The `‹ Today ›` week-stepping cluster, shared by the week navigator and
/// the charts header's week mode.
struct WeekControlsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let history = model.history
        HStack(spacing: 2) {
            Button { history.goToPreviousWeek() } label: {
                Image(systemName: "chevron.left")
            }
            Button("Today") { history.goToToday() }
                .disabled(history.isCurrentWeek)
            Button { history.goToNextWeek() } label: {
                Image(systemName: "chevron.right")
            }
        }
    }
}

// MARK: - Timespan editor

/// Inline editor for one timespan: start/end, tags, note, delete, and the
/// #60 lifecycle actions (Stop on a running span; Re-Open and New Timer on a
/// finished one). Used expanded-in-place by the Log and inside a popover by
/// the Calendar.
///
/// Two regimes: a *finished* span edits view-local drafts, saved through
/// `HistoryModel.update`. A *running* span instead binds the shared
/// `SpanEditSession` — the same drafts the popover's pencil editor shows —
/// so the running timer has one edit, whichever surface it's typed into
/// (#61). Explicit Save for now; whether the running editor should
/// live-commit like the popover is a review decision.
struct TimeSpanEditorView: View {
    @Environment(AppModel.self) private var model
    let span: TimeSpan
    var onDone: () -> Void
    /// Move the editing surface to another timespan — New Timer hands the
    /// panel over to the span it just started. Parents that can re-anchor
    /// their editor (the Log's expanded row) pass this; ones that can't (the
    /// Calendar's per-block popover, whose blocks don't exist until relayout)
    /// leave it nil and the panel just closes.
    var onOpen: ((TimeSpan) -> Void)?

    @State private var start: Date
    @State private var end: Date
    @State private var tagRows: [TagRow]
    @State private var note: String
    @State private var isSaving = false
    @State private var confirmingDelete = false
    /// Save, Cancel, and Delete closed the editor on purpose — the teardown
    /// autosave below must not re-commit (or resurrect) their drafts.
    @State private var closedExplicitly = false

    init(span: TimeSpan, onDone: @escaping () -> Void,
         onOpen: ((TimeSpan) -> Void)? = nil) {
        self.span = span
        self.onDone = onDone
        self.onOpen = onOpen
        _start = State(initialValue: span.start)
        _end = State(initialValue: span.end ?? Date())
        _tagRows = State(initialValue: span.labels.map {
            TagRow(key: $0.key, value: $0.value)
        })
        _note = State(initialValue: span.note)
    }

    var body: some View {
        // A stop registers in two steps: the span leaves `activeTimers`
        // synchronously, and the reloaded (finished) span value arrives a
        // beat later. Route on the first signal so the finished editor is on
        // screen for that whole window — the badge is replaced by the End
        // widget in place, with no collapse in between. The drafts it shows
        // are seeded by `willStop` (the badge path) or rebased by the
        // onChange below (a stop from any other surface).
        let stopLanded = span.isRunning
            && !model.activeTimers.contains { $0.id == span.id }
        Group {
            if span.isRunning && !stopLanded {
                runningBody
            } else {
                finishedBody
            }
        }
        .onChange(of: span) { old, new in
            // A stop landed under this editor (the running badge, or the
            // popover's Stop) and the panel stays open, switching regimes.
            // The finished drafts were captured back when the row expanded —
            // rebase them on the span as it was actually stopped (real end,
            // plus whatever the session committed on the way out). Only on
            // this transition: a finished span's drafts are the user's, not
            // to be clobbered by background reloads.
            if old.isRunning && !new.isRunning {
                start = new.start
                end = new.end ?? Date()
                tagRows = new.labels.map { TagRow(key: $0.key, value: $0.value) }
                note = new.note
            }
        }
        // Autosave on teardown (#224): clicking another row, collapsing, or
        // leaving the tab commits dirty drafts instead of dropping them —
        // edits are immediate everywhere else in the app. Explicit Save /
        // Cancel / Delete opted out above; half-typed mark rows follow the
        // Save button's own rule (`labels` drops empty-key rows). Running
        // spans commit the shared session's drafts the same way, but only
        // while the session is still this span's — a New Timer hand-off or a
        // cancel has already moved on.
        .onDisappear {
            guard !closedExplicitly else { return }
            if span.isRunning {
                if model.editSession?.spanID == span.id {
                    Task { await model.commitEditSession() }
                }
            } else if span.end != nil, draftsDiffer {
                Task {
                    await model.history.update(id: span.id, start: start, end: end,
                                               tags: tagRows.labels, note: note)
                }
            }
        }
    }

    /// Whether committing the drafts would change the span — the autosave
    /// gate, the finished-span sibling of `SpanEditSession.differs(from:)`.
    private var draftsDiffer: Bool {
        start != span.start
            || span.end.map { end != $0 } ?? true
            || tagRows.labels != span.labels
            || note != span.note
    }

    // MARK: Running span — the shared session

    @ViewBuilder
    private var runningBody: some View {
        if let session = model.editSession, session.spanID == span.id {
            RunningSessionEditor(session: session, onDone: onDone) {
                // The badge is about to stop this span: seed the finished
                // drafts from the live session so the finished regime shows
                // the right values the instant it takes over — the reloaded
                // span rebases them (real end time) in the onChange above.
                start = session.startDraft
                tagRows = session.tagDrafts
                note = session.noteDraft
                end = Date()
            }
        } else {
            // The session ended or moved to another editor — collapse.
            // Claiming it is the expansion click's job (see LogView /
            // CalendarView), never a render side effect: a row whose view
            // identity gets recreated while expanded (a filter toggle, lazy
            // scrolling) must not steal the session back from whichever
            // surface holds it now. (A stop never lands here — the body
            // routes to `finishedBody` the moment the span leaves
            // `activeTimers`.)
            Color.clear.frame(height: 1)
                .task { onDone() }
        }
    }

    // MARK: Finished span — view-local drafts

    private var finishedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MinuteSteppingDatePicker(label: "Start", date: $start)
                MinuteSteppingDatePicker(label: "End", date: $end)
                Spacer(minLength: 0)
                // The finished-span actions (#60), next to the fields they
                // act on. Re-Open writes what the panel shows minus the end
                // — drafts ride along — and the panel stays open, switched
                // to the running regime. New Timer starts a fresh span with
                // the drafted labels; this span stays put, any dirty drafts
                // on it landing via the teardown autosave (#224).
                Button("Re-Open") { reopen() }
                    .help("Clear the end — this moment becomes the running timer again, absorbing the gap since it stopped")
                Button("New Timer") {
                    Task {
                        isSaving = true
                        if let created = await model.start(tags: tagRows.labels) {
                            // Editing moves to the new timer: claim the
                            // session, then let the parent re-anchor its
                            // panel onto the new span (or just close, where
                            // it can't). A failed start keeps this editor.
                            if let onOpen {
                                await model.beginEditing(created)
                                onOpen(created)
                            } else {
                                onDone()
                            }
                        }
                        isSaving = false
                    }
                }
                .help("Start a new timer with these marks")
            }
            .disabled(isSaving)

            LabelRowsEditor(rows: $tagRows)
                .textFieldStyle(.roundedBorder)

            TextField("Note", text: $note)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Delete", role: .destructive) {
                    confirmingDelete = true
                }
                .confirmationDialog("Delete this moment?",
                                    isPresented: $confirmingDelete) {
                    Button("Delete", role: .destructive) {
                        Task {
                            isSaving = true
                            await model.history.delete(id: span.id)
                            isSaving = false
                            closedExplicitly = true
                            onDone()
                        }
                    }
                }
                Spacer()
                Button("Cancel") {
                    closedExplicitly = true
                    onDone()
                }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(isSaving)
        }
        .padding(10)
    }

    private func save() {
        Task {
            isSaving = true
            let saved = await model.history.update(
                id: span.id,
                start: start,
                end: end,
                tags: tagRows.labels,
                note: note)
            isSaving = false
            if saved {
                closedExplicitly = true
                onDone()
            }
        }
    }

    /// Re-Open (#60): commit the drafted fields with the end cleared, then
    /// claim the edit session so the panel stays open as the running editor.
    /// The claim races nothing: `reopen` returns on the main actor with no
    /// suspension before `beginEditing`'s synchronous session claim, so
    /// `runningBody` can never render session-less in between (its fallback
    /// would collapse the row).
    private func reopen() {
        Task {
            isSaving = true
            if let running = await model.reopen(id: span.id, start: start,
                                                tags: tagRows.labels, note: note) {
                await model.beginEditing(running)
            }
            isSaving = false
        }
    }
}

/// The running-span editor body: the same chrome as the finished editor, but
/// every field is a binding into the shared `SpanEditSession`, and Save goes
/// through the model's one commit funnel.
private struct RunningSessionEditor: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: SpanEditSession
    var onDone: () -> Void
    /// Runs just before the badge's stop is written: the parent seeds its
    /// finished-regime drafts from the session, so the hand-over renders
    /// with the right values from the first frame.
    var willStop: () -> Void

    @State private var isSaving = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                MinuteSteppingDatePicker(label: "Start", date: $session.startDraft)
                // The running badge doubles as the Stop button (#60), sitting
                // where the finished editor's End picker is — the end field
                // and the action that sets it share a slot.
                Button {
                    stop()
                } label: {
                    Label("Running", systemImage: "stop.circle")
                }
                .buttonStyle(HoverIconButtonStyle())
                .font(.callout)
                .help("Stop this timer")
            }

            LabelRowsEditor(rows: $session.tagDrafts)
                .textFieldStyle(.roundedBorder)

            TextField("Note", text: $session.noteDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Delete", role: .destructive) {
                    confirmingDelete = true
                }
                .confirmationDialog("Delete this moment?",
                                    isPresented: $confirmingDelete) {
                    Button("Delete", role: .destructive) {
                        Task {
                            isSaving = true
                            await model.history.delete(id: session.spanID)
                            isSaving = false
                            onDone()
                        }
                    }
                }
                Spacer()
                Button("Cancel") {
                    model.cancelEditing()
                    onDone()
                }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(isSaving)
        }
        .padding(10)
    }

    private func save() {
        Task {
            isSaving = true
            await model.finishEditing()
            isSaving = false
            // A failed write keeps the session (and this editor) open.
            if model.editSession == nil { onDone() }
        }
    }

    /// Stop from the editor: drafts are committed first — stopping must not
    /// silently discard an open edit (#70) — and a failed commit keeps the
    /// timer running and the editor open, like Save. The panel stays open:
    /// `willStop` seeds the parent's finished drafts, and the parent
    /// switches to the finished regime in place the moment the stop lands.
    private func stop() {
        Task {
            isSaving = true
            if await model.commitEditSession() {
                willStop()
                await model.stop(id: session.spanID)
            }
            isSaving = false
        }
    }
}

/// The label rows shared by both editor regimes: one row per tag (color
/// swatch, key, value, remove) plus the add-mark button.
private struct LabelRowsEditor: View {
    @Binding var rows: [TagRow]
    /// The row being drag-reordered — see RowReorder.swift.
    @State private var dragged: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($rows) { $tag in
                HStack(spacing: 6) {
                    RowReorderGrip(tag: tag, dragged: $dragged)
                    TagColorPicker(key: tag.key, value: tag.value)
                    TextField("key", text: $tag.key)
                        .autocorrectionDisabled()
                        .frame(width: LabelEditorStyle.keyFieldWidth)
                    Text(":").foregroundStyle(.secondary)
                    TextField("value", text: $tag.value)
                        .autocorrectionDisabled()
                    Button(role: .destructive) {
                        // Read the id before removeAll — reading the `tag`
                        // binding inside the predicate re-enters the array's
                        // exclusive access and traps.
                        let id = tag.id
                        rows.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .rowReorderDrop(tag, rows: $rows, dragged: $dragged)
            }
            Button {
                rows.append(TagRow())
            } label: {
                Label("Add Mark", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        // Covers both the expand-in-place appearance of the whole editor and
        // rows added/removed while it's open.
        .refreshesKeyViewLoop(on: rows.count)
    }
}

/// A date+time field whose up/down buttons step by the minute. The stock
/// `.stepperField` picker sends the arrows to whichever element is selected —
/// the *year*, before anything is clicked — so use the stepper-less `.field`
/// style and supply our own minute stepper. Arrow keys inside the field still
/// adjust the clicked element as usual.
private struct MinuteSteppingDatePicker: View {
    let label: String
    @Binding var date: Date

    var body: some View {
        HStack(spacing: 2) {
            DatePicker(label, selection: $date,
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field)
                // Keep the intrinsic width: sharing a row with a Spacer and
                // the #60 action buttons otherwise squeezes the label into a
                // one-character-per-line vertical wrap.
                .fixedSize()
            Stepper(label) {
                step(by: 1)
            } onDecrement: {
                step(by: -1)
            }
            .labelsHidden()
        }
    }

    /// Calendar arithmetic rather than ±60s so steps stay wall-clock minutes
    /// across DST transitions.
    private func step(by minutes: Int) {
        if let stepped = Calendar.current.date(byAdding: .minute,
                                               value: minutes, to: date) {
            date = stepped
        }
    }
}

// MARK: - Small formatting helpers

extension TimeSpan {
    /// "10:32 – 11:25", or "10:32 –" while running.
    var timeRangeLabel: String {
        let f = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute()
        let startText = start.formatted(f)
        guard let end else { return "\(startText) –" }
        return "\(startText) – \(end.formatted(f))"
    }

    /// Duration so far (running spans count up to now).
    var durationSeconds: TimeInterval {
        (end ?? Date()).timeIntervalSince(start)
    }
}
