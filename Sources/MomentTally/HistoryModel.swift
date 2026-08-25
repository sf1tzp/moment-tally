import Foundation
import MomentTallyCore
import Observation

/// What the History (charts) tab groups time by: either every value of one tag
/// key (like the web UI's "Projects" pie for `proj`), or the member tags of a
/// saved tag set (one series per key:value pair in the set).
enum ChartGrouping: Hashable {
    case key(String)
    case tagSet(TagSet.ID)
}

/// A chart grouping resolved to plain data — the tag key, or a tag set's
/// member labels in stored order — so the aggregation decisions below can be
/// pure functions, unit-testable without a model or backend.
enum GroupingDefinition: Hashable {
    case key(String)
    case tagSetMembers([SpanLabel])
}

/// One aggregated series slice: a label ("infra", "proj: infra") and a duration.
struct SeriesTotal: Identifiable {
    var id: String { label }
    let label: String
    let seconds: TimeInterval
}

/// One point of the daily chart: seconds spent on `label` during the bucket
/// starting at `day` — a calendar day for week/30-day windows, a week or a
/// month for longer ones (#163).
struct DailyTotal: Identifiable {
    var id: String { "\(day.timeIntervalSince1970)-\(label)" }
    let day: Date
    let label: String
    let seconds: TimeInterval
}

/// State and behaviour for the history views (Log, Calendar, History/charts).
/// Owns the displayed week, the timespans fetched for it, the charts'
/// optional trailing range (#163), and aggregation. Sibling of `AppModel`,
/// which owns auth and the live timer.
@MainActor
@Observable
final class HistoryModel {
    @ObservationIgnored unowned let app: AppModel

    /// Midnight at the start of the displayed week (respects the system's
    /// first-day-of-week setting).
    private(set) var weekStart: Date
    /// All timespans overlapping the displayed week — finished ones from the
    /// paged query plus any running timer — newest first.
    private(set) var spans: [TimeSpan] = []
    var isLoading = false
    var errorMessage: String?
    /// The grouping the charts tab renders. Nil until first shown, then
    /// defaulted from the data (see `defaultGrouping`).
    var chartGrouping: ChartGrouping?
    /// Optional second grouping, rendered as a second donut beside the first
    /// for comparing two breakdowns of the same week. Nil = off.
    var chartGrouping2: ChartGrouping?
    /// When true (and a second grouping is set) the charts render one combined
    /// breakdown — the first grouping split by the second — instead of two
    /// side-by-side donuts. Session-only, like the groupings.
    var chartsCombined: Bool = false
    /// The window the charts tab aggregates (#163): nil charts the displayed
    /// week (shared with Log and Calendar), a trailing range charts a wider
    /// window fetched separately below. Session-only, like the groupings.
    var chartRange: TrailingRange?
    /// Spans fetched for the charts' trailing range — kept apart from `spans`
    /// so the Log and Calendar stay on their week whatever the charts show.
    private(set) var rangeSpans: [TimeSpan] = []
    var isLoadingRange = false
    /// A one-shot hand-off from the Calendar tab (#130): the id of a span the
    /// Log tab should scroll to and open for editing when it next appears.
    /// The Log view clears it once consumed.
    var pendingLogEditID: Int?

    /// Ask the Log tab to open this span's editor (#130). For a running span
    /// this also claims the shared edit session — synchronously, before the
    /// caller triggers the tab switch: the Log can render its expanded row in
    /// the same pass, and an unclaimed running editor collapses itself (see
    /// `TimeSpanEditorView.runningBody`).
    func requestLogEdit(of span: TimeSpan) {
        pendingLogEditID = span.id
        if span.isRunning {
            app.claimEditingNow(span)
        }
        // The Log shows one week; a hand-off can point outside it (Label
        // Review scans months back, #69). Move the week over so the span is
        // actually in the loaded list — the Log consumes the pending id once
        // the reload delivers it.
        if !weekInterval.contains(span.start),
           let start = Calendar.current.dateInterval(of: .weekOfYear, for: span.start)?.start {
            weekStart = start
            Task { await reload() }
        }
    }

