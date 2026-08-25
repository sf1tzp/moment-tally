import Foundation
import MomentTallyCore

/// What one import run did — the Settings summary line reports these.
struct ImportSummary: Equatable {
    var spansInserted = 0
    var spansUpdated = 0
    /// How many of the imported spans were still running at the source.
    var runningSpans = 0
    var definitionsCreated = 0
    var definitionsRecolored = 0

    var spansImported: Int { spansInserted + spansUpdated }
}

/// One-shot import of a backend's full history into the local store (#30):
/// every finished *and* running timespan, plus label definitions with their
/// key colors. Tag sets and value colors never cross — they were always
/// local, whichever backend was active.
///
/// Generic over `any Backend` as the source, so the whole engine — the paged
/// walk, running-span handling, origin-id dedupe — is testable with a local
/// store on both ends; in the app the source is a `TraggoClient`.
///
/// Idempotent: spans upsert by their id at the source (`TimeSpan.id`),
/// remembered in the destination's `span_origin` table, so a re-run updates
/// what it already brought over instead of duplicating it. Two asymmetries
/// follow from "one-shot" rather than sync: spans deleted at the source since
/// a previous run are *not* deleted locally, and local edits to an imported
/// span are overwritten by a re-run (the source stays the record of truth for
/// what it exports — real bidirectionality is phase 6). The same
/// source-of-truth rule sets the color merge policy: an imported key color
/// replaces the local one, because the colors a user picked over time at the
/// source beat the auto-created defaults that usually sit locally.
struct HistoryImporter {
    let source: any Backend
    let destination: LocalBackend
    /// Namespaces the source's span ids in the origin mapping — the server
    /// URL — so histories imported from two different servers can't collide.
    let origin: String

    /// Defensive bound on the page walk, same idea as the Tag Review scan's
    /// but sized for a full history (10k pages ≈ 1M spans on traggo's cap).
    var maxPages = 10_000

    /// Runs the import. `progress` is awaited with the number of spans
    /// upserted so far, once per batch — the Settings surface shows it live.
    func run(progress: (Int) async -> Void = { _ in }) async throws -> ImportSummary {
        var summary = ImportSummary()

        // Definitions first, so imported spans never reference unknown keys.
        let definitions = try await source.labelDefinitions()
        (summary.definitionsCreated, summary.definitionsRecolored) =
            try await destination.importLabelDefinitions(definitions)

        // Running spans, imported still running (end stays nil). Before the
        // finished walk, deliberately: a span that stops mid-import turns up
        // finished in a later page and the upsert closes it; the other order
        // could miss it entirely. One that ran at the *previous* import and
        // has since finished is the same origin id — the walk closes it too.
        let running = try await source.timers()
        let runningCounts = try await destination.importSpans(running, origin: origin)
        summary.spansInserted += runningCounts.inserted
        summary.spansUpdated += runningCounts.updated
        summary.runningSpans = running.count
        await progress(summary.spansImported)

        // The full-history walk — the same stable-cursor paging the Tag
        // Review scan does, writing rows instead of aggregating cardinality.
        // Nothing predates the epoch; tomorrow bounds "now".
        let from = Date(timeIntervalSince1970: 0)
        let to = Date().addingTimeInterval(86_400)
        var token: PageToken?
        for _ in 0..<maxPages {
            let page = try await source.timeSpans(from: from, to: to, page: token)
            let counts = try await destination.importSpans(page.timeSpans, origin: origin)
            summary.spansInserted += counts.inserted
            summary.spansUpdated += counts.updated
            await progress(summary.spansImported)
            guard let next = page.nextPage, !page.timeSpans.isEmpty else { break }
            token = next
        }
        return summary
    }
}
