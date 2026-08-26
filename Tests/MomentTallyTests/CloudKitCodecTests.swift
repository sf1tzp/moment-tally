import CloudKit
import Foundation
import GRDB
import Testing
@testable import MomentTally
@testable import MomentTallyCore

/// The CloudKit record codec (#121) and the v7 identity migration, exercised
/// with no CloudKit container: a CKRecord is a plain object until an
/// operation ships it, so encode/decode and the encryption boundary are all
/// testable in-process — the CI stand-in the protocol-wrapped transport will
/// build on.
@Suite struct CloudKitCodecTests {

    private func date(_ epochSeconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    }

    private var sampleSpan: CloudSpan {
        CloudSpan(uuid: UUID().uuidString,
                  start: date(1_700_000_000), end: date(1_700_003_600),
                  note: "kneading",
                  labels: [SpanLabel(key: "recipe", value: "sourdough"),
                           SpanLabel(key: "kitchen", value: "home"),
                           SpanLabel(key: "batch", value: "2")],
                  modifiedAt: date(1_700_003_601))
    }

    // MARK: Round trips

    @Test func spanRoundTrips() throws {
        let span = sampleSpan
        let decoded = try CloudKitRecordCodec.span(from: CloudKitRecordCodec.record(for: span))
        #expect(decoded == span)
    }

    @Test func runningSpanKeepsNilEnd() throws {
        let span = CloudSpan(uuid: UUID().uuidString, start: date(1_700_000_000),
                             end: nil, note: "", labels: [],
                             modifiedAt: date(1_700_000_000))
        let decoded = try CloudKitRecordCodec.span(from: CloudKitRecordCodec.record(for: span))
        #expect(decoded.end == nil)
        #expect(decoded == span)
    }

    @Test func labelDefinitionRoundTripsUnderMintedName() throws {
        let definition = CloudLabelDefinition(key: "recipe", color: "#ff9500",
                                              modifiedAt: date(1_700_000_010))
        let record = CloudKitRecordCodec.record(for: definition,
                                                recordName: UUID().uuidString)
        #expect(try CloudKitRecordCodec.labelDefinition(from: record) == definition)
    }

    @Test func valueColorRoundTripsUnderMintedName() throws {
        let valueColor = CloudValueColor(key: "recipe", value: "sourdough",
                                         color: "#f7b060", modifiedAt: date(1_700_000_020))
        let record = CloudKitRecordCodec.record(for: valueColor,
                                                recordName: UUID().uuidString)
        #expect(try CloudKitRecordCodec.valueColor(from: record) == valueColor)
    }

    @Test func labelSetRoundTrips() throws {
        let labelSet = CloudLabelSet(
            uuid: UUID().uuidString, name: "Cooking", symbolName: "frying.pan",
            labels: [SpanLabel(key: "recipe", value: ""),
                     SpanLabel(key: "kitchen", value: "home")],
            quickLabels: [SpanLabel(key: "recipe", value: "sourdough"),
                          SpanLabel(key: "recipe", value: "focaccia")],
            position: 3, modifiedAt: date(1_700_000_030))
        #expect(try CloudKitRecordCodec.labelSet(from: CloudKitRecordCodec.record(for: labelSet)) == labelSet)
    }

    @Test func preferencesRoundTripUnderFixedName() throws {
        let preferences = CloudPreferences(colorByValue: true, menuLabelSetLimit: 5,
                                           modifiedAt: date(1_700_000_040))
        let record = CloudKitRecordCodec.record(for: preferences)
        #expect(record.recordID.recordName == CloudKitSchema.preferencesRecordName)
        #expect(try CloudKitRecordCodec.preferences(from: record) == preferences)
    }

    // MARK: Label order is contractual (#159)

    @Test func labelOrderSurvivesVerbatim() throws {
        let ordered = [SpanLabel(key: "c", value: "3"),
                       SpanLabel(key: "a", value: "1"),
                       SpanLabel(key: "b", value: "2")]
        let span = CloudSpan(uuid: UUID().uuidString, start: date(1_700_000_000),
                             end: nil, note: "", labels: ordered,
                             modifiedAt: date(1_700_000_000))
        let decoded = try CloudKitRecordCodec.span(from: CloudKitRecordCodec.record(for: span))
        #expect(decoded.labels == ordered)

        let reversed = CloudSpan(uuid: span.uuid, start: span.start, end: nil,
                                 note: "", labels: ordered.reversed(),
                                 modifiedAt: span.modifiedAt)
        let decodedReversed = try CloudKitRecordCodec.span(from: CloudKitRecordCodec.record(for: reversed))
        #expect(decodedReversed.labels == ordered.reversed())
        #expect(decodedReversed.labels != decoded.labels)
    }

