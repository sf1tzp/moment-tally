import Foundation
import GRDB

// MARK: - Activation

/// Demo mode (#39): the app running against a seeded, throwaway copy of its
/// data, for reproducible screenshots and a functional tour alongside Help.
/// Activated per launch — the choice is never persisted — by either:
///
///     MOMENTTALLY_DEMO=1 .build/debug/MomentTally
///     .build/debug/MomentTally --demo
///
/// Nothing a demo session does can touch real data: timespans, tag sets,
/// definitions and value colours live in `demo.sqlite` beside the real
/// database (rebuilt from scratch on every demo launch, dated relative to
/// now so "the past month" always looks current), and settings reads/writes
/// go to a scratch UserDefaults suite instead of the standard domain.
package enum DemoMode {
    package static var isActive: Bool {
        isActive(environment: ProcessInfo.processInfo.environment,
                 arguments: ProcessInfo.processInfo.arguments)
    }

    /// Split out so tests can probe the parsing without touching the process.
    /// Any non-empty value except "0" activates, so `MOMENTTALLY_DEMO=true`
    /// also works; the documented spelling is `=1`.
    package static func isActive(environment: [String: String], arguments: [String]) -> Bool {
        if let value = environment["MOMENTTALLY_DEMO"], !value.isEmpty, value != "0" {
            return true
        }
        return arguments.contains("--demo")
    }
}

// MARK: - Demo store

package extension LocalBackend {
    /// `demo.sqlite`, beside the real database — easy to find (and delete)
    /// but impossible to mistake for it.
    static func demoDatabaseURL() throws -> URL {
        try defaultDatabaseURL().deletingLastPathComponent()
            .appendingPathComponent("demo.sqlite")
    }

    /// Open the demo store, rebuilt from scratch: any previous demo database
    /// is deleted (journal siblings too, so a stale WAL can't resurrect last
    /// launch's rows), migrations run *without* the legacy-UserDefaults
    /// import — the user's real presets must not leak into the demo — and the
    /// seed is written dated relative to `now`.
    static func demo(at url: URL? = nil, now: Date = Date(),
                     calendar: Calendar = .current) throws -> LocalBackend {
        let url = try url ?? demoDatabaseURL()
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        let backend = try LocalBackend(DatabaseQueue(path: url.path),
                                       databaseURL: url, legacyDefaults: nil)
        try DemoSeed.write(to: backend, now: now, calendar: calendar)
        return backend
    }
}

// MARK: - Seed content

