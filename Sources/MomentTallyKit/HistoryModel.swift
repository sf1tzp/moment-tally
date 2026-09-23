import Foundation
import MomentTallyCore
import Observation

/// One breakdown row on the History tab (#291): the window's time grouped
/// by the values of one tag key, optionally split `across` a second key —
/// the "in Groups" nesting of #151, now a per-row choice rather than a
/// header mode. Keys only: tallies (tag sets) left the picker with #291, so
/// adding dimensionality is always the explicit `across` action.
package struct ChartBreakdown: Hashable, Codable, Identifiable {
    package var id: UUID
    package var key: String
    package var across: String?

    package init(id: UUID = UUID(), key: String, across: String? = nil) {
        self.id = id
        self.key = key
        self.across = across
    }
}

/// The History tab's persisted setup: the range and the breakdown rows, so
/// the charts you set up are there when you come back (#291). Stored as
/// JSON in the app's UserDefaults suite, which is already split between the
/// demo scratch suite and the real one.
package struct HistorySetup: Codable, Equatable {
    package var range: TrailingRange?
    package var rows: [ChartBreakdown]

    package init(range: TrailingRange? = nil, rows: [ChartBreakdown] = []) {
        self.range = range
        self.rows = rows
    }

    package static let defaultsKey = "historyChartSetup"
}

/// How the Calendar presents time (#286): one day at full width, the
/// 7-column week, or a month of day blocks.
package enum CalendarMode: String, Codable, CaseIterable, Identifiable {
    case day, week, month
    package var id: String { rawValue }
    package var label: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

/// The Calendar's persisted presentation (#286): mode, the time scale
/// (points per hour — the zoom), and whether the grid shows all 24 hours
/// or the working day (07:00–22:00, widened to cover any span outside it).
package struct CalendarSetup: Codable, Equatable {
    package var mode: CalendarMode = .week
    package var hourHeight: Double = 40
    package var fullDay: Bool = false
    /// Month mode's day cards carry the icon of the day's top tally set
    /// (#304) — Settings › Calendar › Top day icons turns them off when a
    /// month reads cluttered.
    package var showDayIcons: Bool = true

    package init(mode: CalendarMode = .week, hourHeight: Double = 40, fullDay: Bool = false,
                 showDayIcons: Bool = true) {
        self.mode = mode
        self.hourHeight = hourHeight
        self.fullDay = fullDay
        self.showDayIcons = showDayIcons
    }

    private enum CodingKeys: String, CodingKey { case mode, hourHeight, fullDay, showDayIcons }

    /// Keys added after the first release decode as their defaults, so a
    /// setup stored by an older build still restores.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(CalendarMode.self, forKey: .mode) ?? .week
        hourHeight = try c.decodeIfPresent(Double.self, forKey: .hourHeight) ?? 40
        fullDay = try c.decodeIfPresent(Bool.self, forKey: .fullDay) ?? false
        showDayIcons = try c.decodeIfPresent(Bool.self, forKey: .showDayIcons) ?? true
    }

    package static let defaultsKey = "calendarSetup"
    /// Zoom bounds: 20pt/h shows a whole day in a short window, 200pt/h
    /// gives quarter-hour moments a readable block.
    package static let hourHeightRange: ClosedRange<Double> = 20...200
}

/// One aggregated series slice: a label ("infra", "proj: infra") and a duration.
package struct SeriesTotal: Identifiable {
    package var id: String { label }
    package let label: String
    package let seconds: TimeInterval

    package init(label: String, seconds: TimeInterval) {
        self.label = label
        self.seconds = seconds
    }
}

/// One point of the daily chart: seconds spent on `label` during the bucket
/// starting at `day` — a calendar day for week/30-day windows, a week or a
/// month for longer ones (#163).
package struct DailyTotal: Identifiable {
    package var id: String { "\(day.timeIntervalSince1970)-\(label)" }
    package let day: Date
    package let label: String
    package let seconds: TimeInterval

    package init(day: Date, label: String, seconds: TimeInterval) {
        self.day = day
        self.label = label
        self.seconds = seconds
    }
}

