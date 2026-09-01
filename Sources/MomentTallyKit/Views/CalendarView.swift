import SwiftUI
#if os(macOS)
import AppKit
#endif
import MomentTallyCore

/// The Calendar tab: a 7-day week grid with a vertical time axis, moments as
/// colored blocks (like the web UI's calendar). Overlapping spans share the
/// column width via lane packing; clicking a block jumps to the Log tab with
/// that span open for editing (#130 — the grid is too dense for a popover).
/// Spans crossing midnight render one segment per day they touch.
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

    private let hourHeight: CGFloat = 40
    private let gutterWidth: CGFloat = 46
    private var gridHeight: CGFloat { hourHeight * 24 }

    package init() {}

    package var body: some View {
        let history = model.history
        VStack(spacing: 0) {
            WeekNavigatorView()
            Divider()
            dayHeaderRow
            Divider()

            GeometryReader { viewport in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        hourGutter
                        ForEach(history.days, id: \.start) { day in
                            dayColumn(day)
                        }
                    }
                    .frame(height: gridHeight)
                }
                // Open on the working day, not midnight: the initial offset
                // that puts 08:00 at the top, expressed as the UnitPoint
                // fraction defaultScrollAnchor expects. (scrollTo from a task
                // is unreliable here — the tab transition resets the offset.)
                .defaultScrollAnchor(morningAnchor(viewportHeight: viewport.size.height))
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
    }

    // MARK: Chrome

    private var dayHeaderRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth, height: 1)
            ForEach(model.history.days, id: \.start) { day in
                let isToday = day.contains(Date())
                VStack(spacing: 1) {
                    Text(day.start.formatted(.dateTime.weekday(.abbreviated).day()))
                        .font(.caption.weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? Color.accentColor : .primary)
                    Text(formatDuration(model.history.totalSeconds(in: day)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
            }
        }
    }

    private var hourGutter: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            ForEach(1..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                    .padding(.top, CGFloat(hour) * hourHeight - 6)
            }
        }
        .frame(width: gutterWidth, height: gridHeight)
    }

    /// The UnitPoint whose aligned scroll offset puts 08:00 at the top of the
    /// viewport: offset = fraction × (content − viewport).
    private func morningAnchor(viewportHeight: CGFloat) -> UnitPoint {
        let scrollable = gridHeight - viewportHeight
        guard scrollable > 0 else { return .top }
        let fraction = min(1, 8 * hourHeight / scrollable)
        return UnitPoint(x: 0, y: fraction)
    }

    // MARK: Day columns

    private func dayColumn(_ day: DateInterval) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Hour lines + left border.
                ForEach(0..<24, id: \.self) { hour in
                    Rectangle()
                        .fill(separatorColor.opacity(0.5))
                        .frame(height: 1)
                        .padding(.top, CGFloat(hour) * hourHeight)
                }
                Rectangle()
                    .fill(separatorColor)
                    .frame(width: 1)

                ForEach(segments(for: day)) { segment in
                    block(segment, day: day, columnWidth: geo.size.width)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: gridHeight)
    }

    @ViewBuilder
    private func block(_ segment: CalendarSegment, day: DateInterval, columnWidth: CGFloat) -> some View {
        let y = segment.interval.start.timeIntervalSince(day.start) / day.duration * gridHeight
        let height = max(9, segment.interval.duration / day.duration * gridHeight)
        let laneWidth = (columnWidth - 5) / CGFloat(segment.laneCount)
        let x = 3 + CGFloat(segment.lane) * laneWidth
        let color = blockColor(segment.span)

        Button {
            // Hand the span to the Log tab and switch over — it scrolls to
            // the row and expands it.
            model.history.requestLogEdit(of: segment.span)
            openAppSection(.log)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(segment.span.timeRangeLabel)
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                Text(tagText(segment.span))
                    .font(.system(size: 9))
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
        .padding(.top, y)
        .help("\(segment.span.timeRangeLabel)  \(tagText(segment.span))"
              + (segment.span.note.isEmpty ? "" : "\n\(segment.span.note)")
              + "\nClick to edit in the Log")
    }

    private func tagText(_ span: TimeSpan) -> String {
        span.labels
            .map { $0.value.isEmpty ? $0.key : "\($0.key):\($0.value)" }
            .joined(separator: " ")
    }

    /// Blocks take the color of their first tag (the web UI similarly
    /// derives block color from tags).
    private func blockColor(_ span: TimeSpan) -> Color {
        if let first = span.labels.first {
            return model.tagColor(for: first.key, value: first.value)
        }
        return .gray
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
