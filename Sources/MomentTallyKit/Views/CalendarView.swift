import SwiftUI
#if os(macOS)
import AppKit
#endif
import MomentTallyCore

/// The Calendar tab (#286): one component with three modes. **Week** is
/// the 7-column grid on a vertical time axis, moments as colored blocks
/// (like the web UI's calendar); **Day** gives one day the whole width, so
/// lanes and labels get room; **Month** is a grid of day blocks, each a
/// pie of that day's tally colors with its total. A time-scale zoom
/// (pinch, the −/+ buttons, ⌘−/⌘=) changes the points per hour of the
/// week and day grids, and the grid shows the working day by default —
/// 07:00–22:00, widened to cover any span outside it — so the empty night
/// doesn't eat the canvas; a 24h toggle shows everything. The zoom has a
/// floor: the visible hours always fill the grid's viewport (#303), so a
/// portrait iPad or a tall window never ends in a blank band.
///
/// Overlapping spans share the column width via lane packing; tapping a
/// block jumps to the Log tab with that span open for editing (#130 — the
/// grid is too dense for a popover); a long-press / right-click shows the
/// block's details. Spans crossing midnight render one segment per day
/// they touch. Mode, zoom and the 24h toggle persist (`CalendarSetup`).
/// The hairline between day cells — NSColor.separatorColor / UIColor.separator.
private var separatorColor: Color {
    #if os(macOS)
    Color(nsColor: .separatorColor)
    #else
    Color(uiColor: .separator)
    #endif
}