/// State and behaviour for the history views (Log, Calendar, History/charts).
/// Owns the displayed week, the timespans fetched for it, the charts'
/// optional trailing range (#163), and aggregation. Sibling of `AppModel`,
/// which owns auth and the live timer.
@MainActor
@Observable
package final class HistoryModel {
    @ObservationIgnored package unowned let app: AppModel

    /// Midnight at the start of the displayed week (respects the system's
    /// first-day-of-week setting).
    package private(set) var weekStart: Date
    /// All timespans overlapping the displayed week — finished ones from the
    /// paged query plus any running timer — newest first.
    package private(set) var spans: [TimeSpan] = []
    package var isLoading = false
    package var errorMessage: String?
    /// The breakdown rows the charts tab renders, in display order. Empty
    /// until first shown, then defaulted from the data (see
    /// `defaultBreakdown`). Persisted with the range as `HistorySetup`.
    package var chartRows: [ChartBreakdown] = [] {
        didSet { persistSetup() }
    }
    /// The window the charts tab aggregates (#163): nil charts the displayed
    /// week (shared with Log and Calendar), a trailing range charts a wider
    /// window fetched separately below. Persisted with the rows.
    package var chartRange: TrailingRange? {
        didSet { persistSetup() }
    }
    /// The Calendar's presentation (#286), persisted on its own key.
    package var calendarSetup = CalendarSetup() {
        didSet { persistCalendarSetup() }
    }
    /// The day the Calendar's day mode shows (start of day). Kept inside the
    /// displayed week: stepping past the week's edge moves the week along.
    package private(set) var calendarDay: Date
    /// The first of the month the Calendar's month mode shows.
    package private(set) var calendarMonth: Date
    /// Spans fetched per calendar month, keyed by the month's first day —
    /// their own windows, like the charts' range, so the Log and Calendar
    /// week stay a week. Month mode scrolls through months (#304), so
    /// several can be resident; each loads as its section comes into view.
    package private(set) var monthSpansByMonth: [Date: [TimeSpan]] = [:]
    /// The months a fetch is in flight for; `isLoadingMonth` is their any.
    package private(set) var loadingMonths: Set<Date> = []
    package var isLoadingMonth: Bool { !loadingMonths.isEmpty }
    /// Bumped when every resident month goes stale (a mutation landed): the
    /// month sections key their load task on it so they refetch in place.
    package private(set) var monthDataVersion = 0

    /// The spans fetched for `month` (its first day), empty until loaded.
    package func monthSpans(for month: Date) -> [TimeSpan] {
        monthSpansByMonth[month] ?? []
    }
    /// Spans fetched for the charts' trailing range — kept apart from `spans`
    /// so the Log and Calendar stay on their week whatever the charts show.
    package private(set) var rangeSpans: [TimeSpan] = []
    package var isLoadingRange = false
    /// A one-shot hand-off from the Calendar tab (#130): the id of a span the
    /// Log tab should scroll to and open for editing when it next appears.
    /// The Log view clears it once consumed.
    package var pendingLogEditID: Int?
    /// The Log's structured filter (#298): the label chips and the window
    /// another surface handed it — a legend value from History, a day from
    /// the Calendar. Only the chips live here; the Log's typed text stays
    /// with its field, composed over this via `LogFilter.withText`. The Log
    /// clears it chip by chip, or whole.
    package var logFilter = LogFilter()
    /// Bumped by every `requestLog`: the Log clears its typed text on the
    /// change, so a hand-off lands on exactly what it asked for rather than
    /// on that narrowed by whatever was left in the field.
    package private(set) var logHandoffCount = 0

    /// The one door into the Log (#298): show the rows `filter` keeps and,
    /// with `editing`, scroll to that span and open its editor (#130). The
    /// filter replaces the chips outright — a hand-off lands on what it
    /// asked for, not on what was left over — and an editing hand-off with
    /// no filter lands on the plain list, its row expanded.
    ///
    /// For a running span this also claims the shared edit session —
    /// synchronously, before the caller triggers the tab switch: the Log can
    /// render its expanded row in the same pass, and an unclaimed running
    /// editor collapses itself (see `TimeSpanEditorView.runningBody`).
    package func requestLog(filter: LogFilter = LogFilter(), editing span: TimeSpan? = nil) {
        logFilter = LogFilter(labels: filter.labels, window: filter.window)
        logHandoffCount += 1
        pendingLogEditID = span?.id
        if let span, span.isRunning {
            app.claimEditingNow(span)
        }
        // The Log shows one week; a hand-off can point outside it (Label
        // Review scans months back, #69; a Calendar day in another month).
        // Move the week over so the target is actually in the loaded list —
        // the Log consumes a pending id once the reload delivers it.
        let target = span?.start ?? filter.window?.start
        if let target, !weekInterval.contains(target),
           let start = Calendar.current.dateInterval(of: .weekOfYear, for: target)?.start {
            weekStart = start
            Task { await reload() }
        }
    }

    /// The label chips a History legend series stands for (#298): the row's
    /// key with the series value, or both keys under `across` — the pair
    /// label split at its first separator, `seriesLabel`'s "(no value)"
    /// read back as the empty value. Nil for a label that isn't a series
    /// (the folded Other).
    package nonisolated static func labels(forSeries label: String,
                                           row: ChartBreakdown) -> [SpanLabel]? {
        func value(_ text: String) -> String { text == "(no value)" ? "" : text }
        guard let across = row.across else {
            return [SpanLabel(key: row.key, value: value(label))]
        }
        guard let separator = label.range(of: pairSeparator) else { return nil }
        return [SpanLabel(key: row.key, value: value(String(label[..<separator.lowerBound]))),
                SpanLabel(key: across, value: value(String(label[separator.upperBound...])))]
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
    /// The months `monthSpansByMonth` holds fresh data for — a month drops
    /// out when a mutation lands (the data stays on screen, stale, until
    /// its section refetches).
    @ObservationIgnored private var loadedMonths: Set<Date> = []
    /// Per-month fetch generations: a refetch of one month drops that
    /// month's superseded fetch, not its neighbours'.
    @ObservationIgnored private var monthGenerations: [Date: Int] = [:]

    /// True while `init` restores the stored setup, so the observers above
    /// don't write it straight back.
    @ObservationIgnored private var isRestoringSetup = false

    package init(app: AppModel) {
        self.app = app
        weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? Calendar.current.startOfDay(for: Date())
        calendarDay = Calendar.current.startOfDay(for: Date())
        calendarMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start
            ?? Calendar.current.startOfDay(for: Date())
        restoreSetup()
    }

    // MARK: Chart setup persistence (#291)

    private func restoreSetup() {
        isRestoringSetup = true
        defer { isRestoringSetup = false }
        if let data = app.defaults.data(forKey: HistorySetup.defaultsKey),
           let setup = try? JSONDecoder().decode(HistorySetup.self, from: data) {
            chartRange = setup.range
            chartRows = setup.rows
        }
        if let data = app.defaults.data(forKey: CalendarSetup.defaultsKey),
           let calendar = try? JSONDecoder().decode(CalendarSetup.self, from: data) {
            calendarSetup = calendar
        }
    }

    private func persistCalendarSetup() {
        guard !isRestoringSetup else { return }
        if let data = try? JSONEncoder().encode(calendarSetup) {
            app.defaults.set(data, forKey: CalendarSetup.defaultsKey)
        }
    }

    private func persistSetup() {
        guard !isRestoringSetup else { return }
        let setup = HistorySetup(range: chartRange, rows: chartRows)
        if let data = try? JSONEncoder().encode(setup) {
            app.defaults.set(data, forKey: HistorySetup.defaultsKey)
        }
    }

    /// Append a breakdown of the first key no row groups by yet — or, with
    /// every key taken, another row of the default key, so a second cut of
    /// the same key (say, `across` a different one) is a click away.
    package func addBreakdown() {
        let used = Set(chartRows.map(\.key))
        if let key = groupableKeys.first(where: { !used.contains($0) }) {
            chartRows.append(ChartBreakdown(key: key))
        } else if let key = defaultBreakdown()?.key {
            chartRows.append(ChartBreakdown(key: key))
        }
    }

    /// Remove a row — never the last one; the tab always shows one chart.
    package func removeBreakdown(id: ChartBreakdown.ID) {
        guard chartRows.count > 1 else { return }
        chartRows.removeAll { $0.id == id }
    }

    // MARK: Week navigation

    package var weekInterval: DateInterval {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        return DateInterval(start: weekStart, end: end)
    }

    /// The seven day-intervals of the displayed week (handles DST-shortened
    /// and -lengthened days by walking real calendar days).
    package var days: [DateInterval] {
        var result: [DateInterval] = []
        var cursor = weekStart
        for _ in 0..<7 {
            let next = Calendar.current.date(byAdding: .day, value: 1, to: cursor) ?? cursor
            result.append(DateInterval(start: cursor, end: next))
            cursor = next
        }
        return result
    }

    package var weekLabel: String {
        let last = weekInterval.end.addingTimeInterval(-1)
        let start = weekStart.formatted(.dateTime.month(.abbreviated).day())
        let end = last.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(start) – \(end)"
    }

    package var isCurrentWeek: Bool {
        weekInterval.contains(Date())
    }

    package func goToPreviousWeek() { shiftWeek(by: -1) }
    package func goToNextWeek() { shiftWeek(by: 1) }

    package func goToToday() {
        let now = Date()
        calendarDay = Calendar.current.startOfDay(for: now)
        if let month = Calendar.current.dateInterval(of: .month, for: now)?.start,
           month != calendarMonth {
            calendarMonth = month
            Task { await loadMonthIfNeeded() }
        }
        if let start = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start {
            weekStart = start
            Task { await reload() }
        }
    }

    private func shiftWeek(by weeks: Int) {
        if let start = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: weekStart) {
            weekStart = start
            // Keep the day inside the week: same weekday, new week.
            if let day = Calendar.current.date(byAdding: .weekOfYear, value: weeks, to: calendarDay) {
                calendarDay = day
            }
            Task { await reload() }
        }
    }

    // MARK: Calendar day + month navigation (#286)

    package var dayInterval: DateInterval {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: calendarDay) ?? calendarDay
        return DateInterval(start: calendarDay, end: end)
    }

    package var dayLabel: String {
        calendarDay.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }

    package var isToday: Bool { dayInterval.contains(Date()) }

    package func goToPreviousDay() { shiftDay(by: -1) }
    package func goToNextDay() { shiftDay(by: 1) }

    /// Step the day; crossing the week's edge moves the week with it, so
    /// the Log stays on the week the Calendar shows.
    private func shiftDay(by days: Int) {
        guard let day = Calendar.current.date(byAdding: .day, value: days, to: calendarDay) else { return }
        showDay(day)
    }

    /// Show one day in day mode — the week header's day tap, a month
    /// block's tap, the day stepper.
    package func showDay(_ date: Date, switchingMode: Bool = false) {
        calendarDay = Calendar.current.startOfDay(for: date)
        if switchingMode { calendarSetup.mode = .day }
        if !weekInterval.contains(calendarDay),
           let start = Calendar.current.dateInterval(of: .weekOfYear, for: calendarDay)?.start {
            weekStart = start
            Task { await reload() }
        }
    }

    package var monthInterval: DateInterval { Self.monthInterval(of: calendarMonth) }

    package static func monthInterval(of month: Date) -> DateInterval {
        let end = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month
        return DateInterval(start: month, end: end)
    }

    package var monthLabel: String {
        calendarMonth.formatted(.dateTime.month(.wide).year())
    }

    package var isCurrentMonth: Bool { monthInterval.contains(Date()) }

    package func goToPreviousMonth() { shiftMonth(by: -1) }
    package func goToNextMonth() { shiftMonth(by: 1) }

    private func shiftMonth(by months: Int) {
        guard let month = Calendar.current.date(byAdding: .month, value: months, to: calendarMonth) else { return }
        calendarMonth = month
        Task { await loadMonthIfNeeded() }
    }

    /// The month scroll (#304) reporting which month sits at the top: the
    /// header label and the stepping follow it. No fetch — the sections
    /// load themselves as they appear.
    package func setCalendarMonth(_ month: Date) {
        if month != calendarMonth { calendarMonth = month }
    }

    /// Entering month mode from a week or day: show that month.
    package func alignMonthToDisplayedDay() {
        if let month = Calendar.current.dateInterval(of: .month, for: calendarDay)?.start,
           month != calendarMonth {
            calendarMonth = month
        }
    }

    /// Fetch `month` (the calendar month by default) unless it is already
    /// resident and fresh.
    package func loadMonthIfNeeded(_ month: Date? = nil) async {
        let month = month ?? calendarMonth
        guard !loadedMonths.contains(month) else { return }
        await reloadMonth(month)
    }

    /// Page through one month, the range fetch's shape (#163): progress via
    /// `loadingMonths`, a per-month generation counter drops a superseded
    /// fetch of the same month.
    package func reloadMonth(_ month: Date? = nil) async {
        let month = month ?? calendarMonth
        guard let backend = app.api, app.isReady else { return }
        let generation = (monthGenerations[month] ?? 0) + 1
        monthGenerations[month] = generation
        loadingMonths.insert(month)
        defer { if generation == monthGenerations[month] { loadingMonths.remove(month) } }
        do {
            let interval = Self.monthInterval(of: month)
            var finished: [TimeSpan] = []
            var token: PageToken?
            for _ in 0..<500 {
                let page = try await backend.timeSpans(from: interval.start, to: interval.end, page: token)
                guard generation == monthGenerations[month] else { return }
                finished += page.timeSpans
                guard let next = page.nextPage, !page.timeSpans.isEmpty else { break }
                token = next
            }
            let running = try await backend.timers()
            guard generation == monthGenerations[month] else { return }
            var seen = Set<Int>()
            monthSpansByMonth[month] = (running + finished).filter { seen.insert($0.id).inserted }
            loadedMonths.insert(month)
            errorMessage = nil
        } catch {
            guard generation == monthGenerations[month] else { return }
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Loading

    /// Forget everything loaded — called when the active backend switches,
    /// since spans (and their ids) from one store mean nothing in the other.
    /// The next look at a history tab reloads from the new backend.
    package func reset() {
        loadGeneration += 1     // invalidates any in-flight load
        rangeGeneration += 1
        spans = []
        hasLoaded = false
        isLoading = false
        rangeSpans = []
        loadedRange = nil
        isLoadingRange = false
        for month in monthGenerations.keys { monthGenerations[month, default: 0] += 1 }
        monthSpansByMonth = [:]
        loadedMonths = []
        loadingMonths = []
        monthDataVersion += 1
        errorMessage = nil
        // The range and rows are the user's setup, not the store's data —
        // they stay (a key the new store lacks just charts empty).
        pendingLogEditID = nil  // span ids mean nothing in the new store
        logFilter = LogFilter()
    }

    package func reload() async {
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
    package func reloadIfLoaded() async {
        if hasLoaded { await reload() }
        await reloadRangeIfLoaded()
        if !loadedMonths.isEmpty {
            // Stale, not refetched here: the version bump re-runs the
            // on-screen sections' load tasks, and any other resident month
            // refetches when its section next appears.
            loadedMonths = []
            monthDataVersion += 1
        }
    }

    /// First-load hook for the tab views: fetch once, then leave navigation
    /// and mutations to trigger further loads (so switching tabs is instant).
    package func loadIfNeeded() async {
        if !hasLoaded { await reload() }
    }

    // MARK: Chart range loading (#163)

    /// Fetch the charts' trailing range unless `rangeSpans` already holds it —
    /// run from the charts tab on appearance and on every range change, so a
    /// mere tab switch doesn't re-page a year of history.
    package func loadRangeIfNeeded() async {
        guard let range = chartRange, loadedRange != range else { return }
        await reloadRange()
    }

    /// Page through the trailing range, like the Label Review's scan: the
    /// window can cover far more than a week, so progress shows via
    /// `isLoadingRange` and a generation counter drops superseded fetches.
    package func reloadRange() async {
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
    package func reloadChartWindow() async {
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
    package func update(id: Int, start: Date, end: Date?, tags: [SpanLabel], note: String) async -> Bool {
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

    package func delete(id: Int) async {
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
    package var chartInterval: DateInterval {
        guard let range = chartRange else { return weekInterval }
        let now = Date()
        let start = range == .all
            ? rangeSpans.map(\.start).min() ?? Calendar.current.startOfDay(for: now)
            : range.start(from: now)
        return DateInterval(start: min(start, now), end: now)
    }

    /// The spans the charts aggregate over — the week's, or the range fetch.
    package var chartSpans: [TimeSpan] {
        chartRange == nil ? spans : rangeSpans
    }

    /// One bar of the "per day" chart covers this much: days up to a month of
    /// them, then weeks, then months — bar counts stay in the teens rather
    /// than growing with the window.
    package var chartBucketUnit: Calendar.Component {
        switch chartRange {
        case nil, .days30: .day
        case .days90: .weekOfYear
        case .year, .all: .month
        }
    }

    /// The bar intervals of the chart window. The week keeps its exact seven
    /// `days`; trailing ranges use calendar-aligned buckets clipped to the
    /// window.
    package var chartBuckets: [DateInterval] {
        chartRange == nil ? days : Self.buckets(of: chartBucketUnit, spanning: chartInterval)
    }

    /// "May 6 – Aug 4, 2026" — the header label while a trailing range is
    /// active (the week keeps `weekLabel`).
    package var chartRangeLabel: String {
        let interval = chartInterval
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        return "\(interval.start.formatted(style)) – \(interval.end.formatted(style))"
    }

    /// The calendar-aligned `unit` buckets covering `interval`, the edge ones
    /// clipped to it: fetched spans can overlap the window's edges, and an
    /// unclipped first bucket would count time from before the range began.
    package nonisolated static func buckets(of unit: Calendar.Component,
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
    package func clippedSeconds(of span: TimeSpan, in interval: DateInterval) -> TimeInterval {
        let end = span.end ?? Date()
        let start = max(span.start, interval.start)
        let clippedEnd = min(end, interval.end)
        return max(0, clippedEnd.timeIntervalSince(start))
    }

    /// The series a span contributes to under a breakdown, or nil for none:
    /// the span's value for the row's key, or — with `across` set — the
    /// strict "outer · inner" pair of `pairLabel`.
    private func seriesLabel(for span: TimeSpan, row: ChartBreakdown) -> String? {
        if let across = row.across {
            return Self.pairLabel(tags: span.labels, outer: row.key, inner: across)
        }
        return Self.seriesLabel(tags: span.labels, key: row.key)
    }

    /// The series label for a key: the span's value for it, "(no value)"
    /// for an empty value, nil when the span lacks the key. Pure, shared
    /// with `pairLabel`.
    package nonisolated static func seriesLabel(tags: [SpanLabel], key: String) -> String? {
        tags.first(where: { $0.key == key }).map { $0.value.isEmpty ? "(no value)" : $0.value }
    }

    /// Separator inside an "outer · inner" pair label. `HistoryChartsView`
    /// splits on its first occurrence to regroup pairs by outer value.
    package nonisolated static let pairSeparator = " · "

    /// The single "outer · inner" pair series a span contributes to under an
    /// `across` breakdown, or nil to exclude it. Strict semantics — every
    /// span lands in exactly one cell or none: a span missing either key is
    /// excluded entirely, so an `across` donut's total can undershoot the
    /// plain donut of the same key.
    package nonisolated static func pairLabel(tags: [SpanLabel],
                                              outer: String, inner: String) -> String? {
        guard let outerLabel = seriesLabel(tags: tags, key: outer),
              let innerLabel = seriesLabel(tags: tags, key: inner)
        else { return nil }
        return "\(outerLabel)\(pairSeparator)\(innerLabel)"
    }

    /// Chart-window totals per series of a breakdown, largest first; ties
    /// break alphabetically, so equal series keep one order across renders
    /// (an unstable tie flipped which of two 3h 45m values folded into Other
    /// on every legend toggle).
    package func totals(for row: ChartBreakdown) -> [SeriesTotal] {
        var sums: [String: TimeInterval] = [:]
        let interval = chartInterval
        for span in chartSpans {
            let seconds = clippedSeconds(of: span, in: interval)
            guard seconds > 0, let label = seriesLabel(for: span, row: row) else { continue }
            sums[label, default: 0] += seconds
        }
        return sums.map { SeriesTotal(label: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.label < $1.label }
    }

    /// Per-bucket, per-series totals of a breakdown across the chart window,
    /// for its bar strip (buckets are days for a week, wider for trailing
    /// ranges).
    package func dailyTotals(for row: ChartBreakdown) -> [DailyTotal] {
        var result: [DailyTotal] = []
        for day in chartBuckets {
            var sums: [String: TimeInterval] = [:]
            for span in chartSpans {
                let seconds = clippedSeconds(of: span, in: day)
                guard seconds > 0, let label = seriesLabel(for: span, row: row) else { continue }
                sums[label, default: 0] += seconds
            }
            for (label, seconds) in sums {
                result.append(DailyTotal(day: day.start, label: label, seconds: seconds))
            }
        }
        return result
    }

    /// Total tracked seconds in the chart window (each span counted once, no
    /// grouping).
    package var chartTotalSeconds: TimeInterval {
        let interval = chartInterval
        return chartSpans.reduce(0) { $0 + clippedSeconds(of: $1, in: interval) }
    }

    /// Seconds tracked during one day of the week (spans clipped to the day).
    package func totalSeconds(in day: DateInterval) -> TimeInterval {
        spans.reduce(0) { $0 + clippedSeconds(of: $1, in: day) }
    }

    /// The most sensible default breakdown: the tag key used most in the
    /// chart window, falling back to the first known tag definition.
    package func defaultBreakdown() -> ChartBreakdown? {
        var counts: [String: Int] = [:]
        for span in chartSpans {
            for tag in span.labels { counts[tag.key, default: 0] += 1 }
        }
        if let best = counts.max(by: { $0.value < $1.value })?.key {
            return ChartBreakdown(key: best)
        }
        if let first = app.tagDefinitions.first?.key {
            return ChartBreakdown(key: first)
        }
        return nil
    }

    /// Tag keys offered by the row pickers: every key seen in the chart
    /// window plus every defined key, deduplicated, alphabetical.
    package var groupableKeys: [String] {
        var keys = Set(app.tagDefinitions.map(\.key))
        for span in chartSpans {
            for tag in span.labels { keys.insert(tag.key) }
        }
        return keys.sorted()
    }
}

/// "5h 12m", "42m", "38s" — compact duration for totals and log rows.
package func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(total)s"
}
