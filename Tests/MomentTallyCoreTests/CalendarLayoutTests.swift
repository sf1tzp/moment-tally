// Apple-only (#85): these tests exercise the app layer in MomentTallyKit,
// which (like the SwiftUI beneath it) does not exist on Linux.
#if canImport(MomentTallyKit)
import Foundation
import Testing
@testable import MomentTallyKit
@testable import MomentTallyCore

/// The Calendar's pure layout decisions (#286).
@Suite struct CalendarLayoutTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1   // Sunday
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func span(_ id: Int, _ start: Date, _ end: Date?) -> TimeSpan {
        TimeSpan(id: id, start: start, end: end, note: "", labels: [SpanLabel(key: "type", value: "x")])
    }

    private var day: DateInterval { DateInterval(start: date(2026, 9, 22), end: date(2026, 9, 23)) }

    // MARK: Visible hours

    @Test func workingDayByDefault() {
        #expect(CalendarLayout.visibleHours(fullDay: false, days: [day], spans: [], calendar: calendar)
                == 7..<22)
    }

    @Test func fullDayShowsEverything() {
        #expect(CalendarLayout.visibleHours(fullDay: true, days: [day], spans: [], calendar: calendar)
                == 0..<24)
    }

    @Test func spansOutsideWidenTheWindow() {
        // 05:30–06:10 pulls the start to 05:00; 23:20–23:50 pushes the end to 24.
        let spans = [span(1, date(2026, 9, 22, 5, 30), date(2026, 9, 22, 6, 10)),
                     span(2, date(2026, 9, 22, 23, 20), date(2026, 9, 22, 23, 50))]
        #expect(CalendarLayout.visibleHours(fullDay: false, days: [day], spans: spans, calendar: calendar)
                == 5..<24)
    }

    @Test func spansInsideDoNotNarrowIt() {
        let spans = [span(1, date(2026, 9, 22, 10), date(2026, 9, 22, 11))]
        #expect(CalendarLayout.visibleHours(fullDay: false, days: [day], spans: spans, calendar: calendar)
                == 7..<22)
    }

    @Test func runningSpanClipsAtNow() {
        let now = date(2026, 9, 22, 22, 30)
        let spans = [span(1, date(2026, 9, 22, 21), nil)]
        #expect(CalendarLayout.visibleHours(fullDay: false, days: [day], spans: spans, now: now, calendar: calendar)
                == 7..<23)
    }

    // MARK: Month grid

    @Test func monthGridIsWholeWeeksFromTheFirstsWeek() {
        // September 2026 starts on a Tuesday and ends on a Wednesday: the
        // grid runs Sun Aug 30 … Sat Oct 3, five rows.
        let days = CalendarLayout.monthGridDays(month: date(2026, 9, 1), calendar: calendar)
        #expect(days.count == 35)
        #expect(days.first == date(2026, 8, 30))
        #expect(days.last == date(2026, 10, 3))
    }

    @Test func monthStartingOnTheFirstWeekdayHasNoLeadingDays() {
        // November 2026 starts on a Sunday.
        let days = CalendarLayout.monthGridDays(month: date(2026, 11, 1), calendar: calendar)
        #expect(days.first == date(2026, 11, 1))
        #expect(days.count == 35)
    }

    // MARK: Day groups

    @Test func dayGroupsSumByFirstLabelLargestFirst() {
        let a = TimeSpan(id: 1, start: date(2026, 9, 22, 9), end: date(2026, 9, 22, 10), note: "",
                         labels: [SpanLabel(key: "type", value: "a"), SpanLabel(key: "proj", value: "p")])
        let b = TimeSpan(id: 2, start: date(2026, 9, 22, 10), end: date(2026, 9, 22, 13), note: "",
                         labels: [SpanLabel(key: "type", value: "b")])
        let a2 = TimeSpan(id: 3, start: date(2026, 9, 22, 14), end: date(2026, 9, 22, 15, 30), note: "",
                          labels: [SpanLabel(key: "type", value: "a")])
        let groups = CalendarLayout.dayGroups(spans: [a, b, a2], day: day)
        let labels: [SpanLabel?] = groups.map(\.label)
        let expectedLabels: [SpanLabel?] = [SpanLabel(key: "type", value: "b"),
                                            SpanLabel(key: "type", value: "a")]
        #expect(labels == expectedLabels)
        let seconds: [TimeInterval] = groups.map(\.seconds)
        #expect(seconds == [10_800, 9_000])
    }

    @Test func dayGroupsClipToTheDayAndGroupUnlabelled() {
        // Crosses midnight into the day: only the 00:00–01:00 part counts.
        let overnight = TimeSpan(id: 1, start: date(2026, 9, 21, 23), end: date(2026, 9, 22, 1), note: "", labels: [])
        let groups = CalendarLayout.dayGroups(spans: [overnight], day: day)
        #expect(groups == [CalendarLayout.DayGroup(label: nil, seconds: 3600)])
    }
}
#endif
