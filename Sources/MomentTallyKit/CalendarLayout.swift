import Foundation
import MomentTallyCore

/// Pure layout decisions for the Calendar (#286), kept off the view so they
/// are unit-testable: the visible hour window, the month grid's day cells,
/// and a day's colour distribution for the month blocks.
package enum CalendarLayout {
    /// The working day the grid shows unless `fullDay`: 07:00–22:00.
    package static let workingHours = 7..<22

    /// Hours the grid renders: all 24 with `fullDay`; otherwise the working
    /// day widened to cover every span touching `days`, so nothing is ever
    /// hidden — the empty night is what gets dropped. Half-open: `7..<22`
    /// draws rows for 07:00 through 21:00 and the 22:00 line.
    package static func visibleHours(fullDay: Bool, days: [DateInterval],
                                     spans: [TimeSpan], now: Date = Date(),
                                     calendar: Calendar = .current) -> Range<Int> {
        guard !fullDay else { return 0..<24 }
        var lower = workingHours.lowerBound
        var upper = workingHours.upperBound
        for day in days {
            for span in spans {
                let start = max(span.start, day.start)
                let end = min(span.end ?? now, day.end)
                guard end > start else { continue }
                let startHour = Int(start.timeIntervalSince(day.start) / 3600)
                let endHour = Int((end.timeIntervalSince(day.start) / 3600).rounded(.up))
                lower = min(lower, max(0, startHour))
                upper = max(upper, min(24, endHour))
            }
        }
        return lower..<upper
    }

    /// The day cells of a month grid: whole weeks per the calendar's first
    /// weekday, from the week holding the 1st through the week holding the
    /// last day — leading and trailing days of the neighbouring months fill
    /// the rows. Count is a multiple of 7.
    package static func monthGridDays(month: Date, calendar: Calendar = .current) -> [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let first = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start)?.start,
              let lastDay = calendar.date(byAdding: .second, value: -1, to: monthInterval.end),
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastDay)
        else { return [] }
        var days: [Date] = []
        var cursor = first
        while cursor < lastWeek.end {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// The first days of every month from `first` through `last` (both
    /// month starts, inclusive) — the month scroll's sections (#304).
    package static func months(from first: Date, through last: Date,
                               calendar: Calendar = .current) -> [Date] {
        guard let start = calendar.dateInterval(of: .month, for: first)?.start,
              let end = calendar.dateInterval(of: .month, for: last)?.start,
              start <= end else { return [] }
        var months: [Date] = []
        var cursor = start
        while cursor <= end {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }

    /// The tally set with the most clipped seconds in `day` — the day card's
    /// icon (#304). A span counts for the first set in `sets` that reads it
    /// as its own (`TagSet.matches`, the Launcher's running rule); spans no
    /// set claims count for nothing. Nil when no set has any time. Ties go
    /// to the earlier set in `sets` (the Launcher's order).
    package static func topSet(spans: [TimeSpan], day: DateInterval, sets: [TagSet],
                               quicks: (TagSet) -> [TagRow], now: Date = Date()) -> TagSet? {
        guard !sets.isEmpty else { return nil }
        let quickLists = sets.map(quicks)
        var seconds = [TimeInterval](repeating: 0, count: sets.count)
        for span in spans {
            let start = max(span.start, day.start)
            let end = min(span.end ?? now, day.end)
            guard end > start,
                  let index = sets.indices.first(where: {
                      sets[$0].matches(spanLabels: span.labels, quicks: quickLists[$0])
                  })
            else { continue }
            seconds[index] += end.timeIntervalSince(start)
        }
        guard let best = seconds.indices.max(by: {
            seconds[$0] != seconds[$1] ? seconds[$0] < seconds[$1] : $0 > $1
        }), seconds[best] > 0 else { return nil }
        return sets[best]
    }

    /// One slice of a day's colour distribution: the first label of the
    /// spans behind it (the block colour's rule) and their clipped seconds.
    package struct DayGroup: Equatable {
        package let label: SpanLabel?
        package let seconds: TimeInterval
    }

    /// Seconds per first-label group within one day, largest first — the
    /// month block's pie. Spans without labels group under nil.
    package static func dayGroups(spans: [TimeSpan], day: DateInterval,
                                  now: Date = Date()) -> [DayGroup] {
        var sums: [SpanLabel?: TimeInterval] = [:]
        for span in spans {
            let start = max(span.start, day.start)
            let end = min(span.end ?? now, day.end)
            guard end > start else { continue }
            sums[span.labels.first, default: 0] += end.timeIntervalSince(start)
        }
        return sums.map { DayGroup(label: $0.key, seconds: $0.value) }
            .sorted {
                $0.seconds != $1.seconds ? $0.seconds > $1.seconds
                    : ($0.label?.key ?? "") + ($0.label?.value ?? "") < ($1.label?.key ?? "") + ($1.label?.value ?? "")
            }
    }
}
