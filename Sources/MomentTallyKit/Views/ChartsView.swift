import SwiftUI
import Charts

/// The History tab: a donut + totals breakdown and a daily stacked bar chart
/// for the displayed window — the shared week by default, or a trailing
/// range picked like the Mark Review's scan window (#163), with the bars
/// widening from days to weeks to months as the window grows. Instead of the
/// web UI's build-your-own dashboards, flexibility lives in the grouping
/// controls: two side-by-side donut columns, each with its own "Group by"
/// picker (any tag key, or a Tag Set — one series per member tag), so two
/// breakdowns of the same window sit next to each other. A "Count marks"
/// toggle (#109) in the header row can instead nest the first grouping
/// inside the second ("in Groups"): one full-width donut and one daily stack
/// of strict "outer · inner" pairs (#151).
package struct HistoryChartsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    package init() {}

    /// Compact width — iPhone portrait, iPad Slide Over / narrow Split View
    /// — stacks what the regular arrangement sets side by side (#125; #126
    /// builds on the same switch). The Mac window is always regular.
    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    package var body: some View {
        let history = model.history
        VStack(spacing: 0) {
            header
            Divider()

            if let error = history.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(6)
            }

            chartsBody
        }
        .task {
            await history.loadIfNeeded()
            if history.chartGrouping == nil {
                history.chartGrouping = history.defaultGrouping()
            }
        }
        // Covers both first appearance and every range change; switching
        // back to a still-loaded range is a no-op inside.
        .task(id: history.chartRange) {
            await history.loadRangeIfNeeded()
        }
    }

    // MARK: Layout

    /// The charts' own date row, in place of the shared `WeekNavigatorView`
    /// (#163): the range picker leads — Week keeps the `‹ Today ›` stepping
    /// cluster, a trailing range swaps it for the window's concrete dates.
    /// The trailing side mirrors the navigator (mode toggle, progress,
    /// refresh) so the three history tabs keep one row shape.
    private var header: some View {
        Group {
            if isCompact {
                // The one row overflows a portrait phone; the mode toggle
                // gets a line of its own.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        rangeCluster
                        Spacer()
                        refreshCluster
                    }
                    modeToggle
                }
            } else {
                HStack(spacing: 8) {
                    rangeCluster
                    Spacer()
                    modeToggle
                    refreshCluster
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var rangeCluster: some View {
        @Bindable var history = model.history
        Picker("Range", selection: $history.chartRange) {
            Text("Week").tag(TrailingRange?.none)
            ForEach(TrailingRange.allCases) { range in
                Text(range.label).tag(TrailingRange?.some(range))
            }
        }
        .fixedSize()

        if history.chartRange == nil {
            WeekControlsView()
            Text(history.weekLabel)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)   // compact header: shrink, don't wrap
        } else {
            Text(history.chartRangeLabel)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    @ViewBuilder
    private var refreshCluster: some View {
        let history = model.history
        if history.isLoading || history.isLoadingRange {
            ProgressView().controlSize(.small)
        }
        Button {
            Task { await history.reloadChartWindow() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("Refresh")
    }

    /// The mode toggle, slotted into the header row (#151):
    /// "Separately" shows two independent breakdowns side by side; "in
    /// Groups" counts the first grouping split by the second in a single
    /// donut. Meaningless with one grouping, so it's disabled (and split
    /// rendered) until a second grouping is picked.
    private var modeToggle: some View {
        @Bindable var history = model.history
        return HStack(spacing: 6) {
            // fixedSize: the navigator row resolves its Spacer by squeezing
            // flexible children, which wrapped this caption onto two lines.
            Text("Count marks")
                .foregroundStyle(.secondary)
                .fixedSize()
            Picker("Count marks", selection: $history.chartsCombined) {
                Text("Separately").tag(false)
                Text("in Groups").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .disabled(history.chartGrouping2 == nil)
    }

    private var chartsBody: some View {
        @Bindable var history = model.history
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let (outer, inner) = combinedGroupings {
                    combinedBody(outer: outer, inner: inner,
                                 outerSelection: $history.chartGrouping,
                                 innerSelection: $history.chartGrouping2)
                } else {
                    // Two columns, each a "Group by" picker over its donut. The
                    // second compares another breakdown of the same window; until
                    // one is picked (or it has no data) a placeholder ring holds
                    // its place.
                    if isCompact {
                        VStack(alignment: .leading, spacing: 16) {
                            donutColumn(selection: $history.chartGrouping, includeNone: false)
                            Divider()
                            donutColumn(selection: $history.chartGrouping2, includeNone: true)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 20) {
                            donutColumn(selection: $history.chartGrouping, includeNone: false)
                            Divider()
                            donutColumn(selection: $history.chartGrouping2, includeNone: true)
                        }
                    }
                }

                HStack {
                    Text(bucketHeaderLabel)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(perDayTotalLabel)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                dailyBody
            }
            .padding(12)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func donutColumn(selection: Binding<ChartGrouping?>,
                             includeNone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            groupingPicker("Group by", selection: selection, includeNone: includeNone)
            if let grouping = selection.wrappedValue {
                let totals = folded(model.history.totals(for: grouping))
                if totals.isEmpty {
                    placeholderDonut("No marked time")
                } else {
                    let colors = colorMap(for: totals, grouping: grouping)
                    let grand = totals.reduce(0) { $0 + $1.seconds }
                    if isCompact {
                        VStack(alignment: .leading, spacing: 12) {
                            donut(totals: totals, colors: colors, grand: grand)
                                .frame(maxWidth: .infinity)
                            breakdownList(totals: totals, colors: colors, grand: grand)
                        }
                    } else {
                        HStack(alignment: .center, spacing: 16) {
                            donut(totals: totals, colors: colors, grand: grand)
                            breakdownList(totals: totals, colors: colors, grand: grand)
                        }
                    }
                }
            } else {
                placeholderDonut("Pick a grouping to compare")
            }
        }
        // Each column owns half the window so the layout stays a two-column
        // grid even when a column is only a placeholder ring.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Stand-in ring, same size as a real donut, for a column with no
    /// grouping picked or no data.
    private func placeholderDonut(_ caption: String) -> some View {
        Circle()
            .inset(by: 15)
            .stroke(Color.secondary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 30, dash: [8, 5]))
            .frame(width: 160, height: 160)
            .overlay {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 90)
            }
    }

    /// The (outer, inner) groupings when the combined layout applies: the
    /// toggle is on and both groupings are picked. Nil renders the split
    /// layout — with no second grouping there is nothing to combine, whatever
    /// the flag says.
    private var combinedGroupings: (outer: ChartGrouping, inner: ChartGrouping)? {
        guard model.history.chartsCombined,
              let outer = model.history.chartGrouping,
              let inner = model.history.chartGrouping2 else { return nil }
        return (outer, inner)
    }

    /// "Total 25h 20m" for the chart window — except in combined mode, where
    /// the bars only chart pair-matched time, so the header echoes the
    /// donut's "matched" figure instead of contradicting it.
    private var perDayTotalLabel: String {
        if let (outer, inner) = combinedGroupings {
            let matched = model.history.combinedTotals(outer: outer, inner: inner)
                .reduce(0) { $0 + $1.seconds }
            return "Matched \(formatDuration(matched))"
        }
        return "Total \(formatDuration(model.history.chartTotalSeconds))"
    }

    /// "Per day" / "Per week" / "Per month", following the bar width the
    /// range dictates.
    private var bucketHeaderLabel: String {
        switch model.history.chartBucketUnit {
        case .weekOfYear: "Per week"
        case .month: "Per month"
        default: "Per day"
        }
    }

    /// Combined mode, full width (#151): the old caption sentence is now the
    /// header, with both grouping pickers embedded in it — "Counting time by
    /// [outer] across all [inner] values" — so the selectors and the
    /// explanation of the nesting are one thing. Below it the donut and its
    /// two-level breakdown get the whole window width instead of half.
    @ViewBuilder
    private func combinedBody(outer: ChartGrouping, inner: ChartGrouping,
                              outerSelection: Binding<ChartGrouping?>,
                              innerSelection: Binding<ChartGrouping?>) -> some View {
        // labelsHidden: the sentence provides the pickers' context, so their
        // own labels would read "Counting time by Group by [type]…"; the
        // label strings stay for accessibility.
        HStack(spacing: 6) {
            Text("Counting time by")
            groupingPicker("Group by", selection: outerSelection, includeNone: false)
                .labelsHidden()
            Text("across all")
            // Picking None here drops back to the split layout (see
            // `combinedGroupings`), same as it did from the old right column.
            groupingPicker("Across", selection: innerSelection, includeNone: true)
                .labelsHidden()
            Text("values")
        }
        let totals = folded(model.history.combinedTotals(outer: outer, inner: inner))
        if totals.isEmpty {
            // Strict pairing: only spans carrying BOTH dimensions count.
            placeholderDonut("No time marked with both groupings")
                .frame(maxWidth: .infinity)
        } else {
            let colors = paletteSlots(for: totals)
            let grand = totals.reduce(0) { $0 + $1.seconds }
            // Full width lets the pair go wider than a split column, so instead
            // of hugging the left edge (a trailing Spacer left the right half
            // empty, #151 follow-up) the donut and its legend centre as a unit,
            // with flanking Spacers giving symmetric breathing room. A bigger
            // donut than the split view's earns the extra prominence.
            if isCompact {
                VStack(alignment: .leading, spacing: 16) {
                    // Strict pairing excludes spans missing either dimension,
                    // so this total can undershoot the week's — "matched"
                    // keeps it from contradicting the footer's "tracked".
                    donut(totals: totals, colors: colors, grand: grand,
                          caption: "matched", size: 200)
                        .frame(maxWidth: .infinity)
                    combinedBreakdownList(totals: totals, colors: colors, grand: grand)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .center, spacing: 28) {
                    Spacer(minLength: 24)
                    // Strict pairing excludes spans missing either dimension,
                    // so this total can undershoot the week's — "matched"
                    // keeps it from contradicting the footer's "tracked".
                    donut(totals: totals, colors: colors, grand: grand,
                          caption: "matched", size: 200)
                    combinedBreakdownList(totals: totals, colors: colors, grand: grand)
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// The daily bars mirror the donut columns: one stack per grouping,
    /// side by side within each day. Two stacks rather than one combined —
    /// a span matching both groupings would double-count in a single stack.
    /// In combined mode that risk is gone (strict pairing lands each span in
    /// at most one pair), so the day collapses to a single stack of the same
    /// folded pair series and colors as the combined donut.
    @ViewBuilder
    private var dailyBody: some View {
        let marks = dailyMarks
        if marks.isEmpty {
            Text(model.history.chartRange == nil
                 ? "No marked time this week" : "No marked time in this range")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            dailyChart(marks, splitColumns: combinedGroupings == nil)
        }
    }

    /// One bar-segment of the daily chart, color resolved up front so the two
    /// groupings can't collide on shared labels. `column` separates the
    /// groupings' stacks (never displayed — the legend is hidden).
    private struct DailyMark: Identifiable {
        let id: String
        let day: Date
        let seconds: TimeInterval
        let color: Color
        let column: String
    }

    /// Marks for every active grouping, ordered so each stack keeps its
    /// biggest series at the baseline (same rule as before). Combined mode
    /// yields a single column of pair series instead.
    private var dailyMarks: [DailyMark] {
        if let (outer, inner) = combinedGroupings {
            let totals = folded(model.history.combinedTotals(outer: outer, inner: inner))
            guard !totals.isEmpty else { return [] }
            return marks(column: "1", totals: totals,
                         daily: model.history.combinedDailyTotals(outer: outer, inner: inner),
                         colors: paletteSlots(for: totals))
        }
        let groupings: [(String, ChartGrouping)] = [
            model.history.chartGrouping.map { ("1", $0) },
            model.history.chartGrouping2.map { ("2", $0) },
        ].compactMap { $0 }

        var result: [DailyMark] = []
        for (column, grouping) in groupings {
            let totals = folded(model.history.totals(for: grouping))
            guard !totals.isEmpty else { continue }
            result += marks(column: column, totals: totals,
                            daily: model.history.dailyTotals(for: grouping),
                            colors: colorMap(for: totals, grouping: grouping))
        }
        return result
    }

    /// Fold, rank, and color one stack's daily series into marks.
    private func marks(column: String, totals: [SeriesTotal],
                       daily: [DailyTotal], colors: [String: Color]) -> [DailyMark] {
        let rank = Dictionary(uniqueKeysWithValues:
            totals.map(\.label).enumerated().map { ($1, $0) })
        return foldedDaily(daily, keeping: Set(totals.map(\.label)))
            .sorted { (rank[$0.label] ?? .max, $0.day) < (rank[$1.label] ?? .max, $1.day) }
            .map {
                DailyMark(id: "\(column)-\($0.id)", day: $0.day,
                          seconds: $0.seconds,
                          color: colors[$0.label] ?? .gray, column: column)
            }
    }

    private func groupingPicker(_ label: String,
                                selection: Binding<ChartGrouping?>,
                                includeNone: Bool) -> some View {
        Picker(label, selection: selection) {
            if includeNone {
                Text("None").tag(ChartGrouping?.none)
            }
            Section("Mark keys") {
                ForEach(model.history.groupableKeys, id: \.self) { key in
                    Text(key).tag(ChartGrouping?.some(.key(key)))
                }
            }
            let sets = model.tagSets.filter { !$0.labels.isEmpty }
            if !sets.isEmpty {
                Section("Tallies") {
                    ForEach(sets) { set in
                        Text(set.name.isEmpty ? "Untitled" : set.name)
                            .tag(ChartGrouping?.some(.tagSet(set.id)))
                    }
                }
            }
        }
        .fixedSize()
    }

    // MARK: Charts

    private func donut(totals: [SeriesTotal], colors: [String: Color], grand: TimeInterval,
                       caption: String = "tracked", size: CGFloat = 160) -> some View {
        Chart(totals) { item in
            SectorMark(angle: .value("Time", item.seconds),
                       innerRadius: .ratio(0.62),
                       angularInset: 1.5)
                .foregroundStyle(colors[item.label] ?? .gray)
                .cornerRadius(2)
        }
        .chartLegend(.hidden)   // the breakdown list is the legend
        .frame(width: size, height: size)
        .overlay {
            VStack(spacing: 0) {
                Text(formatDuration(grand))
                    .font(.headline.monospacedDigit())
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func breakdownList(totals: [SeriesTotal], colors: [String: Color], grand: TimeInterval) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(totals) { item in
                GridRow {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(colors[item.label] ?? .gray)
                            .frame(width: 8, height: 8)
                        Text(item.label)
                            .lineLimit(1)
                    }
                    Text(formatDuration(item.seconds))
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                    Text(grand > 0
                         ? (item.seconds / grand).formatted(.percent.precision(.fractionLength(0)))
                         : "")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                }
                .font(.callout)
            }
        }
    }

    // MARK: Combined breakdown (two-level legend)

    /// One inner row of the combined breakdown: the full pair label (which
    /// keys the color map) plus the inner part shown under its heading.
    private struct CombinedRow: Identifiable {
        var id: String { pair }
        let pair: String
        let inner: String
        let seconds: TimeInterval
    }

    /// One outer section: heading label, subtotal, and its inner rows —
    /// empty for the folded "Other", which stays a single top-level row.
    private struct CombinedSection: Identifiable {
        var id: String { label }
        let label: String
        let seconds: TimeInterval
        let rows: [CombinedRow]
    }

    /// Regroup the folded pair series by outer value: sections by subtotal
    /// descending, rows descending within (already true of `totals`), and
    /// "Other" last as its own row, matching its donut position. Labels split
    /// at the first pair separator — an outer value containing " · " itself
    /// would mis-split, which we accept.
    private func combinedSections(from totals: [SeriesTotal]) -> [CombinedSection] {
        var order: [String] = []
        var rows: [String: [CombinedRow]] = [:]
        var otherSeconds: TimeInterval?
        for item in totals {
            if item.label == Self.otherLabel { otherSeconds = item.seconds; continue }
            let separator = item.label.range(of: HistoryModel.pairSeparator)
            let outer = separator.map { String(item.label[..<$0.lowerBound]) } ?? item.label
            let inner = separator.map { String(item.label[$0.upperBound...]) } ?? ""
            if rows[outer] == nil { order.append(outer) }
            rows[outer, default: []].append(
                CombinedRow(pair: item.label, inner: inner, seconds: item.seconds))
        }
        var sections = order.map { outer in
            CombinedSection(label: outer,
                            seconds: rows[outer]!.reduce(0) { $0 + $1.seconds },
                            rows: rows[outer]!)
        }
        .sorted { $0.seconds > $1.seconds }
        if let otherSeconds {
            sections.append(CombinedSection(label: Self.otherLabel,
                                            seconds: otherSeconds, rows: []))
        }
        return sections
    }

    /// Two-level legend for the combined donut: an outer heading (subtotal
    /// and share of the grand total, slightly heavier weight) over indented
    /// inner rows whose dots match the donut's pair slices.
    private func combinedBreakdownList(totals: [SeriesTotal], colors: [String: Color],
                                       grand: TimeInterval) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(combinedSections(from: totals)) { section in
                GridRow {
                    HStack(spacing: 6) {
                        if section.rows.isEmpty {
                            // The folded "Other" is itself a slice, so it
                            // keeps a dot; real headings aren't slices.
                            Circle()
                                .fill(colors[section.label] ?? .gray)
                                .frame(width: 8, height: 8)
                        }
                        Text(section.label)
                            .lineLimit(1)
                    }
                    Text(formatDuration(section.seconds))
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                    Text(grand > 0
                         ? (section.seconds / grand).formatted(.percent.precision(.fractionLength(0)))
                         : "")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                }
                .font(.callout.weight(.medium))
                ForEach(section.rows) { row in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(colors[row.pair] ?? .gray)
                                .frame(width: 8, height: 8)
                            Text(row.inner)
                                .lineLimit(1)
                        }
                        .padding(.leading, 14)
                        Text(formatDuration(row.seconds))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        Text("")    // per-pair shares would just be noise
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func dailyChart(_ marks: [DailyMark], splitColumns: Bool) -> some View {
        Chart(marks) { item in
            let bar = BarMark(x: .value("Day", item.day, unit: model.history.chartBucketUnit),
                              y: .value("Hours", item.seconds / 3600))
            if splitColumns {
                // With one grouping the single band spans the bucket; with
                // two, each bucket shows the groupings' stacks side by side.
                bar.position(by: .value("Grouping", item.column))
                    .foregroundStyle(item.color)
                    .cornerRadius(2)
            } else {
                // Combined mode: one stack of pair segments, no column split.
                bar.foregroundStyle(item.color)
                    .cornerRadius(2)
            }
        }
        // Pin the domain to the whole window, or a single bucket of data
        // would stretch its bar across the full plot width.
        .chartXScale(domain: model.history.chartInterval.start...model.history.chartInterval.end)
        .chartXAxis {
            AxisMarks(values: xAxisValues) { _ in
                AxisGridLine()
                AxisValueLabel(format: xAxisFormat,
                               centered: model.history.chartRange == nil)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                if let hours = value.as(Double.self) {
                    AxisValueLabel {
                        Text(axisLabel(hours: hours))
                    }
                }
            }
        }
        .frame(height: 200)
    }

    /// X-axis tick positions per range: the week marks every day; trailing
    /// ranges mark calendar boundaries a step above their bar unit (weeks
    /// over daily bars, months over weekly ones…) so labels stay sparse
    /// however many bars the window holds.
    private var xAxisValues: AxisMarkValues {
        switch model.history.chartRange {
        case nil: .stride(by: .day)
        case .days30: .stride(by: .weekOfYear)
        case .days90: .stride(by: .month)
        case .year: .stride(by: .month, count: 2)
        case .all: .automatic(desiredCount: 6)
        }
    }

    /// Tick label style matching `xAxisValues`: weekday initials for the
    /// week, dates or months beyond it.
    private var xAxisFormat: Date.FormatStyle {
        switch model.history.chartRange {
        case nil: .dateTime.weekday(.abbreviated)
        case .days30: .dateTime.day().month(.abbreviated)
        case .days90, .year: .dateTime.month(.abbreviated)
        case .all: .dateTime.month(.abbreviated).year()
        }
    }

    /// "2h", "45m", "1h 30m" — y-axis ticks in whichever unit reads cleanly.
    /// The chart's y values are decimal hours, which the default formatting
    /// showed as-is ("0.8h") once a small matched total shrank the scale.
    private func axisLabel(hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    // MARK: Series colors (validated palette, fixed assignment)

    /// A colorblind-validated categorical palette (light/dark variants). Series
    /// are assigned slots by alphabetical label order — stable across weeks and
    /// grouping tweaks, so a series keeps its color as data changes ("color
    /// follows the entity, not its rank").
    private var palette: [Color] {
        let hexes = colorScheme == .dark
            ? ["#3987e5", "#199e70", "#c98500", "#008300",
               "#9085e9", "#e66767", "#d55181", "#d95926"]
            : ["#2a78d6", "#1baf7a", "#eda100", "#008300",
               "#4a3aa7", "#e34948", "#e87ba4", "#eb6834"]
        return hexes.compactMap { Color(hex: $0) }
    }

    /// Palette slots by alphabetical label order (plus the gray "Other") —
    /// the base assignment for both maps below, and the whole map for the
    /// combined pair series: per-value override colors never apply to a
    /// pair, since it spans two values and neither one's color can claim it.
    private func paletteSlots(for totals: [SeriesTotal]) -> [String: Color] {
        let labels = totals.map(\.label).filter { $0 != Self.otherLabel }.sorted()
        var map: [String: Color] = [Self.otherLabel: .gray]
        for (index, label) in labels.enumerated() {
            map[label] = palette[index % palette.count]
        }
        return map
    }

    private func colorMap(for totals: [SeriesTotal], grouping: ChartGrouping) -> [String: Color] {
        var map = paletteSlots(for: totals)
        // With "color by value" on, user-picked overrides beat palette slots
        // so the charts match the tag pills elsewhere in the app.
        if model.colorTagsByValue {
            for label in totals.map(\.label) where label != Self.otherLabel {
                if let override = overrideColor(for: label, grouping: grouping) {
                    map[label] = override
                }
            }
        }
        return map
    }

    /// The user's per-value color for a series label, if one is set. Labels
    /// are values when grouping by key, "key: value" for tag-set members.
    private func overrideColor(for label: String, grouping: ChartGrouping) -> Color? {
        switch grouping {
        case .key(let key):
            return model.valueColor(key: key, value: label)
        case .tagSet(let id):
            guard let set = model.tagSets.first(where: { $0.id == id }),
                  let tag = set.labels.first(where: {
                      ($0.value.isEmpty ? $0.key : "\($0.key): \($0.value)") == label
                  }) else { return nil }
            return model.valueColor(key: tag.key, value: tag.value)
        }
    }

    // MARK: Folding (cap series count, never cycle hues)

    private static let otherLabel = "Other"

    /// Keep the top 7 series; everything else folds into a gray "Other".
    private func folded(_ totals: [SeriesTotal]) -> [SeriesTotal] {
        guard totals.count > 8 else { return totals }
        let kept = totals.prefix(7)
        let rest = totals.dropFirst(7).reduce(0) { $0 + $1.seconds }
        return Array(kept) + [SeriesTotal(label: Self.otherLabel, seconds: rest)]
    }

    private func foldedDaily(_ daily: [DailyTotal], keeping: Set<String>) -> [DailyTotal] {
        var folded: [String: DailyTotal] = [:]  // keyed by day+label
        var result: [DailyTotal] = []
        for item in daily {
            if keeping.contains(item.label) {
                result.append(item)
            } else {
                let key = "\(item.day.timeIntervalSince1970)"
                let existing = folded[key]?.seconds ?? 0
                folded[key] = DailyTotal(day: item.day, label: Self.otherLabel,
                                         seconds: existing + item.seconds)
            }
        }
        return result + folded.values.sorted { $0.day < $1.day }
    }
}
