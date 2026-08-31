import Foundation
import Testing
@testable import MomentTallyKit
@testable import MomentTallyCore

/// The DTO ↔ domain mapping at the TraggoClient boundary: the RFC3339 time
/// scalar, wire timespans to domain `TimeSpan`, and traggo's cursor riding
/// opaquely inside `PageToken`.
@Suite struct TraggoWireMappingTests {

    // MARK: TraggoTime

    private func decodeTime(_ raw: String) throws -> TraggoTime {
        try JSONDecoder().decode(TraggoTime.self, from: Data("\"\(raw)\"".utf8))
    }

    @Test func decodesPlainRFC3339() throws {
        let time = try decodeTime("2026-07-29T10:15:30Z")
        #expect(time.date == Date(timeIntervalSince1970: 1_785_320_130))
    }

    @Test func decodesFractionalSecondsAndOffsets() throws {
        // The lenient side: traggo emits neither, but the web UI's inputs have
        // produced both in the wild.
        let fractional = try decodeTime("2026-07-29T10:15:30.500Z")
        #expect(abs(fractional.date.timeIntervalSince1970 - 1_785_320_130.5) < 0.001)

        let offset = try decodeTime("2026-07-29T12:15:30+02:00")
        #expect(offset.date == Date(timeIntervalSince1970: 1_785_320_130))
    }

    @Test func rejectsNonRFC3339() {
        #expect(throws: DecodingError.self) { try decodeTime("yesterday") }
    }

    @Test func encodeDecodeRoundTripsToTheSecond() throws {
        // The wire format has no fractional seconds, so start from a whole one.
        let original = TraggoTime(Date(timeIntervalSince1970: 1_785_320_130))
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TraggoTime.self, from: encoded)
        #expect(decoded.date == original.date)
    }

    // MARK: TraggoTimeSpan → TimeSpan

    @Test func mapsFinishedTimeSpanToDomain() throws {
        let json = """
        {"id": 7, "start": "2026-07-29T10:00:00Z", "end": "2026-07-29T11:00:00Z",
         "note": "review", "tags": [{"key": "repo", "value": "moment-tally"}]}
        """
        let span = try JSONDecoder().decode(TraggoTimeSpan.self, from: Data(json.utf8)).domain
        #expect(span.id == 7)
        #expect(span.start == Date(timeIntervalSince1970: 1_785_319_200))
        #expect(span.end == Date(timeIntervalSince1970: 1_785_322_800))
        #expect(span.note == "review")
        #expect(span.labels == [SpanLabel(key: "repo", value: "moment-tally")])
        #expect(!span.isRunning)
    }

    @Test func mapsRunningTimeSpanWithNoTags() throws {
        // A null end means running; null tags normalise to an empty label list.
        let json = """
        {"id": 8, "start": "2026-07-29T10:00:00Z", "end": null, "note": "", "tags": null}
        """
        let span = try JSONDecoder().decode(TraggoTimeSpan.self, from: Data(json.utf8)).domain
        #expect(span.end == nil)
        #expect(span.isRunning)
        #expect(span.labels.isEmpty)
    }

    // MARK: Cursor ↔ PageToken

    private func decodeCursor(hasMore: Bool) throws -> Cursor {
        let json = """
        {"hasMore": \(hasMore), "offset": 100, "startId": 424, "pageSize": 100}
        """
        return try JSONDecoder().decode(Cursor.self, from: Data(json.utf8))
    }

    @Test func cursorRoundTripsThroughPageToken() throws {
        let cursor = try decodeCursor(hasMore: true)
        let token = try #require(cursor.pageToken)
        #expect(Cursor(token) == cursor)
    }

    @Test func exhaustedCursorMintsNoToken() throws {
        let cursor = try decodeCursor(hasMore: false)
        #expect(cursor.pageToken == nil)
    }

    @Test func foreignTokenMapsToNoCursor() {
        #expect(Cursor(PageToken(rawValue: "not a cursor")) == nil)
    }
}
