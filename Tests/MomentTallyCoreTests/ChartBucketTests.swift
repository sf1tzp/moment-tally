// Apple-only (#85): these tests exercise the app layer in MomentTallyKit,
// which (like the SwiftUI beneath it) does not exist on Linux.
#if canImport(MomentTallyKit)
import Foundation
import Testing
@testable import MomentTallyKit
@testable import MomentTallyCore

/// The History charts' trailing-range windowing (#163): calendar-aligned
/// buckets clipped to the window, and the trailing lower bounds themselves.
@Suite struct ChartBucketTests {

    /// A fixed calendar so results don't depend on the machine's locale
    /// (Monday first, UTC — bucket alignment is what's under test).
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    // MARK: Bucketing

    @Test func dayBucketsCoverTheWindowContiguously() {
        let interval = DateInterval(start: date(2026, 8, 1), end: date(2026, 8, 8))
        let buckets = HistoryModel.buckets(of: .day, spanning: interval, calendar: calendar)
        #expect(buckets.count == 7)
        #expect(buckets.first?.start == interval.start)
        #expect(buckets.last?.end == interval.end)
        for (a, b) in zip(buckets, buckets.dropFirst()) {
            #expect(a.end == b.start)
        }
    }

    @Test func edgeBucketsAreClippedToTheWindow() {
        // A trailing window rarely starts on a calendar boundary: the first
        // and last week buckets must be clipped, or spans overlapping the
        // window's edges would count time from outside it.
        let interval = DateInterval(start: date(2026, 5, 6, 14, 30),
                                    end: date(2026, 8, 4, 9, 15))
        let buckets = HistoryModel.buckets(of: .weekOfYear, spanning: interval,
                                           calendar: calendar)
        #expect(buckets.first?.start == interval.start)
        #expect(buckets.last?.end == interval.end)
        // Interior buckets are whole weeks aligned to the calendar.
        for bucket in buckets.dropFirst().dropLast() {
            #expect(calendar.dateInterval(of: .weekOfYear, for: bucket.start)?.start
                    == bucket.start)
            #expect(calendar.date(byAdding: .weekOfYear, value: 1, to: bucket.start)
                    == bucket.end)
        }
        // ~13 weeks in 90 days; clipping can add one partial bucket per edge.
        #expect((13...14).contains(buckets.count))
    }

    @Test func monthBucketsAlignToMonthStarts() {
        let interval = DateInterval(start: date(2025, 8, 4), end: date(2026, 8, 4))
        let buckets = HistoryModel.buckets(of: .month, spanning: interval,
                                           calendar: calendar)
        #expect(buckets.count == 13)    // 12 whole months plus a clipped edge
        #expect(buckets[1].start == date(2025, 9, 1))
        #expect(buckets.first?.start == interval.start)
        #expect(buckets.last?.end == interval.end)
    }

    @Test func emptyAndInvertedWindowsYieldNoBuckets() {
        let instant = date(2026, 8, 4)
        #expect(HistoryModel.buckets(of: .day,
                                     spanning: DateInterval(start: instant, end: instant),
                                     calendar: calendar).isEmpty)
    }

    // MARK: Trailing lower bounds

    @Test func trailingStartsCountBackFromNow() {
        let now = date(2026, 8, 4, 12, 0)
        #expect(TrailingRange.days30.start(from: now, calendar: calendar)
                == date(2026, 7, 5, 12, 0))
        #expect(TrailingRange.days90.start(from: now, calendar: calendar)
                == date(2026, 5, 6, 12, 0))
        #expect(TrailingRange.year.start(from: now, calendar: calendar)
                == date(2025, 8, 4, 12, 0))
        #expect(TrailingRange.all.start(from: now, calendar: calendar)
                == Date(timeIntervalSince1970: 0))
    }
}
#endif
