import SwiftUI
import MomentTallyCore
import CoreTransferable
import UniformTypeIdentifiers

/// Drag payload: a value being dragged onto another key row — every instance
/// (`spanIDs` nil) or a hand-picked subset. JSON-encoded; the drag never
/// leaves the app.
private struct TagMovePayload: Codable, Transferable {
    let key: String
    let value: String
    let spanIDs: [Int]?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// The Tag Review tab: every tag key with the cardinality of its values —
/// distinct-value counts surface the messy keys (typos, near-duplicates,
/// casing drift) that quietly fragment the charts. Values expand into their
/// instances; renames are staged from the pencil, and dragging a value (or a
/// shift-click selection of instances) onto another key — or onto another
/// value, to land on that exact spelling — stages a move. Staged changes
/// collect in the Approve Changes pane at the bottom as a red/green diff and
/// apply as one batch.
struct TagReviewView: View {
    @Environment(AppModel.self) private var model

    /// What the rename sheet is renaming: a value of a key, or (value == nil)
    /// the key itself.
    private struct RenameTarget: Identifiable {
        let key: String
        let value: String?
        var id: String { value.map { "\(key)\u{1F}\($0)" } ?? key }
    }

    @State private var renameTarget: RenameTarget?
    /// Selected instance rows, so a shift-click selection can drag as one
    /// payload. Selection (like row identity) is the composite
    /// key␟value␟span-id, not the bare span id: a span carrying several
    /// labels appears under every key it matches, and duplicate tags in one
    /// List broke row hit-testing outright — rows stopped expanding (#69).
    @State private var selectedInstances = Set<String>()
    /// Expansion state, held explicitly (keyed by key / key␟value) instead of
    /// per-row `DisclosureGroup` state, so it survives the row re-creation
    /// that a rescan or an applied batch causes (#69).
    @State private var expandedKeys = Set<String>()
    @State private var expandedValues = Set<String>()

    private func valueID(_ key: String, _ value: String) -> String {
        "\(key)\u{1F}\(value)"
    }

    private func instanceID(_ key: String, _ value: String, _ spanID: Int) -> String {
        "\(key)\u{1F}\(value)\u{1F}\(spanID)"
    }

