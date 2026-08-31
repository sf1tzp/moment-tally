#if os(iOS)
import SwiftUI
import MomentTallyCore

/// The touch editor for a running timespan (#124): the popover's in-place
/// editor as a sheet — same shared `SpanEditSession` drafts, same commit
/// funnel (`commitEditSession`), so an edit started here survives the sheet
/// and resumes anywhere. Row delete/reorder use the native list idioms the
/// popover expresses with hover grips.
package struct IOSSpanEditorSheet: View {
    @Environment(AppModel.self) private var model

    package init() {}

    package var body: some View {
        NavigationStack {
            if let session = model.editSession {
                editor(session)
            } else {
                // The session died under the sheet (a sync refresh dropping
                // the span, say); nothing to edit.
                ContentUnavailableView("Nothing to edit",
                                       systemImage: "circle.dashed")
            }
        }
    }

    private func editor(_ session: SpanEditSession) -> some View {
        @Bindable var session = session
        return Form {
            Section("Marks") {
                ForEach($session.tagDrafts) { $tag in
                    HStack(spacing: 8) {
                        PopoverTagColorPicker(key: tag.key, value: tag.value)
                        TextField("key", text: $tag.key)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(width: LabelEditorStyle.keyFieldWidth)
                            .onSubmit { commit() }
                        Text(":").foregroundStyle(.secondary)
                        TextField("value", text: $tag.value)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { commit() }
                    }
                }
                .onDelete { offsets in
                    session.tagDrafts.remove(atOffsets: offsets)
                    commit()
                }
                .onMove { from, to in
                    session.tagDrafts.move(fromOffsets: from, toOffset: to)
                    commit()
                }
                Button {
                    session.tagDrafts.append(TagRow())
                } label: {
                    Label("Add Mark", systemImage: "plus")
                }
            }
            Section("Note") {
                TextField("Add a note…", text: $session.noteDraft, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit { commit() }
            }
        }
        .navigationTitle("Edit Moment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.cancelEditing() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { Task { await model.finishEditing() } }
                    .disabled(model.isBusy)
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }

    private func commit() {
        Task { await model.commitEditSession() }
    }
}
#endif
