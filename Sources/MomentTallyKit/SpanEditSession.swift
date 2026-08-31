import Foundation
import MomentTallyCore
import Observation

/// The one in-flight edit of a running timespan, shared by every surface that
/// can edit it — the popover's pencil editor and the Log view's expanded
/// running row bind to the *same* drafts, so an edit made in either is the
/// edit the other shows and commits. Per-view `@State` drafts were the root
/// of #61's cross-view clobber (each surface seeded its own copy once, then
/// wrote it back wholesale, silently reverting the other's committed edits)
/// and of #70's silent draft loss (the popover closing tore the drafts down
/// with the view). Owned by `AppModel`, which is also the only writer — the
/// session holds drafts and answers "did they change", nothing more.
@MainActor
@Observable
package final class SpanEditSession {
    /// The running timespan the drafts belong to. The span itself stays in
    /// `AppModel.activeTimers` — a session never caches it, so commits always
    /// compare against and write over the freshest known state.
    package let spanID: TimeSpan.ID

    /// The popover's editor doesn't surface the start time, only the Log
    /// view's does — but the draft lives here regardless, so a commit writes
    /// start, tags, and note in one update instead of two racing ones.
    package var startDraft: Date
    package var tagDrafts: [TagRow]
    package var noteDraft: String

    package init(span: TimeSpan) {
        spanID = span.id
        startDraft = span.start
        let rows = span.labels.map { TagRow(key: $0.key, value: $0.value) }
        tagDrafts = rows.isEmpty ? [TagRow()] : rows   // an empty row, ready to type
        noteDraft = span.note
    }

    /// Whether the drafts differ from the span as currently known — the guard
    /// that keeps focus hops and redundant saves from firing writes.
    package func differs(from span: TimeSpan) -> Bool {
        tagDrafts.labels != span.labels
            || noteDraft != span.note
            || startDraft != span.start
    }
}