/// The demo dataset, renovated for the onboarding "Pro-Moves" examples
/// (#172), culled to a five-card cast for screenshot presentation (#189 —
/// the shelved set survives as a comment below), and recast for the
/// Moment Tally brand's broader audience (#27): the persona is a freelance
/// creative — photography and design work up front, a full life around it
/// — whose scheme shows all three recommended patterns:
///
/// - **Quick-marks-only sets** (Cooking, Workout, Reading): no preset
///   marks, one chip per recipe/activity/book — easy to add or remove
///   without touching history.
/// - **Value-less marks** (Client Rebrand's `deliverable:`): quick-starting
///   one opens the popover editor with the empty value focused, ready for
///   a typed deliverable name (#149, #162).
/// - **Multi-client, multi-project sets** (Client Rebrand, Wedding Shoot):
///   `client:` + `project:` presets with `type:`/`meeting:` quick marks.
///   The *spans* still carry a third engagement (Violet Café's menu
///   shoot), so History's combined view keeps real type × project,
///   type × client and meeting × client axes to group by.
///
/// Spans cover a trailing month — enough for the History range selector's
/// "Last 30 days" — with work-day clustering, overlaps, notes, evening and
/// weekend leisure spans, a running span, unlabelled ad-hoc spans, and a
/// deliberate `proj:` vs `project:` key drift for Mark Review to move
/// (`proj: menu-shoot` → `project: menu-shoot`).
///
/// Everything is deterministic given (`now`, `calendar`): past days carry
/// fixed templates chosen by weekday/weekend, today is laid out backwards
/// from `now`.
package enum DemoSeed {

    // MARK: Tag sets (Launcher cards / popover quick start)

    static let tagSets: [TagSet] = [
        // The multi-client pattern: `project:` + `client:` presets, with a
        // value-less `deliverable:` to fill in per start. Their quick
        // labels below carry the `type:`/`meeting:` axes History's combined
        // view groups by. `project:` leads so each launcher card borrows its
        // *project's* colour — client-first would paint each engagement in
        // its client's hue instead of its own.
        TagSet(name: "Client Rebrand",
               tags: [TagRow(key: "project", value: "rebrand"),
                      TagRow(key: "client", value: "acme"),
                      TagRow(key: "deliverable", value: "")],
               symbolName: "paintbrush.pointed"),
        TagSet(name: "Wedding Shoot",
               tags: [TagRow(key: "project", value: "wedding-shoot"),
                      TagRow(key: "client", value: "hartleys"),
                      ],
               symbolName: "camera"),
        // The third engagement, shelved from the Launcher for the five-card
        // cast — its spans stay in history (and carry the `proj:` drift).
        // TagSet(name: "Menu Shoot",
        //        tags: [TagRow(key: "project", value: "menu-shoot"),
        //               TagRow(key: "client", value: "violet-cafe")],
        //        symbolName: "fork.knife"),
        // Quick-marks-only sets: no presets, so the card colour comes from
        // `colorHex` (matched to the key's definition colour below).
        TagSet(name: "Cooking", symbolName: "frying.pan", colorHex: "#ee6b2a"),
        TagSet(name: "Workout", symbolName: "figure.run", colorHex: "#34c759"),
        TagSet(name: "Reading", symbolName: "book", colorHex: "#26a69a"),
    ]

    // MARK: Quick labels (popover / Launcher hover chips)

    /// Quick labels for every set, matched by name because the set ids are
    /// minted fresh on every reseed. The design engagement carries the
    /// `type:` trio (added from scratch — no `type:` is baked into any
    /// set); the photography engagements add `meeting:` chips so one hover
    /// covers desk work and appointments; the leisure sets are chips
    /// *only* — the whole set is its quick labels.
    package static func quickLabels(forSetNamed name: String) -> [TagRow]? {
        switch name {
        case "Client Rebrand":
            return [TagRow(key: "type", value: "design"),
                    TagRow(key: "type", value: "revisions"),
                    TagRow(key: "type", value: "invoicing")]
        case "Wedding Shoot", "Menu Shoot":
            return [TagRow(key: "type", value: "shoot"),
                    TagRow(key: "type", value: "editing"),
                    TagRow(key: "type", value: "retouching"),
                    TagRow(key: "meeting", value: "consult"),
                    TagRow(key: "meeting", value: "venue-visit"),
                    TagRow(key: "meeting", value: "delivery")]
        case "Cooking":
            return [TagRow(key: "recipe", value: "sourdough"),
                    TagRow(key: "recipe", value: "focaccia"),
                    TagRow(key: "recipe", value: "pad-thai")]
        case "Workout":
            return [TagRow(key: "activity", value: "bike"),
                    TagRow(key: "activity", value: "run"),
                    TagRow(key: "activity", value: "yoga")]
        case "Reading":
            return [TagRow(key: "book", value: "the-director"),
                    TagRow(key: "book", value: "crux"),
                    TagRow(key: "book", value: "the-wayfinder")]
        default:
            return nil
        }
    }

    // MARK: Colours
    //
    // The persona palette (#27/#201) — the website's launcher.ts hexes, one
    // per persona tile, spread across the demo's keys and values so every
    // surface photographs in the same spectrum the moment-tally.com persona
    // ring uses. The hero label — `project: wedding-shoot` and its spans
    // dominate the demo — carries a warm apricot anchor; the rest balance
    // warm/cool as contrast anchors instead of the old orange/red
    // PrimeTime lean.

    static let labelDefinitions: [LabelDefinition] = [
        LabelDefinition(key: "client", color: "#5856d6"),      // Freelance
        LabelDefinition(key: "project", color: "#f06292"),     // Creative Work
        // Same colour as `project` on purpose: the drifted key should look
        // like what it is — the same concept, misspelled — so the difference
        // shows up in Mark Review, not on every pill.
        LabelDefinition(key: "proj", color: "#f06292"),
        LabelDefinition(key: "deliverable", color: "#007aff"), // Side Project
        LabelDefinition(key: "type", color: "#30b0c7"),        // Language
        LabelDefinition(key: "meeting", color: "#af52de"),     // Music Practice
        LabelDefinition(key: "recipe", color: "#ff9500"),      // Cooking
        LabelDefinition(key: "activity", color: "#34c759"),    // Fitness
        LabelDefinition(key: "book", color: "#26a69a"),        // Leisure
        LabelDefinition(key: "lang", color: "#42a5f5"),        // Studying
        LabelDefinition(key: "show", color: "#d84315"),        // Streaming
    ]

    /// Per-pair overrides, one hue per value so the colour-by-value story
    /// reads at a glance — every `type:`/`meeting:` value its own slice in
    /// the History donuts, and the combined view's type × client and
    /// meeting × client pairings stay tellable-apart.
    static let valueColors: [String: String] = [
        ValueColorKey.join("project", "wedding-shoot"): "#f760f2",  // the hero apricot
        ValueColorKey.join("project", "rebrand"): "#58d8ad",
        ValueColorKey.join("project", "menu-shoot"): "#ffd60a",
        // Drift matches too — see `proj` above.
        ValueColorKey.join("proj", "menu-shoot"): "#ffd60a",
        ValueColorKey.join("client", "acme"): "#dac96e",
        ValueColorKey.join("client", "hartleys"): "#ec407a",
        ValueColorKey.join("client", "violet-cafe"): "#af52de",     // naturally
        ValueColorKey.join("deliverable", "logo-v2"): "#42a5f5",
        ValueColorKey.join("deliverable", "style-guide"): "#5856d6",
        ValueColorKey.join("deliverable", "teasers"): "#ff2d55",
        ValueColorKey.join("deliverable", "menu-board"): "#66bb6a",
        ValueColorKey.join("type", "design"): "#007aff",
        ValueColorKey.join("type", "editing"): "#00add8",
        ValueColorKey.join("type", "revisions"): "#ff9500",
        ValueColorKey.join("type", "invoicing"): "#66bb6a",
        ValueColorKey.join("type", "shoot"): "#ff2d55",
        ValueColorKey.join("type", "retouching"): "#af52de",
        ValueColorKey.join("type", "lesson"): "#34c759",
        ValueColorKey.join("meeting", "check-in"): "#ec407a",
        ValueColorKey.join("meeting", "consult"): "#30b0c7",
        ValueColorKey.join("meeting", "venue-visit"): "#66bb6a",
        ValueColorKey.join("meeting", "delivery"): "#ffd60a",
        ValueColorKey.join("recipe", "sourdough"): "#f7b060",
        ValueColorKey.join("recipe", "focaccia"): "#66bb6a",
        ValueColorKey.join("recipe", "pad-thai"): "#ff2d55",
        ValueColorKey.join("activity", "bike"): "#66bb6a",          // Gardening
        ValueColorKey.join("activity", "run"): "#ff9500",
        ValueColorKey.join("activity", "yoga"): "#af52de",
        ValueColorKey.join("book", "the-director"): "#5856d6",
        ValueColorKey.join("book", "crux"): "#007aff",
        ValueColorKey.join("book", "the-wayfinder"): "#26a69a",     // the Leisure chip
        ValueColorKey.join("lang", "spanish"): "#30b0c7",
        ValueColorKey.join("show", "ted-lasso"): "#ff9500",
    ]

    // MARK: Spans

    /// One seeded timespan; `end == nil` means running. Internal (and
    /// Hashable) so tests can compare generated seeds directly.
    struct SeedSpan: Hashable {
        let start: Date
        let end: Date?
        let labels: [SpanLabel]
        let note: String
    }

    /// One templated span within a past day, in minutes from that day's
    /// local midnight.
    private struct Draft {
        var startMinute: Int
        var durationMinutes: Int
        var labels: [SpanLabel] = []
        var note: String = ""
    }

    // Label shorthands for the templates.
    private static func engagement(_ client: String, _ project: String,
                                   _ key: String, _ value: String) -> [SpanLabel] {
        [SpanLabel(key: "client", value: client),
         SpanLabel(key: "project", value: project),
         SpanLabel(key: key, value: value)]
    }
    private static let rebrandDesign = engagement("acme", "rebrand", "type", "design")
    private static let rebrandRevisions = engagement("acme", "rebrand", "type", "revisions")
    private static let rebrandInvoicing = engagement("acme", "rebrand", "type", "invoicing")
    private static let rebrandCheckIn = engagement("acme", "rebrand", "meeting", "check-in")
    private static let weddingEditing = engagement("hartleys", "wedding-shoot", "type", "editing")
    private static let weddingConsult = engagement("hartleys", "wedding-shoot", "meeting", "consult")
    private static let weddingVenue = engagement("hartleys", "wedding-shoot", "meeting", "venue-visit")
    private static let weddingCheckIn = engagement("hartleys", "wedding-shoot", "meeting", "check-in")
    private static let menuEditing = engagement("violet-cafe", "menu-shoot", "type", "editing")
    private static let menuShooting = engagement("violet-cafe", "menu-shoot", "type", "shoot")
    private static let menuConsult = engagement("violet-cafe", "menu-shoot", "meeting", "consult")
    private static let menuDelivery = engagement("violet-cafe", "menu-shoot", "meeting", "delivery")
    // The drift pair: `proj:` where every other span says `project:` — Mark
    // Review's move fixture (`proj: menu-shoot` → `project:`).
    private static let driftEditing = [SpanLabel(key: "proj", value: "menu-shoot"),
                                       SpanLabel(key: "deliverable", value: "menu-board"),
                                       SpanLabel(key: "type", value: "editing")]
    private static let driftDesign = [SpanLabel(key: "proj", value: "menu-shoot"),
                                      SpanLabel(key: "deliverable", value: "menu-board"),
                                      SpanLabel(key: "type", value: "design")]
    private static func recipe(_ value: String) -> [SpanLabel] {
        [SpanLabel(key: "recipe", value: value)]
    }
    private static func activity(_ value: String) -> [SpanLabel] {
        [SpanLabel(key: "activity", value: value)]
    }
    private static func book(_ value: String) -> [SpanLabel] {
        [SpanLabel(key: "book", value: value)]
    }

    /// Work-day templates, cycled chronologically across the trailing
    /// month's weekdays. Five-day weeks over a four-template cycle mean each
    /// week starts one variant later than the last, so no two charted weeks
    /// look identical — and any six consecutive days contain at least four
    /// weekdays, so every per-variant fixture (the overlap in B, the key
    /// drift in C, the untagged call in D) is launch-date-proof.
    private static let weekdayTemplates: [[Draft]] = [
        // A — a heads-down design day, evening cooking.
        [
            Draft(startMinute: 570, durationMinutes: 30, labels: rebrandCheckIn,
                  note: "Round-two scope call"),
            Draft(startMinute: 600, durationMinutes: 105,
                  labels: engagement("acme", "rebrand", "deliverable", "logo-v2")
                      + [SpanLabel(key: "type", value: "design")],
                  note: "Deliverable typed straight into the quick start"),
            Draft(startMinute: 720, durationMinutes: 30, labels: rebrandInvoicing,
                  note: "Monthly invoice + expenses"),
            Draft(startMinute: 780, durationMinutes: 120, labels: weddingEditing,
                  note: "Ceremony set — first cull"),
            Draft(startMinute: 900, durationMinutes: 30,
                  labels: engagement("hartleys", "wedding-shoot", "deliverable", "teasers")
                      + [SpanLabel(key: "type", value: "editing")],
                  note: "Teaser picks out to the couple"),
            Draft(startMinute: 960, durationMinutes: 60, labels: rebrandDesign),
            Draft(startMinute: 1140, durationMinutes: 75, labels: recipe("pad-thai"),
                  note: "Weeknight pad thai"),
        ],
        // B — appointments day, with a genuine overlap: the Acme check-in
        // call landed while the album render was still being watched (the
        // multi-timer story, visible as shared columns in Calendar).
        [
            Draft(startMinute: 570, durationMinutes: 15, labels: menuConsult),
            Draft(startMinute: 600, durationMinutes: 60, labels: weddingVenue,
                  note: "Vineyard walkthrough"),
            Draft(startMinute: 660, durationMinutes: 120, labels: weddingEditing,
                  note: "Album render + culling"),
            Draft(startMinute: 735, durationMinutes: 30, labels: rebrandCheckIn,
                  note: "Check-in — render still going"),
            Draft(startMinute: 840, durationMinutes: 120, labels: menuEditing,
                  note: "Menu board comps"),
            Draft(startMinute: 990, durationMinutes: 30, labels: menuDelivery,
                  note: "Proof handoff"),
            Draft(startMinute: 1140, durationMinutes: 45, labels: activity("run")),
        ],
        // C — the drift day: `proj:` where every other span says `project:`,
        // Mark Review's move-to-another-key fixture.
        [
            Draft(startMinute: 570, durationMinutes: 15, labels: weddingConsult),
            Draft(startMinute: 585, durationMinutes: 120, labels: driftEditing,
                  note: "Colour pass on the menu set"),
            Draft(startMinute: 780, durationMinutes: 60, labels: driftDesign),
            Draft(startMinute: 870, durationMinutes: 120,
                  labels: engagement("acme", "rebrand", "deliverable", "style-guide")
                      + [SpanLabel(key: "type", value: "design")],
                  note: "Style-guide pass"),
            Draft(startMinute: 1000, durationMinutes: 20, labels: weddingCheckIn,
                  note: "Album direction notes"),
            Draft(startMinute: 1170, durationMinutes: 90, labels: book("crux")),
        ],
        // D — a lighter day with an untagged phone call (the ad-hoc story:
        // a blank-timer span left as it was captured).
        [
            Draft(startMinute: 570, durationMinutes: 15, labels: menuConsult),
            Draft(startMinute: 600, durationMinutes: 150, labels: weddingEditing,
                  note: "Album draft out for review"),
            Draft(startMinute: 810, durationMinutes: 30,
                  note: "Phone call — forgot the marks"),
            Draft(startMinute: 870, durationMinutes: 60, labels: menuShooting,
                  note: "Reshoots: two menu items"),
            Draft(startMinute: 945, durationMinutes: 45, labels: rebrandRevisions,
                  note: "Client notes, round three"),
            Draft(startMinute: 1050, durationMinutes: 45, labels: activity("yoga")),
            Draft(startMinute: 1140, durationMinutes: 30,
                  labels: [SpanLabel(key: "lang", value: "spanish")],
                  note: "Flashcards before bed"),
        ],
    ]

    /// Weekend templates — leisure-only on purpose, so the History day bars
    /// show the work-day clustering and the quick-marks-only sets (Cooking,
    /// Workout, Reading) own the weekends.
    private static let weekendTemplates: [[Draft]] = [
        [
            Draft(startMinute: 600, durationMinutes: 60, labels: activity("bike"),
                  note: "Morning loop"),
            Draft(startMinute: 780, durationMinutes: 150, labels: recipe("sourdough"),
                  note: "Bake day — stretch and folds"),
            Draft(startMinute: 990, durationMinutes: 90, labels: book("the-director")),
        ],
        [
            Draft(startMinute: 630, durationMinutes: 45, labels: activity("run")),
            Draft(startMinute: 840, durationMinutes: 90, labels: recipe("focaccia"),
                  note: "Rosemary from the balcony"),
            Draft(startMinute: 1020, durationMinutes: 60, labels: book("the-wayfinder"),
                  note: "One more chapter"),
            Draft(startMinute: 1110, durationMinutes: 75,
                  labels: [SpanLabel(key: "show", value: "ted-lasso")]),
        ],
    ]

    /// Today, laid out backwards from `now` (in minutes) so it always fits
    /// whatever the launch time is; a nil duration is a *running* span. The
    /// last powers the live menu-bar timer (#189 stopped the second runner —
    /// and the multi-timer popover story with it — for cleaner screenshots,
    /// leaving it as the 0-duration entry); the lesson span matches no
    /// saved set, so its Log row shows the save-as-set ＋; the empty entry
    /// is today's ad-hoc unlabelled span.
    private static let todayTemplate: [(minutesBeforeNow: Int, durationMinutes: Int?,
                                        labels: [SpanLabel], note: String)] = [
        (220, 75, engagement("acme", "rebrand", "deliverable", "logo-v2")
             + [SpanLabel(key: "type", value: "design")], "Logo — round-two comps"),
        (130, 20, menuConsult, ""),
        (105, 15, [], ""),
        (80, 25, [SpanLabel(key: "lang", value: "spanish"),
                  SpanLabel(key: "type", value: "lesson")], "Tutor moved the lesson up"),
        (42, 0, rebrandDesign, ""),
        (9, nil, weddingEditing, ""),
    ]

    /// The full seed for the trailing month: thirty templated past days
    /// (weekday variants cycled in chronological order, weekend days
    /// leisure-only) plus today anchored to `now`.
    static func spans(now: Date, calendar: Calendar = .current) -> [SeedSpan] {
        var result: [SeedSpan] = []
        var weekdayIndex = 0
        var weekendIndex = 0
        for offset in -30...(-1) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let dayStart = calendar.startOfDay(for: day)
            let template: [Draft]
            if calendar.isDateInWeekend(day) {
                template = weekendTemplates[weekendIndex % weekendTemplates.count]
                weekendIndex += 1
            } else {
                template = weekdayTemplates[weekdayIndex % weekdayTemplates.count]
                weekdayIndex += 1
            }
            for draft in template {
                let start = dayStart.addingTimeInterval(TimeInterval(draft.startMinute * 60))
                result.append(SeedSpan(
                    start: start,
                    end: start.addingTimeInterval(TimeInterval(draft.durationMinutes * 60)),
                    labels: draft.labels, note: draft.note))
            }
        }
        for entry in todayTemplate {
            let start = now.addingTimeInterval(TimeInterval(-entry.minutesBeforeNow * 60))
            let end = entry.durationMinutes.map {
                start.addingTimeInterval(TimeInterval($0 * 60))
            }
            result.append(SeedSpan(start: start, end: end,
                                   labels: entry.labels, note: entry.note))
        }
        return result
    }

    /// Write the whole seed into `backend`, replacing whatever is there —
    /// every surface is replace-all, so re-seeding an existing demo store
    /// yields exactly the same state as a fresh one.
    static func write(to backend: LocalBackend, now: Date = Date(),
                      calendar: Calendar = .current) throws {
        try backend.saveTagSets(tagSets)
        try backend.replaceLabelDefinitions(labelDefinitions)
        try backend.saveValueColors(valueColors)
        try backend.replaceTimeSpans(with: spans(now: now, calendar: calendar))
    }
}
