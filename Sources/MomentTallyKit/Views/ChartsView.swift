import SwiftUI
import Charts

/// The History tab: breakdown rows over the displayed window — the shared
/// week by default, or a trailing range picked like the Mark Review's scan
/// window (#163), with the bars widening from days to weeks to months as
/// the window grows. Each row (#291) is one breakdown: a sentence of pickers
/// ("by [key] across [key]"), a donut with its totals legend, and a short
/// bar strip of the same series per bucket. One row by default; **Add
/// breakdown** appends another, and rows flow two-up once the canvas is
/// wide enough (a Mac window pulled out past its floor, an iPad landscape
/// canvas) — a second cut of the same window beside the first. Picking a key
/// `across` nests the row's grouping inside it: one donut of strict
/// "outer · inner" pairs (#151), the old header-wide "in Groups" mode made
/// per row. The setup persists with the range (`HistorySetup`).
///
/// Density follows the canvas (#292): the measured row width picks the
/// donut size, the bar strip height and how many series show before the
/// tail folds into "Other" — never past the palette's eight hues, since a
/// donut stops reading past that however big it is. The legend still
/// enumerates everything: the Other row is a disclosure listing the folded
/// values inline.
package struct HistoryChartsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    /// Width the grid gives each row — every row gets the same, so one
    /// measurement serves all. Zero until the first layout pass.
    @State private var rowWidth: CGFloat = 0
    /// Rows whose Other disclosure is open. View state, not persisted.
    @State private var expandedOther: Set<ChartBreakdown.ID> = []
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
            if history.chartRows.isEmpty, let row = history.defaultBreakdown() {
                history.chartRows = [row]
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
    /// The trailing side mirrors the navigator (progress, refresh) so the
    /// three history tabs keep one row shape.
    private var header: some View {
        HStack(spacing: 8) {
            rangeCluster
            Spacer()
            refreshCluster
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

    /// Rows flow into as many columns as fit a minimum row width: one on a
    /// phone, a floor-sized Mac window or a portrait iPad, two once the
    /// canvas passes ~1060pt. Compact widths pin a single flexible column
    /// rather than trusting the adaptive item to shrink below its minimum.
    private var rowColumns: [GridItem] {
        isCompact
            ? [GridItem(.flexible(), alignment: .topLeading)]
            : [GridItem(.adaptive(minimum: 520), spacing: 24, alignment: .topLeading)]
    }

    private var chartsBody: some View {
        @Bindable var history = model.history
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: rowColumns, alignment: .leading, spacing: 20) {
                    ForEach($history.chartRows) { $row in
                        breakdownRow($row)
                    }
                }

                Button {
                    history.addBreakdown()
                } label: {
                    Label("Add breakdown", systemImage: "plus")
                }
                .disabled(history.groupableKeys.isEmpty)
                .help("Another breakdown of the same window")
            }
            .padding(12)
            .padding(.bottom, 12)
            // Full-canvas iPad (#126): an unbounded content column strands
            // the fixed-size donuts in acres of whitespace — cap and centre
            // it instead. Phones never reach the cap; the Mac window does
            // once pulled wide (#165), and centres the same way.
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Breakdown row

    /// One breakdown: the picker sentence, then the donut and its legend
    /// (side by side, or stacked on a compact width), then the bar strip
    /// with its own "Per day … Total" caption.
    @ViewBuilder
    private func breakdownRow(_ row: Binding<ChartBreakdown>) -> some View {
        let breakdown = row.wrappedValue
        let metrics = rowMetrics
        VStack(alignment: .leading, spacing: 10) {
            rowHeader(row)
            let fold = folded(model.history.totals(for: breakdown), cap: metrics.cap)
            let totals = fold.kept
            if totals.isEmpty {
                // Strict pairing under `across`: only spans carrying BOTH
                // keys count.
                placeholderDonut(breakdown.across == nil
                                 ? "No marked time" : "No time marked with both keys",
                                 size: metrics.donut)
            } else {
                let colors = colorMap(for: totals, row: breakdown)
                let grand = totals.reduce(0) { $0 + $1.seconds }
                let expanded = Binding<Bool>(
                    get: { expandedOther.contains(breakdown.id) },
                    set: { open in
                        if open { expandedOther.insert(breakdown.id) }
                        else { expandedOther.remove(breakdown.id) }
                    })
                let pairLayout = isCompact
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
                pairLayout {
                    // Strict pairing excludes spans missing either key, so
                    // an across total can undershoot the window's — "matched"
                    // keeps it from contradicting the caption's "Total".
                    donut(totals: totals, colors: colors, grand: grand,
                          caption: breakdown.across == nil ? "tracked" : "matched",
                          size: metrics.donut)
                        .frame(maxWidth: isCompact ? .infinity : nil)
                    if breakdown.across == nil {
                        breakdownList(totals: totals, tail: fold.tail, colors: colors,
                                      grand: grand, expanded: expanded)
                    } else {
                        combinedBreakdownList(totals: totals, tail: fold.tail, colors: colors,
                                              grand: grand, expanded: expanded)
                    }
                }

                HStack {
                    Text(bucketHeaderLabel)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(stripTotalLabel(for: breakdown, matched: grand))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                dailyChart(marks(for: breakdown, totals: totals, colors: colors),
                           height: metrics.strip)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }

    // MARK: Canvas-aware metrics (#292)

    /// What a row's width buys it: donut diameter, bar strip height, and
    /// the series cap before the tail folds into Other.
    private struct RowMetrics {
        let donut: CGFloat
        let strip: CGFloat
        let cap: Int
    }

    /// Steps by the measured row width. Compact widths stack the legend
    /// under the donut, so their cap is about the column's length, not the
    /// donut's height; regular widths fit the legend beside the donut — a
    /// 160pt ring carries seven callout rows, 180 and up the full eight.
    /// Eight is the palette, and the ceiling everywhere (see the type doc).
    private var rowMetrics: RowMetrics {
        if isCompact { return RowMetrics(donut: 160, strip: 120, cap: 6) }
        switch rowWidth {
        case 700...: return RowMetrics(donut: 220, strip: 160, cap: 8)
        case 520...: return RowMetrics(donut: 180, strip: 140, cap: 8)
        default: return RowMetrics(donut: 160, strip: 120, cap: 7)
        }
    }

    /// The row's sentence of pickers — "by [key] across [key]" — with the
    /// remove button trailing. Removing is offered only while another row
    /// remains: the tab always shows one chart.
    private func rowHeader(_ row: Binding<ChartBreakdown>) -> some View {
        let history = model.history
        return HStack(spacing: 6) {
            Text("by")
                .foregroundStyle(.secondary)
            // labelsHidden: the sentence provides the pickers' context; the
            // label strings stay for accessibility.
            keyPicker("Group by", selection: row.key, excluding: row.wrappedValue.across)
                .labelsHidden()
            Text("across")
                .foregroundStyle(.secondary)
            acrossPicker("Across", selection: row.across, excluding: row.wrappedValue.key)
                .labelsHidden()
            Spacer()
            if history.chartRows.count > 1 {
                Button {
                    history.removeBreakdown(id: row.wrappedValue.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove breakdown")
                .help("Remove breakdown")
            }
        }
    }

    /// The row's grouping key. A persisted key the window no longer carries
    /// stays listed, so the picker never shows an empty selection.
    private func keyPicker(_ label: String, selection: Binding<String>,
                           excluding: String?) -> some View {
        var keys = model.history.groupableKeys.filter { $0 != excluding }
        if !keys.contains(selection.wrappedValue) {
            keys.insert(selection.wrappedValue, at: 0)
        }
        return Picker(label, selection: selection) {
            ForEach(keys, id: \.self) { key in
                Text(key).tag(key)
            }
        }
        .fixedSize()
    }

    /// The optional second key the row's grouping nests inside.
    private func acrossPicker(_ label: String, selection: Binding<String?>,
                              excluding: String) -> some View {
        var keys = model.history.groupableKeys.filter { $0 != excluding }
        if let current = selection.wrappedValue, !keys.contains(current) {
            keys.insert(current, at: 0)
        }
        return Picker(label, selection: selection) {
            Text("None").tag(String?.none)
            ForEach(keys, id: \.self) { key in
                Text(key).tag(String?.some(key))
            }
        }
        .fixedSize()
    }

    /// Stand-in ring, same size as a real donut, for a row with no data.
    private func placeholderDonut(_ caption: String, size: CGFloat) -> some View {
        Circle()
            .inset(by: 15)
            .stroke(Color.secondary.opacity(0.15),
                    style: StrokeStyle(lineWidth: 30, dash: [8, 5]))
            .frame(width: size, height: size)
            .overlay {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 90)
            }
    }

    /// "Total 25h 20m" for the chart window — except under `across`, where
    /// the bars only chart pair-matched time, so the caption echoes the
    /// donut's "matched" figure instead of contradicting it.
    private func stripTotalLabel(for row: ChartBreakdown, matched: TimeInterval) -> String {
        row.across == nil
            ? "Total \(formatDuration(model.history.chartTotalSeconds))"
            : "Matched \(formatDuration(matched))"
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

    // MARK: Charts

    private func donut(totals: [SeriesTotal], colors: [String: Color], grand: TimeInterval,
                       caption: String, size: CGFloat) -> some View {
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

    /// The donut's legend: one row per kept series, and — when the tail
    /// folded — an Other row that discloses the folded values inline, so
    /// every value is enumerable without changing the chart.
    private func breakdownList(totals: [SeriesTotal], tail: [SeriesTotal],
                               colors: [String: Color], grand: TimeInterval,
                               expanded: Binding<Bool>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(totals) { item in
                if item.label == Self.otherLabel {
                    otherRow(seconds: item.seconds, count: tail.count, grand: grand,
                             expanded: expanded, font: .callout)
                    if expanded.wrappedValue {
                        tailRows(tail, grand: grand)
                    }
                } else {
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
                        shareText(item.seconds, of: grand)
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// "11%" — a series' share of the donut, blank for an empty donut.
    private func shareText(_ seconds: TimeInterval, of grand: TimeInterval) -> some View {
        Text(grand > 0
             ? (seconds / grand).formatted(.percent.precision(.fractionLength(0)))
             : "")
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .gridColumnAlignment(.trailing)
    }

    /// The Other row of either legend: a disclosure with the folded count,
    /// the gray dot of its slice, and the tail's subtotal and share.
    private func otherRow(seconds: TimeInterval, count: Int, grand: TimeInterval,
                          expanded: Binding<Bool>, font: Font) -> some View {
        GridRow {
            Button {
                withAnimation(.snappy) { expanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("\(Self.otherLabel) (\(count))")
                        .lineLimit(1)
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Other, \(count) values")
            .accessibilityValue(expanded.wrappedValue ? "expanded" : "collapsed")
            .help(expanded.wrappedValue ? "Hide the folded values" : "Show the folded values")
            Text(formatDuration(seconds))
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
            shareText(seconds, of: grand)
        }
        .font(font)
    }

    /// The folded values under an open Other row: indented, a hollow dot in
    /// place of a slice color (they share Other's gray slice), each with its
    /// own duration and share of the donut.
    private func tailRows(_ tail: [SeriesTotal], grand: TimeInterval) -> some View {
        ForEach(tail) { item in
            GridRow {
                HStack(spacing: 6) {
                    Circle()
                        .strokeBorder(Color.gray, lineWidth: 1)
                        .frame(width: 8, height: 8)
                    Text(item.label)
                        .lineLimit(1)
                }
                .padding(.leading, 14)
                Text(formatDuration(item.seconds))
                    .monospacedDigit()
                    .gridColumnAlignment(.trailing)
                shareText(item.seconds, of: grand)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
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

    /// Two-level legend for an `across` donut: an outer heading (subtotal
    /// and share of the grand total, slightly heavier weight) over indented
    /// inner rows whose dots match the donut's pair slices.
    private func combinedBreakdownList(totals: [SeriesTotal], tail: [SeriesTotal],
                                       colors: [String: Color], grand: TimeInterval,
                                       expanded: Binding<Bool>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
            ForEach(combinedSections(from: totals)) { section in
                if section.rows.isEmpty {
                    // The folded "Other" is itself a slice (so it keeps a
                    // dot; real headings aren't slices) and discloses the
                    // folded pairs by their full "outer · inner" label.
                    otherRow(seconds: section.seconds, count: tail.count, grand: grand,
                             expanded: expanded, font: .callout.weight(.medium))
                    if expanded.wrappedValue {
                        tailRows(tail, grand: grand)
                    }
                } else {
                    GridRow {
                        Text(section.label)
                            .lineLimit(1)
                        Text(formatDuration(section.seconds))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                        shareText(section.seconds, of: grand)
                    }
                    .font(.callout.weight(.medium))
                }
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

    // MARK: Bar strip

    /// One bar-segment of a row's strip, color resolved up front from the
    /// row's own map (so two rows sharing a label can't collide).
    private struct DailyMark: Identifiable {
        let id: String
        let day: Date
        let seconds: TimeInterval
        let color: Color
    }

    /// Fold, rank, and color one row's daily series into marks, ordered so
    /// the stack keeps its biggest series at the baseline.
    private func marks(for row: ChartBreakdown, totals: [SeriesTotal],
                       colors: [String: Color]) -> [DailyMark] {
        let rank = Dictionary(uniqueKeysWithValues:
            totals.map(\.label).enumerated().map { ($1, $0) })
        return foldedDaily(model.history.dailyTotals(for: row), keeping: Set(totals.map(\.label)))
            .sorted { (rank[$0.label] ?? .max, $0.day) < (rank[$1.label] ?? .max, $1.day) }
            .map {
                DailyMark(id: $0.id, day: $0.day, seconds: $0.seconds,
                          color: colors[$0.label] ?? .gray)
            }
    }

    /// The row's stacked bars — short, a volume strip under the donut rather
    /// than a chart competing with it. Every row has its own, so a second
    /// breakdown never interleaves its stacks with the first's.
    private func dailyChart(_ marks: [DailyMark], height: CGFloat) -> some View {
        Chart(marks) { item in
            BarMark(x: .value("Day", item.day, unit: model.history.chartBucketUnit),
                    y: .value("Hours", item.seconds / 3600))
                .foregroundStyle(item.color)
                .cornerRadius(2)
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
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                if let hours = value.as(Double.self) {
                    AxisValueLabel {
                        Text(axisLabel(hours: hours))
                    }
                }
            }
        }
        .frame(height: height)
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
    /// the base assignment, and the whole map for an `across` row's pair
    /// series: per-value override colors never apply to a pair, since it
    /// spans two values and neither one's color can claim it.
    private func paletteSlots(for totals: [SeriesTotal]) -> [String: Color] {
        let labels = totals.map(\.label).filter { $0 != Self.otherLabel }.sorted()
        var map: [String: Color] = [Self.otherLabel: .gray]
        for (index, label) in labels.enumerated() {
            map[label] = palette[index % palette.count]
        }
        return map
    }

    private func colorMap(for totals: [SeriesTotal], row: ChartBreakdown) -> [String: Color] {
        var map = paletteSlots(for: totals)
        // With "color by value" on, user-picked overrides beat palette slots
        // so the charts match the tag pills elsewhere in the app.
        guard row.across == nil, model.colorTagsByValue else { return map }
        for label in totals.map(\.label) where label != Self.otherLabel {
            if let override = model.valueColor(key: row.key, value: label) {
                map[label] = override
            }
        }
        return map
    }

    // MARK: Folding (cap series count, never cycle hues)

    private static let otherLabel = "Other"

    /// A row's series after folding: `kept` is what the donut and strip
    /// chart (ending in the gray Other when anything folded), `tail` the
    /// folded values themselves, for the legend's disclosure.
    private struct Folded {
        let kept: [SeriesTotal]
        let tail: [SeriesTotal]
    }

    /// Up to `cap` series chart as they are; past that the top `cap - 1`
    /// stay and the rest fold into Other — so a row never shows more than
    /// `cap` slices, Other included.
    private func folded(_ totals: [SeriesTotal], cap: Int) -> Folded {
        guard totals.count > cap else { return Folded(kept: totals, tail: []) }
        let kept = Array(totals.prefix(cap - 1))
        let tail = Array(totals.dropFirst(cap - 1))
        let rest = tail.reduce(0) { $0 + $1.seconds }
        return Folded(kept: kept + [SeriesTotal(label: Self.otherLabel, seconds: rest)],
                      tail: tail)
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