    /// True once a load has completed, so mutations elsewhere in the app (e.g.
    /// stopping the timer from the popover) know a reload is worthwhile.
    @ObservationIgnored private var hasLoaded = false
    /// Invalidates in-flight loads when the range changes mid-fetch.
    @ObservationIgnored private var loadGeneration = 0
    /// The trailing range `rangeSpans` was last fetched for — nil when it has
    /// never loaded or has gone stale (a mutation landed while the charts were
    /// back on the week). Guards `loadRangeIfNeeded` from refetching on every
    /// tab visit.
    @ObservationIgnored private var loadedRange: TrailingRange?
    /// Invalidates in-flight range fetches when the range changes mid-fetch.
    @ObservationIgnored private var rangeGeneration = 0

    init(app: AppModel) {
        self.app = app
        weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? Calendar.current.startOfDay(for: Date())
    }

    // MARK: Week navigation

    var weekInterval: DateInterval {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        return DateInterval(start: weekStart, end: end)
    }

    /// The seven day-intervals of the displayed week (handles DST-shortened
    /// and -lengthened days by walking real calendar days).
    var days: [DateInterval] {
        var result: [DateInterval] = []
        var cursor = weekStart
        for _ in 0..<7 {
            let next = Calendar.current.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            result.append(DateInterval(start: cursor, end: next))
            cursor = next
        }
        return result
    }

    var weekLabel: String {
        let last = weekInterval.end.addingTimeInterval(-1)
        let start = weekStart.formatted(.dateTime.month(.abbreviated).day())
        let end = last.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(start) – \(end)"
    }

    var isCurrentWeek: Bool {
        weekInterval.contains(Date())
    }

    func goToPreviousWeek() { shiftWeek(by: -1) }
    func goToNextWeek() { shiftWeek(by: 1) }

    func goToToday() {
        if let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start {
            weekStart = start
            Task { await reload() }
        }
    }

