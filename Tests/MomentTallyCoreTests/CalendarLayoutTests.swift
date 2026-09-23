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

    // MARK: Month scroll (#304)

    @Test func monthsRunFromFirstThroughLastInclusive() {
        let months = CalendarLayout.months(from: date(2026, 7, 15), through: date(2026, 9, 3), calendar: calendar)
        #expect(months == [date(2026, 7, 1), date(2026, 8, 1), date(2026, 9, 1)])
        #expect(CalendarLayout.months(from: date(2026, 9, 1), through: date(2026, 8, 1), calendar: calendar).isEmpty)
    }

    @Test func topSetIsTheSetWithTheMostClippedTime() {
        let work = TagSet(name: "Work", tags: [TagRow(key: "type", value: "work")])
        let rest = TagSet(name: "Rest", tags: [TagRow(key: "type", value: "rest")])
        let quick = TagRow(key: "focus", value: "deep")
        let quicks: (TagSet) -> [TagRow] = { $0.id == work.id ? [quick] : [] }
        // Work 09–10 plain plus 10–11 honed by its quick label (2h, still
        // Work); Rest 14–16:30 (2h 30m); a span no set claims; a span that
        // crosses out of the day counts only its 23:00–24:00 hour.
        let spans = [
            TimeSpan(id: 1, start: date(2026, 9, 22, 9), end: date(2026, 9, 22, 10), note: "",
                     labels: [SpanLabel(key: "type", value: "work")]),
            TimeSpan(id: 2, start: date(2026, 9, 22, 10), end: date(2026, 9, 22, 11), note: "",
                     labels: [SpanLabel(key: "type", value: "work"), SpanLabel(key: "focus", value: "deep")]),
            TimeSpan(id: 3, start: date(2026, 9, 22, 14), end: date(2026, 9, 22, 16, 30), note: "",
                     labels: [SpanLabel(key: "type", value: "rest")]),
            TimeSpan(id: 4, start: date(2026, 9, 22, 17), end: date(2026, 9, 22, 22), note: "",
                     labels: [SpanLabel(key: "type", value: "other")]),
            TimeSpan(id: 5, start: date(2026, 9, 22, 23), end: date(2026, 9, 23, 5), note: "",
                     labels: [SpanLabel(key: "type", value: "work")]),
        ]
        let top = CalendarLayout.topSet(spans: spans, day: day, sets: [work, rest], quicks: quicks)
        #expect(top?.id == work.id)   // 3h vs 2h 30m
        #expect(CalendarLayout.topSet(spans: [spans[3]], day: day, sets: [work, rest], quicks: quicks) == nil)
        #expect(CalendarLayout.topSet(spans: spans, day: day, sets: [], quicks: quicks) == nil)
    }

    @Test func topSetTiesGoToTheEarlierSet() {
        let a = TagSet(name: "A", tags: [TagRow(key: "k", value: "a")])
        let b = TagSet(name: "B", tags: [TagRow(key: "k", value: "b")])
        let spans = [
            TimeSpan(id: 1, start: date(2026, 9, 22, 9), end: date(2026, 9, 22, 10), note: "",
                     labels: [SpanLabel(key: "k", value: "b")]),
            TimeSpan(id: 2, start: date(2026, 9, 22, 11), end: date(2026, 9, 22, 12), note: "",
                     labels: [SpanLabel(key: "k", value: "a")]),
        ]
        #expect(CalendarLayout.topSet(spans: spans, day: day, sets: [a, b], quicks: { _ in [] })?.id == a.id)
        #expect(CalendarLayout.topSet(spans: spans, day: day, sets: [b, a], quicks: { _ in [] })?.id == b.id)
    }

    // MARK: Setup persistence

    @Test func calendarSetupDecodesWithoutTheNewerKeys() throws {
        let stored = Data(#"{"mode":"day","hourHeight":55,"fullDay":true}"#.utf8)
        let setup = try JSONDecoder().decode(CalendarSetup.self, from: stored)
        #expect(setup == CalendarSetup(mode: .day, hourHeight: 55, fullDay: true, showDayIcons: true))
        let roundTrip = try JSONDecoder().decode(
            CalendarSetup.self,
            from: JSONEncoder().encode(CalendarSetup(showDayIcons: false)))
        #expect(roundTrip.showDayIcons == false)
    }
}
#endif