    private func isExpanded(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) },
                set: { expanded in
                    if expanded { set.wrappedValue.insert(id) }
                    else { set.wrappedValue.remove(id) }
                })
    }

    var body: some View {
        let review = model.review
        VStack(spacing: 0) {
            controls
            Divider()

            if let error = review.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(6)
            }

            if review.keyStats.isEmpty {
                emptyState
            } else {
                statsList
            }

            Divider()
            approvePane
        }
        .task {
            // First appearance scans; re-selections of the tab only refetch
            // when an edit elsewhere made the snapshot stale (#225).
            if !review.hasScanned { await review.scan() }
            else { await review.rescanIfStale() }
        }
        // Edits landing while the tab is frontmost (the popover's timer
        // controls, a CLI write, a sync pull) refresh the scan live — the
        // store publishes, this surface reacts (#225).
        .onChange(of: model.spanDataVersion) {
            Task { await review.rescanIfStale() }
        }
        .sheet(item: $renameTarget) { target in
            RenameSheet(key: target.key, value: target.value) {
                renameTarget = nil
            }
            .environment(model)
        }
    }

    // MARK: Controls

    private var controls: some View {
        @Bindable var review = model.review
        return HStack(spacing: 8) {
            Picker("Range", selection: $review.range) {
                ForEach(TrailingRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .fixedSize()
            .onChange(of: review.range) {
                Task { await review.scan() }
            }

            Button {
                Task { await review.scan() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan")
            .disabled(review.isScanning)

            if review.isScanning {
                ProgressView().controlSize(.small)
            }

            Spacer()

            Text("\(review.keyStats.count) keys · \(review.scannedCount) moments")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Stats list

    private var statsList: some View {
        List(selection: $selectedInstances) {
            ForEach(model.review.keyStats) { stat in
                DisclosureGroup(isExpanded: isExpanded(stat.key, in: $expandedKeys)) {
                    ForEach(stat.values) { value in
                        valueGroup(key: stat.key, value: value)
                    }
                } label: {
                    // Only instance rows join the multi-select: a key or
                    // value row swept into a shift-click range would silently
                    // add its whole subtree to the payload.
                    keyRow(stat)
                        .selectionDisabled()
                }
            }
        }
        .listStyle(.inset)
    }

    private func keyRow(_ stat: KeyStat) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.tagColor(for: stat.key))
                .frame(width: 9, height: 9)
            Text(stat.key)
                .fontWeight(.medium)
            Text("\(stat.values.count) \(stat.values.count == 1 ? "value" : "values")")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(.quaternary))
            Spacer()
            Text("\(stat.spanCount)×")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(formatDuration(stat.seconds))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Button {
                renameTarget = RenameTarget(key: stat.key, value: nil)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(HoverIconButtonStyle())
            .help("Rename this key everywhere")
        }
        // Key rows accept dragged values/instances: dropping stages a move
        // under this key, with the value spelling editable while staged.
        .dropDestination(for: TagMovePayload.self) { items, _ in
            var accepted = false
            for item in items {
                // Whole-value drop on its own key is a no-op (use the pencil
                // to respell); a subset drop on its own key stages a
                // subset-only respell, which is meaningful.
                guard item.key != stat.key || item.spanIDs != nil else { continue }
                model.review.stage(StagedChange(
                    fromKey: item.key, fromValue: item.value,
                    toKey: stat.key, toValue: item.value,
                    spanIDs: item.spanIDs))
                accepted = true
            }
            if accepted { selectedInstances.removeAll() }
            return accepted
        }
    }

    /// One value row, expandable into its matched instances.
    private func valueGroup(key: String, value: ValueStat) -> some View {
        DisclosureGroup(isExpanded: isExpanded(valueID(key, value.value), in: $expandedValues)) {
            // Row identity must be the composite, not the span id — the same
            // span shows up under every label it carries (see
            // `selectedInstances`).
            let instances = model.review.matches(key: key, value: value.value)
                .sorted { $0.start > $1.start }
                .map { (rowID: instanceID(key, value.value, $0.id), span: $0) }
            ForEach(instances, id: \.rowID) { instance in
                let span = instance.span
                if span.isRunning {
                    // Running spans can't be staged (see movableMatches);
                    // their rows are inert — no selection, no drag. The Log
                    // hand-off still works: its editor edits live timers.
                    instanceRow(span, key: key, value: value.value)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { openInLog(span) })
                        .selectionDisabled()
                        .help("Still running — stop it before moving it. Double-click to edit in the Log.")
                } else {
                    // Selection and drag initiation belong to the underlying
                    // NSTableView, which only sees presses the row content
                    // doesn't consume — so the double-click must be a
                    // *simultaneous* gesture. A plain .onTapGesture holds
                    // every mouse-down (waiting for the second click) and
                    // deadens its whole hit area to clicks and drags alike.
                    instanceRow(span, key: key, value: value.value)
                        .draggable(instancePayload(key: key, value: value.value, span: span)) {
                            TagPill(key: key, value: value.value,
                                    color: model.tagColor(for: key, value: value.value))
                        }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { openInLog(span) })
                        .tag(instance.rowID)
                        .help("Drag to move · double-click to edit in the Log")
                }
            }
        } label: {
            valueRow(key: key, value: value)
                .draggable(TagMovePayload(key: key, value: value.value, spanIDs: nil)) {
                    TagPill(key: key, value: value.value,
                            color: model.tagColor(for: key, value: value.value))
                }
                // Value rows accept drops too (#184): landing instances (or a
                // whole value) here stages a move to *this* key and value —
                // the direct gesture for "these three spans were planning,
                // not review". Key-row drops still exist for values that
                // don't have a row yet (the staged value stays editable).
                .dropDestination(for: TagMovePayload.self) { items, _ in
                    var accepted = false
                    for item in items {
                        // Dropping a value (or instances) on their own row
                        // changes nothing.
                        guard item.key != key || item.value != value.value else { continue }
                        model.review.stage(StagedChange(
                            fromKey: item.key, fromValue: item.value,
                            toKey: key, toValue: value.value,
                            spanIDs: item.spanIDs))
                        accepted = true
                    }
                    if accepted { selectedInstances.removeAll() }
                    return accepted
                }
                .selectionDisabled()   // see keyRow — instance rows only
        }
        .padding(.leading, 17)   // align under the key name, past the swatch
    }

    private func valueRow(key: String, value: ValueStat) -> some View {
        HStack(spacing: 8) {
            // With "color by value" on, the swatch edits the per-value
            // override in place (#69). Otherwise (and for the value-less
            // row) values can only render the key's color, so a read-only
            // dot mirroring the key row is honest.
            if model.colorTagsByValue && !value.value.isEmpty {
                TagColorPicker(key: key, value: value.value)
            } else {
                Circle()
                    .fill(model.tagColor(for: key, value: value.value))
                    .frame(width: 9, height: 9)
            }
            Text(value.value.isEmpty ? "(no value)" : value.value)
                .foregroundStyle(value.value.isEmpty ? .secondary : .primary)
            Spacer()
            Text("\(value.count)×")
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(formatDuration(value.seconds))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Button {
                renameTarget = RenameTarget(key: key, value: value.value)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(HoverIconButtonStyle())
            .help("Rename this value everywhere")
        }
    }

    /// One matched timespan under a value: date, duration, the span's *other*
    /// marks, note. Selectable (shift-click for ranges) and draggable —
    /// dragging a selected row drags the whole selection.
    ///
    /// The other marks are what tell instances apart when a value is shared
    /// widely (#223): under `type: editing`, the `client:`/`project:` pills
    /// are the only way to pick out the spans worth moving. The mark being
    /// reviewed is omitted — it's the group header right above.
    private func instanceRow(_ span: TimeSpan, key: String, value: String) -> some View {
        let others = span.labels.filter { $0.key != key || $0.value != value }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(span.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .monospacedDigit()
            Text(span.isRunning ? "running" : formatDuration(span.durationSeconds))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                if !others.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(others, id: \.self) { tag in
                            TagPill(key: tag.key, value: tag.value,
                                    color: model.tagColor(for: tag.key, value: tag.value))
                        }
                    }
                }
                if !span.note.isEmpty {
                    Text(span.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 17)
        // Text and pills don't hit-test the gaps between them; the explicit
        // shape gives the double-click gesture the whole row face. It must
        // pair with non-consuming gestures only (see the call site), or it
        // deadens the row to the table's selection and drag handling.
        .contentShape(Rectangle())
    }

    /// Hand a span to the Log tab and switch over — the same #130 hand-off
    /// the Calendar's blocks use. `requestLogEdit` moves the Log's week to
    /// the span first when it's outside the loaded one.
    private func openInLog(_ span: TimeSpan) {
        model.history.requestLogEdit(of: span)
        SettingsWindowManager.shared.show(model: model, tab: .log)
    }

    /// Dragging a row that's part of the current selection carries the whole
    /// selection (restricted to this value's movable instances); otherwise
    /// just the row itself.
    private func instancePayload(key: String, value: String, span: TimeSpan) -> TagMovePayload {
        // Selection carries composite ids; the payload wants span ids scoped
        // to this value's movable instances.
        let selected = Set(model.review.movableMatches(key: key, value: value)
            .map(\.id)
            .filter { selectedInstances.contains(instanceID(key, value, $0)) })
        let ids = selected.contains(span.id) ? selected.sorted() : [span.id]
        return TagMovePayload(key: key, value: value, spanIDs: ids)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tag.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(model.review.isScanning
                 ? "Scanning…" : "No marks in the scanned range")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Approve Changes pane

    /// Reserved space at the bottom: a slim hint bar when nothing is staged,
    /// otherwise the git-style diff of pending changes with Approve/Cancel.
    private var approvePane: some View {
        @Bindable var review = model.review
        return Group {
            if review.staged.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "tray")
                    Text("Nothing staged — drag a value (or selected instances) onto another key or value, or stage a rename from a pencil.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach($review.staged) { $change in
                                stagedChangeRow($change)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 150)

                    if review.isApplying {
                        HStack(spacing: 8) {
                            ProgressView(value: Double(review.renameDone),
                                         total: Double(max(1, review.renameTotal)))
                            Text("change \(review.applyIndex + 1) of \(review.staged.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Button("Cancel") { review.cancelApply() }
                        }
                    } else {
                        HStack {
                            Text("\(review.staged.count) staged \(review.staged.count == 1 ? "change" : "changes")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Approve Changes") {
                                Task { await review.applyStaged() }
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    /// One staged change as prose — the old name highlighted red, the new
    /// green — e.g. "Move 3 'planning' spans from project to repo". The
    /// target value stays editable until approved.
    private func stagedChangeRow(_ change: Binding<StagedChange>) -> some View {
        let value = change.wrappedValue
        let count = model.review.spans(for: value).count
        let total = model.review.movableMatches(key: value.fromKey,
                                                value: value.fromValue).count
        let countText = value.spanIDs == nil ? "\(count)" : "\(count) of \(total)"
        return HStack(spacing: 6) {
            prose(for: value, count: countText,
                  toKey: model.review.effectiveTargetKey(of: value))
            if value.toValue != nil {
                TextField("value", text: Binding(
                    get: { change.wrappedValue.toValue ?? "" },
                    set: { change.wrappedValue.toValue = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disabled(model.review.isApplying)
            }
            Spacer()
            Button {
                model.review.discard(value.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(HoverIconButtonStyle())
            .disabled(model.review.isApplying)
            .help("Discard this change")
        }
        .font(.callout)
        .padding(.horizontal, 4)
    }

    /// The sentence describing a staged change, ending just before the
    /// editable value field (when the change carries one). `toKey` is the
    /// *effective* target — key renames staged earlier folded in — so the
    /// pane describes what approving will actually do. Labels render as
    /// `TagPill`s in their real colors, matching the review list and the
    /// drag preview, instead of the generic red/green diff coloring (#69).
    private func prose(for change: StagedChange, count: String, toKey: String) -> some View {
        // The target key may not exist yet; apply will create it carrying
        // the source key's color, so preview it that way.
        let toColor = model.tagDefinitions.contains { $0.key == toKey }
            ? model.tagColor(for: toKey)
            : model.tagColor(for: change.fromKey)
        let fromValue = (change.fromValue?.isEmpty == true)
            ? "(no value)" : change.fromValue ?? ""
        let fromColor = model.tagColor(for: change.fromKey, value: change.fromValue)
        return HStack(spacing: 4) {
            if change.fromValue == nil {
                // Key rename: values ride along, so no value field follows.
                Text("Rename key")
                TagPill(key: change.fromKey, value: "", color: fromColor)
                Text("to")
                TagPill(key: toKey, value: "", color: toColor)
                Text("(\(count) moments)").foregroundStyle(.secondary)
            } else if toKey == change.fromKey {
                Text("Rename \(count)")
                TagPill(key: change.fromKey, value: fromValue, color: fromColor)
                Text("moments to “\(toKey):”")
            } else {
                Text("Move \(count)")
                TagPill(key: change.fromKey, value: fromValue, color: fromColor)
                Text("moments to")
                TagPill(key: toKey, value: "", color: toColor)
            }
        }
        .lineLimit(1)
    }
}

/// Staging sheet for a rename: shows the blast radius, then adds the change
/// to the Approve Changes pane rather than touching the server directly.
private struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    let key: String
    let value: String?    // nil = renaming the key itself
    var onDone: () -> Void

    @State private var newSpelling: String

    init(key: String, value: String?, onDone: @escaping () -> Void) {
        self.key = key
        self.value = value
        self.onDone = onDone
        _newSpelling = State(initialValue: value ?? key)
    }

    private var isKeyRename: Bool { value == nil }

    private var invalid: Bool {
        let trimmed = newSpelling.trimmingCharacters(in: .whitespaces)
        if isKeyRename { return normalizeKey(trimmed).isEmpty || normalizeKey(trimmed) == key }
        return trimmed == value
    }

    var body: some View {
        let review = model.review
        // Running spans are excluded — staged rewrites only touch finished ones.
        let count = review.movableMatches(key: key, value: value).count
        VStack(alignment: .leading, spacing: 12) {
            Text(isKeyRename
                 ? "Rename mark key “\(key)”"
                 : "Rename a value of “\(key)”")
                .font(.headline)

            TextField(isKeyRename ? "New key" : "New value", text: $newSpelling)
                .textFieldStyle(.roundedBorder)

            Text(isKeyRename
                 ? "Stages a rewrite of \(count) scanned \(count == 1 ? "moment" : "moments") to “\(normalizeKey(newSpelling))”, carrying the color over. Applied from the Approve Changes pane; moments outside the scanned range keep the old key."
                 : "Stages a rewrite of \(count) scanned \(count == 1 ? "moment" : "moments") carrying “\(key): \(value ?? "")”. Applied from the Approve Changes pane; moments outside the scanned range keep the old value.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { onDone() }
                Button("Stage") { stage() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(invalid || count == 0)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func stage() {
        let to = newSpelling.trimmingCharacters(in: .whitespaces)
        if let value {
            model.review.stage(StagedChange(
                fromKey: key, fromValue: value,
                toKey: key, toValue: to, spanIDs: nil))
        } else {
            model.review.stage(StagedChange(
                fromKey: key, fromValue: nil,
                toKey: to, toValue: nil, spanIDs: nil))
        }
        onDone()
    }
}