    private func shiftWeek(by weeks: Int) {
        if let start = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: weekStart) {
            weekStart = start
            Task { await reload() }
        }
    }

    // MARK: Loading

    /// Forget everything loaded — called when the active backend switches,
    /// since spans (and their ids) from one store mean nothing in the other.
    /// The next look at a history tab reloads from the new backend.
    func reset() {
        loadGeneration += 1     // invalidates any in-flight load
        rangeGeneration += 1
        spans = []
        hasLoaded = false
        isLoading = false
        rangeSpans = []
        loadedRange = nil
        isLoadingRange = false
        chartRange = nil
        errorMessage = nil
        chartGrouping = nil     // re-derived from the new backend's data
        chartGrouping2 = nil
        chartsCombined = false
        pendingLogEditID = nil  // span ids mean nothing in the new store
    }

    func reload() async {
        guard let backend = app.api, app.isReady else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let interval = weekInterval
            var finished: [TimeSpan] = []
            var token: PageToken?
            // Page until the backend says there's no more (cap pages defensively).
            for _ in 0..<50 {
                let page = try await backend.timeSpans(from: interval.start,
                                                       to: interval.end,
                                                       page: token)
                finished += page.timeSpans
                guard let next = page.nextPage, !page.timeSpans.isEmpty else { break }
                token = next
            }
            // The paged query excludes running spans; merge those in separately.
            let running = try await backend.timers()
                .filter { $0.start < interval.end }
            guard generation == loadGeneration else { return }  // range changed mid-fetch

            var seen = Set<Int>()
            spans = (running + finished)
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.start > $1.start }
            hasLoaded = true
            errorMessage = nil
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Reload only if a history view has already fetched data — called after
    /// timer mutations elsewhere in the app so open views stay fresh.
    func reloadIfLoaded() async {
        if hasLoaded { await reload() }
        await reloadRangeIfLoaded()
    }

    /// First-load hook for the tab views: fetch once, then leave navigation
    /// and mutations to trigger further loads (so switching tabs is instant).
    func loadIfNeeded() async {
        if !hasLoaded { await reload() }
    }

    // MARK: Chart range loading (#163)

    /// Fetch the charts' trailing range unless `rangeSpans` already holds it —
    /// run from the charts tab on appearance and on every range change, so a
    /// mere tab switch doesn't re-page a year of history.
    func loadRangeIfNeeded() async {
        guard let range = chartRange, loadedRange != range else { return }
        await reloadRange()
    }

    /// Page through the trailing range, like the Label Review's scan: the
    /// window can cover far more than a week, so progress shows via
    /// `isLoadingRange` and a generation counter drops superseded fetches.
    func reloadRange() async {
        guard let range = chartRange, let backend = app.api, app.isReady else { return }
        rangeGeneration += 1
        let generation = rangeGeneration
        isLoadingRange = true
        defer { if generation == rangeGeneration { isLoadingRange = false } }
        do {
            let from = range.start
            let to = Date().addingTimeInterval(86_400)
            var finished: [TimeSpan] = []
            var token: PageToken?
            // Page until done (cap defensively: 500 pages × 100 = 50k spans).
            for _ in 0..<500 {
                let page = try await backend.timeSpans(from: from, to: to, page: token)
                guard generation == rangeGeneration else { return }
                finished += page.timeSpans
                guard let next = page.nextPage, !page.timeSpans.isEmpty else { break }
                token = next
            }
            // The paged query excludes running spans; merge those in separately.
            let running = try await backend.timers()
            guard generation == rangeGeneration else { return }

            var seen = Set<Int>()
            rangeSpans = (running + finished).filter { seen.insert($0.id).inserted }
            loadedRange = range
            errorMessage = nil
        } catch {
            guard generation == rangeGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Refresh whichever window the charts are showing — the charts header's
    /// refresh button, in either mode.
    func reloadChartWindow() async {
        if chartRange == nil {
            await reload()
        } else {
            await reloadRange()
        }
    }

    /// After a mutation: refresh a loaded trailing range, or — with the charts
    /// back on the week — mark it stale so its next use refetches instead of
    /// showing pre-mutation data.
    private func reloadRangeIfLoaded() async {
        guard loadedRange != nil else { return }
        if chartRange != nil {
            await reloadRange()
        } else {
            loadedRange = nil
        }
    }

    // MARK: Editing

    /// Update a timespan in place. Returns true on success (the editor closes).
    func update(id: Int, start: Date, end: Date?, tags: [SpanLabel], note: String) async -> Bool {
        guard let backend = app.api else { return false }
        do {
            try await app.ensureTagDefinitions(for: tags)
            _ = try await backend.updateTimeSpan(id: id, start: start, end: end,
                                                 labels: tags, note: note)
            errorMessage = nil
            await reload()
            await reloadRangeIfLoaded()
            await app.refresh()   // the edit may have touched the running timer
            app.noteSpanDataChanged()
            app.syncSoon()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(id: Int) async {
        guard let backend = app.api else { return }
        do {
            try await backend.removeTimeSpan(id: id)
            errorMessage = nil
            await reload()
            await reloadRangeIfLoaded()
            await app.refresh()
            app.noteSpanDataChanged()
            app.syncSoon()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Chart window (#163)

    /// The interval the charts aggregate: the displayed week, or the trailing
    /// range back from now. "All history" starts at the earliest fetched span
    /// — its nominal 1970 lower bound would make an unusable axis domain —
    /// and degenerates to today while nothing is fetched.
    var chartInterval: DateInterval {
        guard let range = chartRange else { return weekInterval }
        let now = Date()
        let start = range == .all
            ? rangeSpans.map(\.start).min() ?? Calendar.current.startOfDay(for: now)
            : range.start(from: now)
        return DateInterval(start: min(start, now), end: now)
    }

    /// The spans the charts aggregate over — the week's, or the range fetch.
    var chartSpans: [TimeSpan] {
        chartRange == nil ? spans : rangeSpans
    }

    /// One bar of the "per day" chart covers this much: days up to a month of
    /// them, then weeks, then months — bar counts stay in the teens rather
    /// than growing with the window.
    var chartBucketUnit: Calendar.Component {
        switch chartRange {
        case nil, .days30: .day
        case .days90: .weekOfYear
        case .year, .all: .month
        }
    }

    /// The bar intervals of the chart window. The week keeps its exact seven
    /// `days`; trailing ranges use calendar-aligned buckets clipped to the
    /// window.
    var chartBuckets: [DateInterval] {
        chartRange == nil ? days : Self.buckets(of: chartBucketUnit, spanning: chartInterval)
    }

    /// "May 6 – Aug 4, 2026" — the header label while a trailing range is
    /// active (the week keeps `weekLabel`).
    var chartRangeLabel: String {
        let interval = chartInterval
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        return "\(interval.start.formatted(style)) – \(interval.end.formatted(style))"
    }

    /// The calendar-aligned `unit` buckets covering `interval`, the edge ones
    /// clipped to it: fetched spans can overlap the window's edges, and an
    /// unclipped first bucket would count time from before the range began.
    nonisolated static func buckets(of unit: Calendar.Component,
                                    spanning interval: DateInterval,
                                    calendar: Calendar = .current) -> [DateInterval] {
        guard interval.duration > 0 else { return [] }
        var result: [DateInterval] = []
        var cursor = calendar.dateInterval(of: unit, for: interval.start)?.start
            ?? interval.start
        // Cap defensively: decades of month buckets are still only hundreds,
        // so hitting this means the dates are garbage.
        while cursor < interval.end && result.count < 1200 {
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor),
                  next > cursor else { break }
            let clipped = DateInterval(start: max(cursor, interval.start),
                                       end: min(next, interval.end))
            if clipped.duration > 0 { result.append(clipped) }
            cursor = next
        }
        return result
    }

    // MARK: Aggregation

    /// Seconds of `span` that fall inside `interval`. Running spans count up
    /// to now; spans are clipped at the interval edges so overnight entries
    /// contribute to each day they touch.
    func clippedSeconds(of span: TimeSpan, in interval: DateInterval) -> TimeInterval {
        let end = span.end ?? Date()
        let start = max(span.start, interval.start)
        let clippedEnd = min(end, interval.end)
        return max(0, clippedEnd.timeIntervalSince(start))
    }

    /// The series a span contributes to under a grouping, or [] if none.
    /// Grouping by key: the span's value for that key. Grouping by tag set:
    /// one series per member tag the span carries (a span matching several
    /// member tags counts toward each).
    private func seriesLabels(for span: TimeSpan, grouping: ChartGrouping) -> [String] {
        guard let definition = definition(of: grouping) else { return [] }
        return Self.seriesLabels(tags: span.labels, definition: definition)
    }

    /// A grouping resolved to plain data (tag-set ids looked up in the app's
    /// stored sets), or nil for a since-deleted set.
    private func definition(of grouping: ChartGrouping) -> GroupingDefinition? {
        switch grouping {
        case .key(let key):
            return .key(key)
        case .tagSet(let id):
            guard let set = app.tagSets.first(where: { $0.id == id }) else { return nil }
            return .tagSetMembers(set.labels)
        }
    }

    /// Pure core of `seriesLabels(for:grouping:)`, shared with the combined
    /// pair mapping below. Tag-set matches come back in the set's stored
    /// label order.
    nonisolated static func seriesLabels(tags: [SpanLabel],
                                         definition: GroupingDefinition) -> [String] {
        switch definition {
        case .key(let key):
            return tags.first(where: { $0.key == key }).map { [$0.value.isEmpty ? "(no value)" : $0.value] } ?? []
        case .tagSetMembers(let members):
            return members
                .filter { tags.contains($0) }
                .map { $0.value.isEmpty ? $0.key : "\($0.key): \($0.value)" }
        }
    }

    /// Chart-window totals per series, largest first.
    func totals(for grouping: ChartGrouping) -> [SeriesTotal] {
        var sums: [String: TimeInterval] = [:]
        let interval = chartInterval
        for span in chartSpans {
            let seconds = clippedSeconds(of: span, in: interval)
            guard seconds > 0 else { continue }
            for label in seriesLabels(for: span, grouping: grouping) {
                sums[label, default: 0] += seconds
            }
        }
        return sums.map { SeriesTotal(label: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    /// Per-bucket, per-series totals across the chart window, for the daily
    /// chart (buckets are days for a week, wider for trailing ranges).
    func dailyTotals(for grouping: ChartGrouping) -> [DailyTotal] {
        var result: [DailyTotal] = []
        for day in chartBuckets {
            var sums: [String: TimeInterval] = [:]
            for span in chartSpans {
                let seconds = clippedSeconds(of: span, in: day)
                guard seconds > 0 else { continue }
                for label in seriesLabels(for: span, grouping: grouping) {
                    sums[label, default: 0] += seconds
                }
            }
            for (label, seconds) in sums {
                result.append(DailyTotal(day: day.start, label: label, seconds: seconds))
            }
        }
        return result
    }

    // MARK: Combined aggregation (#109)

    /// Separator inside a combined pair label. `HistoryChartsView` splits on
    /// its first occurrence to regroup pairs by outer value.
    nonisolated static let pairSeparator = " · "

    /// The single "outer · inner" pair series a span contributes to in the
    /// combined view, or nil to exclude it. Strict semantics — every span
    /// lands in exactly one cell or none:
    /// - A span missing either dimension is excluded entirely, so the
    ///   combined donut's total can undershoot the split view's left donut
    ///   for the same week.
    /// - A span matching several members of a tag-set dimension counts only
    ///   toward the FIRST matched member in the set's stored label order —
    ///   no cross-product, sums never exceed tracked time.
    nonisolated static func pairLabel(tags: [SpanLabel],
                                      outer: GroupingDefinition,
                                      inner: GroupingDefinition) -> String? {
        guard let outerLabel = seriesLabels(tags: tags, definition: outer).first,
              let innerLabel = seriesLabels(tags: tags, definition: inner).first
        else { return nil }
        return "\(outerLabel)\(pairSeparator)\(innerLabel)"
    }

    /// The pair series a span contributes to in the combined view — [] or one
    /// element under the strict semantics, which live in `pairLabel` above.
    private func pairLabels(for span: TimeSpan,
                            outer: ChartGrouping, inner: ChartGrouping) -> [String] {
        guard let outerDefinition = definition(of: outer),
              let innerDefinition = definition(of: inner),
              let label = Self.pairLabel(tags: span.labels,
                                         outer: outerDefinition,
                                         inner: innerDefinition)
        else { return [] }
        return [label]
    }

    /// Chart-window totals of the outer grouping broken down by the inner one
    /// — one series per "outer · inner" pair, largest first.
    func combinedTotals(outer: ChartGrouping, inner: ChartGrouping) -> [SeriesTotal] {
        var sums: [String: TimeInterval] = [:]
        let interval = chartInterval
        for span in chartSpans {
            let seconds = clippedSeconds(of: span, in: interval)
            guard seconds > 0 else { continue }
            for label in pairLabels(for: span, outer: outer, inner: inner) {
                sums[label, default: 0] += seconds
            }
        }
        return sums.map { SeriesTotal(label: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    /// Per-bucket, per-pair totals across the chart window —
    /// `dailyTotals(for:)` for the combined view.
    func combinedDailyTotals(outer: ChartGrouping, inner: ChartGrouping) -> [DailyTotal] {
        var result: [DailyTotal] = []
        for day in chartBuckets {
            var sums: [String: TimeInterval] = [:]
            for span in chartSpans {
                let seconds = clippedSeconds(of: span, in: day)
                guard seconds > 0 else { continue }
                for label in pairLabels(for: span, outer: outer, inner: inner) {
                    sums[label, default: 0] += seconds
                }
            }
            for (label, seconds) in sums {
                result.append(DailyTotal(day: day.start, label: label, seconds: seconds))
            }
        }
        return result
    }

    /// Total tracked seconds in the chart window (each span counted once, no
    /// grouping).
    var chartTotalSeconds: TimeInterval {
        let interval = chartInterval
        return chartSpans.reduce(0) { $0 + clippedSeconds(of: $1, in: interval) }
    }

    /// Seconds tracked during one day of the week (spans clipped to the day).
    func totalSeconds(in day: DateInterval) -> TimeInterval {
        spans.reduce(0) { $0 + clippedSeconds(of: $1, in: day) }
    }

    /// The most sensible default chart grouping: the tag key used most in the
    /// chart window, falling back to the first known tag definition.
    func defaultGrouping() -> ChartGrouping? {
        var counts: [String: Int] = [:]
        for span in chartSpans {
            for tag in span.labels { counts[tag.key, default: 0] += 1 }
        }
        if let best = counts.max(by: { $0.value < $1.value })?.key {
            return .key(best)
        }
        if let first = app.tagDefinitions.first?.key {
            return .key(first)
        }
        return nil
    }

    /// Tag keys offered by the grouping picker: every key seen in the chart
    /// window plus every defined key, deduplicated, alphabetical.
    var groupableKeys: [String] {
        var keys = Set(app.tagDefinitions.map(\.key))
        for span in chartSpans {
            for tag in span.labels { keys.insert(tag.key) }
        }
        return keys.sorted()
    }
}

/// "5h 12m", "42m", "38s" — compact duration for totals and log rows.
func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(total)s"
}