package struct CalendarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openAppSection) private var openAppSection
    /// Inside a screen-long outer scroll (#280) the grid shows its whole
    /// height and the outer scroll moves through the day; there is no
    /// viewport of its own to anchor at 08:00.
    @Environment(\.outerScroll) private var outerScroll
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    /// The hour height the current pinch started from.
    @State private var pinchBase: Double?
    /// The hour at the top of the viewport, tracked from the grid's scroll
    /// offset, so a zoom, the 24h toggle or a day ⇄ week switch can put
    /// it back where it was instead of keeping the point offset.
    @State private var topHour: Double = 8
    /// Set when a pinch ends: the hour at the top when it began.
    @State private var pinchAnchor: Double?
    /// The grid's viewport height (#303): the visible hours stretch to fill
    /// it when the zoom alone would leave the page short — a working day
    /// at 40pt/h is 600pt, and a portrait iPad has 1000 to give.
    @State private var viewportHeight: CGFloat = 0

    private let gutterWidth: CGFloat = 46

    package init() {}

    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    private var setup: CalendarSetup { model.history.calendarSetup }
    /// The points per hour that fill the viewport with the visible hours —
    /// the zoom's floor. Zero until the viewport is known (or when there is
    /// none: the outer-scroll embedding lays the grid out at its zoom).
    private var fillHourHeight: Double {
        guard viewportHeight > 0 else { return 0 }
        return Double(viewportHeight) / Double(max(1, visibleHours.count))
    }
    /// The effective scale: the zoom, or the fill floor when that's taller
    /// (#303) — so the grid always reaches the bottom of its viewport and
    /// zooming in past the fill still grows it through the scroll.
    private var hourHeight: CGFloat { CGFloat(max(setup.hourHeight, fillHourHeight)) }

    package var body: some View {
        @Bindable var history = model.history
        VStack(spacing: 0) {
            header
            Divider()

            switch setup.mode {
            case .week:
                dayHeaderRow(days: history.days, tappable: true)
                Divider()
                timeGrid(days: history.days)
            case .day:
                dayHeaderRow(days: [history.dayInterval], tappable: false)
                Divider()
                timeGrid(days: [history.dayInterval])
            case .month:
                monthGrid
            }

            if let error = history.errorMessage {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(6)
            }
        }
        .task { await history.loadIfNeeded() }
        // The month fetches on entry and on every month step; a mode
        // switch back to a still-loaded month is a no-op inside.
        .task(id: monthLoadKey) {
            if setup.mode == .month { await history.loadMonthIfNeeded() }
        }
        .onChange(of: setup.mode) { _, mode in
            if mode == .month { history.alignMonthToDisplayedDay() }
        }
    }

    private var monthLoadKey: String {
        "\(setup.mode.rawValue)-\(model.history.calendarMonth.timeIntervalSince1970)"
    }

    // MARK: Header

    /// The Calendar's own row, the History tabs' one shape (#163): the mode
    /// picker leads, then the stepping cluster and the window's label; the
    /// trailing side carries the zoom, the 24h toggle, progress and refresh.
    /// Compact widths split it in two so the label keeps its room.
    private var header: some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        modePicker
                        Spacer()
                        trailingCluster
                    }
                    HStack(spacing: 8) {
                        steppingCluster
                        windowLabel
                    }
                }
            } else {
                HStack(spacing: 8) {
                    modePicker
                    steppingCluster
                    windowLabel
                    Spacer()
                    trailingCluster
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var modePicker: some View {
        @Bindable var history = model.history
        return Picker("View", selection: $history.calendarSetup.mode) {
            ForEach(CalendarMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// `‹ Today ›`, stepping by the mode's unit.
    private var steppingCluster: some View {
        let history = model.history
        return HStack(spacing: 2) {
            Button {
                switch setup.mode {
                case .day: history.goToPreviousDay()
                case .week: history.goToPreviousWeek()
                case .month: history.goToPreviousMonth()
                }
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous")
            Button("Today") { history.goToToday() }
                .disabled(isOnToday)
            Button {
                switch setup.mode {
                case .day: history.goToNextDay()
                case .week: history.goToNextWeek()
                case .month: history.goToNextMonth()
                }
            } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next")
        }
    }

    private var isOnToday: Bool {
        switch setup.mode {
        case .day: model.history.isToday
        case .week: model.history.isCurrentWeek
        case .month: model.history.isCurrentMonth
        }
    }

    private var windowLabel: some View {
        let history = model.history
        let text = switch setup.mode {
        case .day: history.dayLabel
        case .week: history.weekLabel
        case .month: history.monthLabel
        }
        return Text(text)
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    @ViewBuilder
    private var trailingCluster: some View {
        @Bindable var history = model.history
        if setup.mode != .month {
            HStack(spacing: 2) {
                Button { zoom(by: 1 / 1.25) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)
                // Nothing to zoom out to once the grid is at its fill
                // floor: a smaller zoom would draw the same grid.
                .disabled(setup.hourHeight <= max(CalendarSetup.hourHeightRange.lowerBound,
                                                  fillHourHeight))
                .accessibilityLabel("Zoom out")
                .help("Zoom out (⌘−)")
                Button { zoom(by: 1.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(setup.hourHeight >= CalendarSetup.hourHeightRange.upperBound)
                .accessibilityLabel("Zoom in")
                .help("Zoom in (⌘=)")
            }
            Toggle(isOn: $history.calendarSetup.fullDay) {
                Text("24h")
                    .font(.caption.weight(.semibold))
            }
            .toggleStyle(.button)
            .help(setup.fullDay ? "Show the working day" : "Show all 24 hours")
        }
        if history.isLoading || history.isLoadingMonth {
            ProgressView().controlSize(.small)
        }
        Button {
            Task {
                if setup.mode == .month { await history.reloadMonth() }
                else { await history.reload() }
            }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .help("Refresh")
    }

    /// Steps from the effective scale, not the stored zoom: with the grid
    /// at its fill floor, the first zoom-in should grow it, not spend a
    /// step catching the stored value up.
    private func zoom(by factor: Double) {
        setHourHeight(Double(hourHeight) * factor)
    }

    private func setHourHeight(_ value: Double) {
        let clamped = min(max(value, CalendarSetup.hourHeightRange.lowerBound),
                          CalendarSetup.hourHeightRange.upperBound)
        model.history.calendarSetup.hourHeight = clamped
    }

    // MARK: Day headers

    /// "Tue 22 · 2h 25m" per column; in week mode a tap opens the day.
    private func dayHeaderRow(days: [DateInterval], tappable: Bool) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth, height: 1)
            ForEach(days, id: \.start) { day in
                let isToday = day.contains(Date())
                let label = VStack(spacing: 1) {
                    Text(day.start.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(.caption.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Color.accentColor : .primary)
                    Text(formatDuration(model.history.totalSeconds(in: day)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                if tappable {
                    Button {
                        model.history.showDay(day.start, switchingMode: true)
                    } label: {
                        label
                    }
                    .buttonStyle(.plain)
                    .help("Show this day")
                } else {
                    label
                }
            }
        }
    }

    // MARK: Time grid (week + day)

    private var visibleHours: Range<Int> {
        CalendarLayout.visibleHours(fullDay: setup.fullDay,
                                    days: setup.mode == .day ? [model.history.dayInterval] : model.history.days,
                                    spans: model.history.spans)
    }

    private var gridHeight: CGFloat { hourHeight * CGFloat(visibleHours.count) }

    @ViewBuilder
    private func timeGrid(days: [DateInterval]) -> some View {
        let hours = visibleHours
        let grid = HStack(alignment: .top, spacing: 0) {
            hourGutter(hours: hours)
            ForEach(days, id: \.start) { day in
                dayColumn(day, hours: hours)
            }
        }
        .frame(height: gridHeight)
        // Pinch (touch, or a trackpad on the Mac) scales the hour height
        // from where the gesture started; the buttons step it.
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchBase ?? Double(hourHeight)
                    pinchBase = base
                    setHourHeight(base * value.magnification)
                }
                .onEnded { _ in
                    if pinchBase != nil { pinchAnchor = topHour }
                    pinchBase = nil
                }
        )

        if outerScroll != nil {
            grid
        } else {
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        grid
                            .background {
                                GeometryReader { content in
                                    Color.clear.preference(
                                        key: ScrollOffsetKey.self,
                                        value: -content.frame(in: .named("calendarScroll")).minY)
                                }
                            }
                    }
                    .coordinateSpace(name: "calendarScroll")
                    // The fill floor follows the viewport: a window resize
                    // or a rotation re-stretches the grid.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        viewportHeight = height
                    }
                    .onPreferenceChange(ScrollOffsetKey.self) { offset in
                        topHour = Double(hours.lowerBound) + Double(offset + Self.labelClearance) / hourHeight
                    }
                    // Open on the working day, not the first visible hour.
                    // (scrollTo from a task is unreliable for the initial
                    // position — the tab transition resets the offset.)
                    .defaultScrollAnchor(anchor(forHour: 8, viewportHeight: viewport.size.height,
                                                hours: hours))
                    // Re-anchor after a change of scale or window: a zoom
                    // step, the end of a pinch (not every tick — that
                    // fights the gesture), the 24h toggle, a day ⇄ week
                    // switch. The target is read before the layout changes;
                    // the scroll lands after it.
                    .onChange(of: setup.hourHeight) { _, _ in
                        if pinchBase == nil { keepTopHour(proxy, topHour, viewportHeight: viewport.size.height) }
                    }
                    .onChange(of: pinchAnchor) { _, anchor in
                        if let anchor {
                            keepTopHour(proxy, anchor, viewportHeight: viewport.size.height)
                            pinchAnchor = nil
                        }
                    }
                    .onChange(of: setup.fullDay) { _, _ in keepTopHour(proxy, topHour, viewportHeight: viewport.size.height) }
                    .onChange(of: setup.mode) { _, _ in keepTopHour(proxy, topHour, viewportHeight: viewport.size.height) }
                }
            }
        }
    }

    /// Scroll so `hour` sits at the top again (to the quarter hour), once
    /// the new layout has settled — a beat later, since the scroll view
    /// lays out its new content after this update commits.
    private func keepTopHour(_ proxy: ScrollViewProxy, _ hour: Double, viewportHeight: CGFloat) {
        let target = hour
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let hours = visibleHours
            let quarter = Int(((target - Double(hours.lowerBound)) * 4).rounded())
            let clamped = min(max(quarter, 0), hours.count * 4 - 1)
            // Align the cell's top the label clearance below the viewport's
            // top: a UnitPoint anchor aligns the same fraction of both, so
            // fraction × (viewport − cell) = clearance.
            let cell = hourHeight / 4
            let fraction = Self.labelClearance / max(1, viewportHeight - cell)
            proxy.scrollTo(Self.quarterMarkerID(clamped), anchor: UnitPoint(x: 0, y: fraction))
        }
    }

    private static func quarterMarkerID(_ quarter: Int) -> String { "quarter-\(quarter)" }

    private struct ScrollOffsetKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    /// Points above an hour line the viewport's top edge sits, so the
    /// hour's label isn't clipped by the edge.
    private static let labelClearance: CGFloat = 8

    /// The UnitPoint whose aligned scroll offset puts `hour` at the top:
    /// offset = fraction × (content − viewport).
    private func anchor(forHour hour: Double, viewportHeight: CGFloat, hours: Range<Int>) -> UnitPoint {
        let scrollable = gridHeight - viewportHeight
        guard scrollable > 0 else { return .top }
        let offset = max(0, CGFloat(hour - Double(hours.lowerBound)) * hourHeight - Self.labelClearance)
        return UnitPoint(x: 0, y: min(1, offset / scrollable))
    }

    private func hourGutter(hours: Range<Int>) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            // Labels on the hour lines; the window's first hour is the top
            // edge and goes unlabelled.
            ForEach(Array(hours.dropFirst()), id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                    .padding(.top, CGFloat(hour - hours.lowerBound) * hourHeight - 6)
            }
        }
        .frame(width: gutterWidth, height: gridHeight)
        // Invisible quarter-hour cells `keepTopHour` scrolls to. A stack,
        // not padded views: padding would put every cell's layout frame at
        // the top, and scrollTo aligns the frame.
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                ForEach(0..<(hours.count * 4), id: \.self) { quarter in
                    Color.clear
                        .frame(height: hourHeight / 4)
                        .id(Self.quarterMarkerID(quarter))
                }
            }
        }
    }

    /// Vertical position of a moment within the visible hours.
    private func y(of date: Date, in day: DateInterval, hours: Range<Int>) -> CGFloat {
        let hoursIn = date.timeIntervalSince(day.start) / 3600 - Double(hours.lowerBound)
        return CGFloat(hoursIn) * hourHeight
    }

    private func dayColumn(_ day: DateInterval, hours: Range<Int>) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Hour lines + left border.
                ForEach(Array(hours), id: \.self) { hour in
                    Rectangle()
                        .fill(separatorColor.opacity(0.5))
                        .frame(height: 1)
                        .padding(.top, CGFloat(hour - hours.lowerBound) * hourHeight)
                }
                Rectangle()
                    .fill(separatorColor)
                    .frame(width: 1)

                ForEach(segments(for: day)) { segment in
                    block(segment, day: day, hours: hours, columnWidth: geo.size.width)
                }

                // The present moment, in today's column: a hairline with
                // a dot at the gutter edge.
                let now = Date()
                if day.contains(now) {
                    let lineY = y(of: now, in: day, hours: hours)
                    if lineY >= 0, lineY <= gridHeight {
                        HStack(spacing: 0) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Rectangle()
                                .fill(Color.red)
                                .frame(height: 1.5)
                        }
                        .padding(.top, lineY - 3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: gridHeight)
    }

    @ViewBuilder
    private func block(_ segment: CalendarSegment, day: DateInterval, hours: Range<Int>,
                       columnWidth: CGFloat) -> some View {
        let top = y(of: segment.interval.start, in: day, hours: hours)
        let height = max(9, CGFloat(segment.interval.duration / 3600) * hourHeight)
        let laneWidth = (columnWidth - 5) / CGFloat(segment.laneCount)
        let x = 3 + CGFloat(segment.lane) * laneWidth
        let color = blockColor(segment.span)
        let single = setup.mode == .day
        let fontSize: CGFloat = single ? 11 : 9

        Button {
            // Hand the span to the Log tab and switch over — it scrolls to
            // the row and expands it.
            model.history.requestLogEdit(of: segment.span)
            openAppSection(.log)
        } label: {
            // Labels re-flow with the zoom instead of clipping: a sliver
            // is just its color; a short block says what it is; a tall
            // one adds when, and (day mode) the note.
            VStack(alignment: .leading, spacing: 1) {
                if height >= 26 {
                    Text(segment.span.timeRangeLabel)
                        .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
                }
                if height >= 14 {
                    Text(tagText(segment.span))
                        .font(.system(size: fontSize))
                        .lineLimit(height >= 40 ? 2 : 1)
                }
                if single, height >= 52, !segment.span.note.isEmpty {
                    Text(segment.span.note)
                        .font(.system(size: fontSize))
                        .foregroundStyle(color.contrastingTextColor.opacity(0.8))
                        .lineLimit(2)
                }
            }
            .foregroundStyle(color.contrastingTextColor)
            .padding(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(segment.span.isRunning
                                  ? Color.accentColor
                                  : color.opacity(0.4),
                                  lineWidth: segment.span.isRunning ? 1.5 : 0.5)
            )
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: max(laneWidth - 1.5, 6), height: height)
        .padding(.leading, x)
        .padding(.top, top)
        .help("\(segment.span.timeRangeLabel)  \(tagText(segment.span))"
              + (segment.span.note.isEmpty ? "" : "\n\(segment.span.note)")
              + "\nClick to edit in the Log")
        // The tooltip's content on touch (long-press) — and a right-click
        // on the Mac — with the same action the tap performs.
        .contextMenu {
            Text(segment.span.timeRangeLabel)
            Text(tagText(segment.span))
            if !segment.span.note.isEmpty {
                Text(segment.span.note)
            }
            Divider()
            Button("Edit in Log") {
                model.history.requestLogEdit(of: segment.span)
                openAppSection(.log)
            }
        }
    }

    private func tagText(_ span: TimeSpan) -> String {
        span.labels
            .map { $0.value.isEmpty ? $0.key : "\($0.key):\($0.value)" }
            .joined(separator: " ")
    }

    /// Blocks take the color of their first tag (the web UI similarly
    /// derives block color from tags).
    private func blockColor(_ span: TimeSpan) -> Color {
        color(for: span.labels.first)
    }

    private func color(for label: SpanLabel?) -> Color {
        if let label {
            return model.tagColor(for: label.key, value: label.value)
        }
        return .gray
    }

    // MARK: Month grid

    /// Whole weeks of day blocks; each block a pie of the day's first-label
    /// colors with its total. Tap a block to open that day.
    private var monthGrid: some View {
        let history = model.history
        let days = CalendarLayout.monthGridDays(month: history.calendarMonth)
        let rows = days.count / 7
        let weekdays = weekdayHeaders
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdays, id: \.self) { name in
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }
            Divider()
            if outerScroll != nil {
                monthRows(days: days, rows: rows, cellHeight: 110)
            } else {
                GeometryReader { geo in
                    monthRows(days: days, rows: rows,
                              cellHeight: max(72, geo.size.height / CGFloat(rows)))
                }
            }
        }
    }

    /// The calendar's weekday names in its first-weekday order.
    private var weekdayHeaders: [String] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    private func monthRows(days: [Date], rows: Int, cellHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(days[row * 7..<(row + 1) * 7], id: \.self) { day in
                        monthCell(day)
                            .frame(maxWidth: .infinity)
                            .frame(height: cellHeight)
                    }
                }
                Divider()
            }
        }
    }

    private func monthCell(_ dayStart: Date) -> some View {
        let calendar = Calendar.current
        let history = model.history
        let end = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let day = DateInterval(start: dayStart, end: end)
        let inMonth = history.monthInterval.contains(dayStart)
        let isToday = day.contains(Date())
        let groups = CalendarLayout.dayGroups(spans: history.monthSpans, day: day)
        let total = groups.reduce(0) { $0 + $1.seconds }

        return Button {
            history.showDay(dayStart, switchingMode: true)
        } label: {
            VStack(spacing: 4) {
                Text(dayStart.formatted(.dateTime.day()))
                    .font(.caption.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.accentColor
                                     : inMonth ? Color.primary : Color.secondary.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if total > 0 {
                    dayPie(groups: groups)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(formatDuration(total))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                Rectangle().fill(separatorColor).frame(width: 1)
            }
        }
        .buttonStyle(.plain)
        .opacity(inMonth ? 1 : 0.6)
        .accessibilityLabel(dayStart.formatted(.dateTime.weekday(.wide).month().day()))
        .accessibilityValue(total > 0 ? formatDuration(total) : "nothing marked")
        .help("Show this day")
    }

    /// The day's colour distribution as a pie — one sector per first-label
    /// group, clockwise from twelve, largest first (the History donut's
    /// convention).
    private func dayPie(groups: [CalendarLayout.DayGroup]) -> some View {
        let total = groups.reduce(0) { $0 + $1.seconds }
        return Canvas { context, size in
            let radius = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var angle = Angle.degrees(-90)
            for group in groups where total > 0 {
                let sweep = Angle.degrees(360 * group.seconds / total)
                var path = Path()
                path.move(to: center)
                path.addArc(center: center, radius: radius,
                            startAngle: angle, endAngle: angle + sweep, clockwise: false)
                path.closeSubpath()
                context.fill(path, with: .color(color(for: group.label).opacity(0.9)))
                angle += sweep
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: Segment layout (lane packing)

    /// This day's slice of every span, with overlapping segments assigned
    /// side-by-side lanes: segments are grouped into clusters of transitive
    /// overlap; within a cluster each takes the first free lane, and all
    /// share the cluster's lane count so widths line up.
    private func segments(for day: DateInterval) -> [CalendarSegment] {
        let now = Date()
        let clipped: [(TimeSpan, DateInterval)] = model.history.spans
            .compactMap { span in
                let start = max(span.start, day.start)
                let end = min(span.end ?? now, day.end)
                guard end > start else { return nil }
                return (span, DateInterval(start: start, end: end))
            }
            .sorted { $0.1.start < $1.1.start }

        var result: [CalendarSegment] = []
        var cluster: [(span: TimeSpan, interval: DateInterval, lane: Int)] = []
        var laneEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func closeCluster() {
            let count = max(1, laneEnds.count)
            result += cluster.map {
                CalendarSegment(span: $0.span, interval: $0.interval,
                                lane: $0.lane, laneCount: count)
            }
            cluster = []
            laneEnds = []
        }

        for (span, interval) in clipped {
            if !cluster.isEmpty, interval.start >= clusterEnd {
                closeCluster()
            }
            let lane: Int
            if let free = laneEnds.firstIndex(where: { $0 <= interval.start }) {
                lane = free
                laneEnds[free] = interval.end
            } else {
                lane = laneEnds.count
                laneEnds.append(interval.end)
            }
            cluster.append((span, interval, lane))
            clusterEnd = max(clusterEnd, interval.end)
        }
        closeCluster()
        return result
    }
}

private struct CalendarSegment: Identifiable {
    let span: TimeSpan
    let interval: DateInterval
    let lane: Int
    let laneCount: Int
    var id: String { "\(span.id)-\(Int(interval.start.timeIntervalSince1970))" }
}
