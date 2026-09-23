import SwiftUI
#if os(macOS)
import AppKit
#endif
import MomentTallyCore

/// The Calendar tab (#286): one component with three modes. **Week** is
/// the 7-column grid on a vertical time axis, moments as colored blocks
/// (like the web UI's calendar); **Day** gives one day the whole width, so
/// lanes and labels get room; **Month** is a vertical scroll of months,
/// each a grid of day cards filled with that day's tally colors (a pie
/// clipped to the card) with its total and the top set's icon (#304).
/// A time-scale zoom
/// (pinch, the −/+ buttons, ⌘−/⌘=) changes the points per hour of the
/// week and day grids, and the grid shows the working day by default —
/// 07:00–22:00, widened to cover any span outside it — so the empty night
/// doesn't eat the canvas; a 24h toggle shows everything. The zoom has a
/// floor: the visible hours always fill the grid's viewport (#303), so a
/// portrait iPad or a tall window never ends in a blank band.
///
/// Blocks carry the tally set's tile and the labels as chips on a glass
/// surface over a wash of the day's colours (#302). Overlapping spans
/// share the column width via lane packing; tapping a
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
    /// Month mode (#304): the section under the top of the month scroll,
    /// and the ends of the range of months on screen once the scroll or
    /// the stepping widened it.
    @State private var scrolledMonth: Date?
    @State private var monthRangeFirst: Date?
    @State private var monthRangeLast: Date?
    /// Each on-screen month section's top, in the month scroll's space.
    @State private var monthTops: [Date: CGFloat] = [:]
    /// False until the initial scroll to the calendar month has landed.
    @State private var monthScrollSettled = false

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
                monthScroll
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
        .onChange(of: setup.mode) { _, mode in
            if mode == .month { history.alignMonthToDisplayedDay() }
        }
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
                columnWash(day)
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

                glassContainer {
                    ZStack(alignment: .topLeading) {
                        ForEach(segments(for: day)) { segment in
                            block(segment, day: day, hours: hours, columnWidth: geo.size.width)
                        }
                    }
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

    /// A block reads as the object the Launcher shows (#302): the matched
    /// tally set's tile (`LauncherTileIcon`) — or a placeholder tile in the
    /// first label's colour when no set claims the span — beside the time,
    /// then the labels as chips (`TagPill`) where the block is wide and
    /// tall enough, plain text otherwise, and (day mode) the note. The
    /// surface is liquid glass tinted with the block colour on OS 26,
    /// the flat fill before it. Everything re-flows with the zoom instead
    /// of clipping: a sliver is just its colour.
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
        let set = model.tagSet(for: segment.span)
        let tileSize: CGFloat = single ? 22 : 16
        let showsTile = height >= tileSize + 6 && laneWidth >= 64
        let showsChips = height >= 44 && laneWidth >= (single ? 120 : 108)
        let ink = color.contrastingTextColor

        Button {
            // Hand the span to the Log tab and switch over — it scrolls to
            // the row and expands it.
            model.history.requestLogEdit(of: segment.span)
            openAppSection(.log)
        } label: {
            HStack(alignment: .top, spacing: 5) {
                if showsTile {
                    blockTile(set: set, color: color, size: tileSize)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if height >= 26 {
                        Text(segment.span.timeRangeLabel)
                            .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
                    }
                    if showsChips {
                        // Chips only when the row of them fits — a squeezed
                        // chip truncates to nothing — else the text.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 3) {
                                ForEach(segment.span.labels, id: \.self) { label in
                                    TagPill(key: label.key, value: label.value,
                                            color: model.tagColor(for: label.key, value: label.value))
                                }
                            }
                            Text(tagText(segment.span))
                                .font(.system(size: fontSize))
                                .lineLimit(2)
                        }
                    } else if height >= 14 {
                        Text(tagText(segment.span))
                            .font(.system(size: fontSize))
                            .lineLimit(height >= 40 ? 2 : 1)
                    }
                    if single, height >= (showsChips ? 68 : 52), !segment.span.note.isEmpty {
                        Text(segment.span.note)
                            .font(.system(size: fontSize))
                            .foregroundStyle(ink.opacity(0.8))
                            .lineLimit(2)
                    }
                }
            }
            .foregroundStyle(ink)
            .padding(showsTile ? 4 : 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(BlockSurface(color: color, running: segment.span.isRunning))
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

    /// The set's launcher tile at block scale, or the placeholder: the
    /// same rounded square in the first label's colour with no glyph —
    /// the shape says "a tally", the colour says which.
    @ViewBuilder
    private func blockTile(set: TagSet?, color: Color, size: CGFloat) -> some View {
        if let set {
            LauncherTileIcon(set: set, size: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.27)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: size * 0.27)
                    .strokeBorder(color.contrastingTextColor.opacity(0.35), lineWidth: 1))
                .frame(width: size, height: size)
        }
    }

    /// Glass wants something behind it to bend: a wash of the day's top
    /// colours, faint, diagonal like the launcher tiles' gradient, and a
    /// light from the top-leading corner. Empty days get the light alone.
    private func columnWash(_ day: DateInterval) -> some View {
        let groups = CalendarLayout.dayGroups(spans: model.history.spans, day: day).prefix(3)
        let colors = groups.map { color(for: $0.label).opacity(0.14) } + [Color.clear]
        return ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.white.opacity(0.07), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 600)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One glass container per column, so neighbouring blocks' glass
    /// resolves together (and cheaper than one effect per block).
    @ViewBuilder
    private func glassContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(macOS 26, iOS 26, *) {
            GlassEffectContainer(spacing: 4) { content() }
        } else {
            content()
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

    // MARK: Month scroll

    /// Months as sections of day cards (`DayCard`, #304) in one vertical
    /// scroll, oldest at the top — scroll up for earlier months. Each
    /// month loads as its section nears the viewport; the section under
    /// the viewport's top reports back as `calendarMonth`, so the header's
    /// label follows the scroll, and the stepping / Today / a mode switch
    /// scroll to their month. Tap a card to open that day.
    ///
    /// Section heights are computed, not measured: every section is a
    /// placeholder of known height that draws its cards only near the
    /// viewport (a lazy stack estimates unrealised heights, and a scroll
    /// target across two years of estimates lands rows off). So the
    /// initial anchor is arithmetic, and `scrollTo` is exact.
    private var monthScroll: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(weekdayHeaders, id: \.self) { name in
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, Self.monthInset)
            Divider()
            if outerScroll != nil {
                // Embedded in a page scroll: the calendar month alone, at
                // a fixed card size.
                monthSection(model.history.calendarMonth, side: 96, titled: false)
            } else {
                GeometryReader { geo in
                    let side = cardSide(in: geo.size)
                    let months = monthRange
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                Button {
                                    extendMonths(proxy)
                                } label: {
                                    Label("Earlier months", systemImage: "chevron.up")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: Self.earlierRowHeight)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                ForEach(months, id: \.self) { month in
                                    monthSlot(month, side: side, viewportHeight: geo.size.height)
                                        .id(month)
                                }
                            }
                        }
                        .coordinateSpace(name: "monthScroll")
                        .defaultScrollAnchor(monthAnchor(for: model.history.calendarMonth, months: months,
                                                         side: side, viewportHeight: geo.size.height))
                        // Tracking starts once the first layout has
                        // landed on the anchor: an early report must not
                        // become the calendar month.
                        .task {
                            try? await Task.sleep(for: .milliseconds(100))
                            monthScrollSettled = true
                        }
                        .onChange(of: monthTops) { _, tops in
                            guard monthScrollSettled,
                                  let current = Self.currentMonth(tops: tops),
                                  current != scrolledMonth else { return }
                            scrolledMonth = current
                            model.history.setCalendarMonth(current)
                        }
                        .onChange(of: model.history.calendarMonth) { _, month in
                            // A step, Today, or a day → month switch: scroll
                            // there. A scroll-driven change is already there.
                            if month != scrolledMonth { showMonth(month, proxy, animated: true) }
                        }
                    }
                }
            }
        }
    }

    /// The month sections on screen: the trailing two years through the
    /// month after the later of this month and the calendar month — one
    /// past, so the calendar month can sit at the top with a shorter
    /// section below it instead of the scroll clamping on its tail — and
    /// extended as the stepping or "Earlier months" reaches past either end.
    private var monthRange: [Date] {
        let calendar = Calendar.current
        let thisMonth = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        let current = model.history.calendarMonth
        let after = calendar.date(byAdding: .month, value: 1, to: max(thisMonth, current)) ?? current
        let last = max(monthRangeLast ?? after, after)
        let first = min(monthRangeFirst
                        ?? calendar.date(byAdding: .month, value: -24, to: last) ?? last,
                        current)
        return CalendarLayout.months(from: first, through: last)
    }

    /// The month whose section holds the viewport's top edge: the lowest
    /// section top at or above it, else the first one below (the scroll
    /// is above every section — the "Earlier months" row).
    private static func currentMonth(tops: [Date: CGFloat]) -> Date? {
        let above = tops.filter { $0.value <= 8 }
        if let current = above.max(by: { $0.value < $1.value }) { return current.key }
        return tops.min(by: { $0.value < $1.value })?.key
    }

    /// Twelve more months above the oldest, which stays where it is.
    private func extendMonths(_ proxy: ScrollViewProxy) {
        guard let first = monthRange.first else { return }
        monthRangeFirst = Calendar.current.date(byAdding: .month, value: -12, to: first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            proxy.scrollTo(first, anchor: .top)
        }
    }

    /// Put `month` at the top, widening the range when it lies outside.
    /// A widened range lays out first; the scroll follows a beat later.
    private func showMonth(_ month: Date, _ proxy: ScrollViewProxy, animated: Bool = false) {
        var widened = false
        if let first = monthRange.first, month < first { monthRangeFirst = month; widened = true }
        if let last = monthRange.last, month >= last {
            monthRangeLast = Calendar.current.date(byAdding: .month, value: 1, to: month)
            widened = true
        }
        scrolledMonth = month
        let scroll = {
            if animated {
                withAnimation(.snappy) { proxy.scrollTo(month, anchor: .top) }
            } else {
                proxy.scrollTo(month, anchor: .top)
            }
        }
        if widened {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: scroll)
        } else {
            scroll()
        }
    }

    /// The initial scroll position with `month` at the top, as the
    /// fraction of the scrollable height its offset is (the time grid's
    /// `anchor(forHour:)` arithmetic).
    private func monthAnchor(for month: Date, months: [Date], side: CGFloat,
                             viewportHeight: CGFloat) -> UnitPoint {
        var offset = Self.earlierRowHeight
        var content = Self.earlierRowHeight
        for candidate in months {
            let height = monthHeight(candidate, side: side)
            if candidate < month { offset += height }
            content += height
        }
        let scrollable = content - viewportHeight
        guard scrollable > 0 else { return .top }
        return UnitPoint(x: 0, y: min(1, offset / scrollable))
    }

    /// Cards are squares sized by the column width, capped so six rows and
    /// the title fit the viewport — a month is never taller than the page.
    private func cardSide(in size: CGSize) -> CGFloat {
        let byWidth = (size.width - 2 * Self.monthInset) / 7 - Self.cardGap
        let byHeight = (size.height - Self.monthTitleHeight) / 6 - Self.cardGap
        return max(40, min(byWidth, byHeight))
    }

    /// A section's height: title, rows of cards with their gaps, and the
    /// vertical padding — what `monthSection` lays out.
    private func monthHeight(_ month: Date, side: CGFloat) -> CGFloat {
        let rows = CGFloat(CalendarLayout.monthGridDays(month: month).count / 7)
        return Self.monthTitleHeight + rows * (side + Self.cardGap) + Self.cardGap
    }

    private static let cardGap: CGFloat = 6
    private static let monthInset: CGFloat = 8
    private static let monthTitleHeight: CGFloat = 30
    private static let earlierRowHeight: CGFloat = 32

    /// The calendar's weekday names in its first-weekday order.
    private var weekdayHeaders: [String] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    /// A month's slot in the scroll: the computed height always, the
    /// cards only within a page of the viewport. It reports its top so
    /// the tracking and the realisation both work off one number.
    private func monthSlot(_ month: Date, side: CGFloat, viewportHeight: CGFloat) -> some View {
        let height = monthHeight(month, side: side)
        let top = monthTops[month]
        let near = top.map { $0 < 2 * viewportHeight && $0 + height > -viewportHeight } ?? false
        return Color.clear
            .frame(height: height)
            .overlay(alignment: .top) {
                if near {
                    monthSection(month, side: side, titled: true)
                }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named("monthScroll")).minY
            } action: { top in
                monthTops[month] = top
            }
    }

    /// One month: its title row, then whole weeks of day cards. The load
    /// task keys on the data version so a mutation refetches in place.
    private func monthSection(_ month: Date, side: CGFloat, titled: Bool) -> some View {
        let history = model.history
        let days = CalendarLayout.monthGridDays(month: month)
        let rows = days.count / 7
        let interval = HistoryModel.monthInterval(of: month)
        let spans = history.monthSpans(for: month)
        return VStack(spacing: Self.cardGap) {
            if titled {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.monthTitleHeight - Self.cardGap)
                    .padding(.horizontal, 4)
            }
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(days[row * 7..<(row + 1) * 7], id: \.self) { day in
                        monthCell(day, side: side, spans: spans, inMonth: interval.contains(day))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: side)
            }
        }
        .padding(.horizontal, Self.monthInset)
        .padding(.vertical, Self.cardGap)
        .task(id: "\(month.timeIntervalSince1970)-\(history.monthDataVersion)") {
            await history.loadMonthIfNeeded(month)
        }
    }

    private func monthCell(_ dayStart: Date, side: CGFloat, spans: [TimeSpan], inMonth: Bool) -> some View {
        let calendar = Calendar.current
        let history = model.history
        let end = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let day = DateInterval(start: dayStart, end: end)
        let groups = CalendarLayout.dayGroups(spans: spans, day: day)
        let total = groups.reduce(0) { $0 + $1.seconds }
        let topSet = setup.showDayIcons
            ? CalendarLayout.topSet(spans: spans, day: day, sets: model.tagSets,
                                    quicks: { model.quickLabels(for: $0) })
            : nil

        return Button {
            history.showDay(dayStart, switchingMode: true)
        } label: {
            DayCard(dayStart: dayStart, side: side, inMonth: inMonth,
                    isToday: day.contains(Date()), groups: groups, total: total,
                    topSet: topSet, color: { color(for: $0) })
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayStart.formatted(.dateTime.weekday(.wide).month().day()))
        .accessibilityValue(total > 0 ? formatDuration(total) : "nothing marked")
        .help("Show this day")
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

<<<<<<< HEAD

/// The block's surface (#302): liquid glass tinted with the block colour
/// where the OS has it, the flat tinted fill before that. A running span
/// keeps its accent border on either.
private struct BlockSurface: ViewModifier {
    let color: Color
    let running: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if #available(macOS 26, iOS 26, *) {
            content
                .glassEffect(.regular.tint(color.opacity(0.82)), in: shape)
                .overlay(shape.strokeBorder(running ? Color.accentColor : color.contrastingTextColor.opacity(0.18),
                                            lineWidth: running ? 1.5 : 0.5))
        } else {
            content
                .background(shape.fill(color.opacity(0.9)))
                .overlay(shape.strokeBorder(running ? Color.accentColor : color.opacity(0.4),
                                            lineWidth: running ? 1.5 : 0.5))
=======
/// A month-view day (#304): a rounded square *filled* with the day's colour
/// distribution — the pie's sectors, clockwise from twelve, largest first
/// (the History donut's convention), clipped to the card — with the day
/// number top-leading, the total bottom-trailing, and the top tally set's
/// icon on a glass disc in the middle. A day with nothing marked is the
/// same card unfilled, so the grid stays regular; today wears an accent
/// ring; days of the neighbouring months fade.
private struct DayCard: View {
    let dayStart: Date
    let side: CGFloat
    let inMonth: Bool
    let isToday: Bool
    let groups: [CalendarLayout.DayGroup]
    let total: TimeInterval
    let topSet: TagSet?
    let color: (SpanLabel?) -> Color

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
    }
    private var filled: Bool { total > 0 }
    /// Caption ink: white over the colour fill, secondary on an empty card.
    private var ink: Color { filled ? .white : .secondary }

    var body: some View {
        ZStack {
            if filled {
                pie.clipShape(shape)
            } else {
                shape.fill(.quaternary.opacity(0.6))
                shape.strokeBorder(.quaternary, lineWidth: 1)
            }
            if let topSet, side >= 44 {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: side * 0.44, height: side * 0.44)
                    .overlay {
                        TagSetIcon(set: topSet, size: side * 0.2, weight: .semibold)
                            .foregroundStyle(.primary)
                    }
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
        }
        .overlay(alignment: .topLeading) {
            Text(dayStart.formatted(.dateTime.day()))
                .font(.system(size: max(9, side * 0.14), weight: isToday ? .bold : .semibold))
                .monospacedDigit()
                .padding(.leading, side * 0.1)
                .padding(.top, side * 0.07)
        }
        .overlay(alignment: .bottomTrailing) {
            if filled, side >= 56 {
                Text(formatDuration(total))
                    .font(.system(size: max(8, side * 0.11), weight: .medium).monospacedDigit())
                    .padding(.trailing, side * 0.09)
                    .padding(.bottom, side * 0.07)
            }
        }
        .foregroundStyle(ink)
        .shadow(color: filled ? .black.opacity(0.35) : .clear, radius: 1.5, y: 0.5)
        .overlay {
            if isToday {
                shape.strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .frame(width: side, height: side)
        .contentShape(shape)
        .opacity(inMonth ? 1 : 0.35)
    }

    /// Sectors from the centre, with a radius past the corners so the
    /// clip is what shapes the card.
    private var pie: some View {
        Canvas { context, size in
            let radius = hypot(size.width, size.height) / 2 + 1
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            var angle = Angle.degrees(-90)
            for group in groups where total > 0 {
                let sweep = Angle.degrees(360 * group.seconds / total)
                var path = Path()
                path.move(to: center)
                path.addArc(center: center, radius: radius,
                            startAngle: angle, endAngle: angle + sweep, clockwise: false)
                path.closeSubpath()
                context.fill(path, with: .color(color(group.label).opacity(0.92)))
                angle += sweep
            }
>>>>>>> 3487258 (Calendar month: pie-filled day cards, a scroll through months, the top set's icon (#304))
        }
    }
}