    @Test func equalLabelListsEncodeByteEqual() throws {
        // Byte-equal payloads for equal lists let the transport compare
        // payloads instead of decoding both sides.
        let spanRecord = { CloudKitRecordCodec.record(for: self.sampleSpan) }
        let first = spanRecord().encryptedValues["labels"] as? Data
        let second = spanRecord().encryptedValues["labels"] as? Data
        #expect(first != nil && first == second)
    }

    // MARK: Encryption boundary

    @Test func userDataLivesOnlyInEncryptedValues() throws {
        let records = [
            CloudKitRecordCodec.record(for: sampleSpan),
            CloudKitRecordCodec.record(for: CloudLabelDefinition(
                key: "recipe", color: "#ff9500", modifiedAt: date(0)),
                recordName: UUID().uuidString),
            CloudKitRecordCodec.record(for: CloudValueColor(
                key: "recipe", value: "sourdough", color: "#f7b060", modifiedAt: date(0)),
                recordName: UUID().uuidString),
            CloudKitRecordCodec.record(for: CloudLabelSet(
                uuid: UUID().uuidString, name: "Cooking", symbolName: "frying.pan",
                labels: [], quickLabels: [], position: 0, modifiedAt: date(0))),
            CloudKitRecordCodec.record(for: CloudPreferences(
                colorByValue: false, menuLabelSetLimit: 3, modifiedAt: date(0)))
        ]
        for record in records {
            // allKeys() lists encrypted fields too (field *names* travel in
            // the clear; values are what encryptedValues protects), so the
            // boundary to assert is access: every field except the version
            // stamp must be unreadable through the plain subscript and
            // readable through encryptedValues.
            for key in record.allKeys() where key != "v" {
                #expect(record[key] == nil,
                        "\(record.recordType).\(key) is readable unencrypted")
                #expect(record.encryptedValues[key] != nil,
                        "\(record.recordType).\(key) missing from encryptedValues")
            }
            #expect(record["v"] as? Int == CloudKitSchema.currentRecordVersion)
        }
    }

    @Test func mintedRecordNamesNeverContainNaturalKeys() throws {
        let record = CloudKitRecordCodec.record(
            for: CloudValueColor(key: "client", value: "acme corp",
                                 color: "#5856d6", modifiedAt: date(0)),
            recordName: UUID().uuidString)
        #expect(!record.recordID.recordName.contains("client"))
        #expect(!record.recordID.recordName.contains("acme"))
    }

    // MARK: Versioning (promote-only schema)

    @Test func newerRecordVersionRefusesToDecode() throws {
        let record = CloudKitRecordCodec.record(for: sampleSpan)
        record["v"] = CloudKitSchema.currentRecordVersion + 1
        #expect(throws: CloudKitRecordCodec.DecodeError.newerRecordVersion(
            CloudKitSchema.currentRecordVersion + 1)) {
            try CloudKitRecordCodec.span(from: record)
        }
    }

    @Test func wrongRecordTypeRefusesToDecode() throws {
        let record = CloudKitRecordCodec.record(for: sampleSpan)
        #expect(throws: CloudKitRecordCodec.DecodeError.self) {
            try CloudKitRecordCodec.labelSet(from: record)
        }
    }

    // MARK: Re-encoding onto a fetched record

    @Test func applyReencodesOntoAnExistingRecord() throws {
        // The transport re-encodes onto records fetched from the server (a
        // CKRecord carries the change tag that makes a save an update);
        // apply must fully overwrite, including clearing a stale end.
        let span = sampleSpan
        let record = CloudKitRecordCodec.record(for: span)
        let edited = CloudSpan(uuid: span.uuid, start: span.start, end: nil,
                               note: "second rise",
                               labels: [SpanLabel(key: "recipe", value: "focaccia")],
                               modifiedAt: date(1_700_010_000))
        CloudKitRecordCodec.apply(edited, to: record)
        #expect(try CloudKitRecordCodec.span(from: record) == edited)
    }
}
