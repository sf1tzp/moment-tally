import Foundation
import Testing
@testable import MomentTallyKit
@testable import MomentTallyCore

/// The Log filter (#51): the `key:value` / free-text parse and the AND
/// matching semantics over a span's labels and note.
@Suite struct LogFilterTests {

    private func span(labels: [SpanLabel] = [], note: String = "") -> TimeSpan {
        TimeSpan(id: 1, start: Date(timeIntervalSince1970: 0), end: nil,
                 note: note, labels: labels)
    }

    // MARK: Parsing

    @Test func parsesPairsAndTerms() {
        let filter = LogFilter.parse("client:a project:website standup")
        #expect(filter.pairs == [LogFilter.Pair(key: "client", value: "a"),
                                 LogFilter.Pair(key: "project", value: "website")])
        #expect(filter.terms == ["standup"])
    }

    @Test func emptyAndWhitespaceParseAsEmpty() {
        #expect(LogFilter.parse("").isEmpty)
        #expect(LogFilter.parse("   ").isEmpty)
        #expect(!LogFilter.parse("x").isEmpty)
    }

    @Test func quotedValuesKeepSpaces() {
        let filter = LogFilter.parse("client:\"acme corp\" \"deep work\"")
        #expect(filter.pairs
            == [LogFilter.Pair(key: "client", value: "acme corp", exact: true)])
        #expect(filter.terms == ["deep work"])
    }

    @Test func whollyQuotedTokenIsATermEvenWithColon() {
        #expect(LogFilter.parse("\"a:b\"").pairs.isEmpty)
        #expect(LogFilter.parse("\"a:b\"").terms == ["a:b"])
    }

    @Test func valueMayContainColons() {
        // Only the first colon splits: url-ish values survive.
        let filter = LogFilter.parse("link:https://x")
        #expect(filter.pairs == [LogFilter.Pair(key: "link", value: "https://x")])
    }

    @Test func pastedSelectorSyntaxParsesLikeBareTokens() {
        // #52's selector punctuation is separator noise here, so a pasted
        // `{client:a, project:website}` means the same as the bare tokens.
        let filter = LogFilter.parse("{client:a, project:website}")
        #expect(filter == LogFilter.parse("client:a project:website"))
        // Quoting still protects the punctuation as content.
        #expect(LogFilter.parse("note:\"a, b\"").pairs
            == [LogFilter.Pair(key: "note", value: "a, b", exact: true)])
    }

    @Test func strayLeadingColonBecomesTerm() {
        let filter = LogFilter.parse(":oops")
        #expect(filter.pairs.isEmpty)
        #expect(filter.terms == ["oops"])
    }

    // MARK: Pair matching

    @Test func barePairValueMatchesAsPrefix() {
        let filter = LogFilter.parse("client:a")
        #expect(filter.matches(span(labels: [SpanLabel(key: "client", value: "a")])))
        #expect(filter.matches(span(labels: [SpanLabel(key: "client", value: "abc")])))
        #expect(!filter.matches(span(labels: [SpanLabel(key: "client", value: "b")])))
        #expect(!filter.matches(span(labels: [SpanLabel(key: "project", value: "a")])))
        // Prefix, not substring: the value must start with the text.
        #expect(!filter.matches(span(labels: [SpanLabel(key: "client", value: "bca")])))
    }

    @Test func typingAPartialValueKeepsMatching() {
        // The list narrows on the way to a full value instead of flashing
        // empty between `repo:` and `repo:server`.
        let target = span(labels: [SpanLabel(key: "repo", value: "server")])
        #expect(LogFilter.parse("repo:s").matches(target))
        #expect(LogFilter.parse("repo:ser").matches(target))
        #expect(LogFilter.parse("repo:server").matches(target))
        #expect(!LogFilter.parse("repo:serverless").matches(target))
    }

    @Test func quotedPairValueMatchesExactly() {
        let filter = LogFilter.parse("client:\"app\"")
        #expect(filter.matches(span(labels: [SpanLabel(key: "client", value: "app")])))
        #expect(!filter.matches(span(labels: [SpanLabel(key: "client", value: "app-server")])))
    }

    @Test func pairsANDTogether() {
        let filter = LogFilter.parse("client:a project:website")
        let both = span(labels: [SpanLabel(key: "client", value: "a"),
                                 SpanLabel(key: "project", value: "website")])
        let one = span(labels: [SpanLabel(key: "client", value: "a")])
        #expect(filter.matches(both))
        #expect(!filter.matches(one))
    }

    @Test func pairMatchingIsCaseInsensitive() {
        let filter = LogFilter.parse("Client:A")
        #expect(filter.matches(span(labels: [SpanLabel(key: "client", value: "a")])))
    }

    @Test func pairIgnoresWhitespaceAroundKeyAndValue() {
        // Traggo keeps a space typed after the colon, so the label's value
        // may be " foo" while its pill reads "repo: foo" — the search
        // `repo:foo` must still find it.
        let spaced = span(labels: [SpanLabel(key: "repo", value: " foo")])
        #expect(LogFilter.parse("repo:foo").matches(spaced))
        // And a quoted spaced search value matches the clean label.
        let clean = span(labels: [SpanLabel(key: "repo", value: "foo")])
        #expect(LogFilter.parse("repo:\" foo\"").matches(clean))
    }

    @Test func emptyValueMatchesAnyValueOfKey() {
        // "client:" = any span carrying the key — also what's briefly parsed
        // while a value is being typed.
        let filter = LogFilter.parse("client:")
        #expect(filter.matches(span(labels: [SpanLabel(key: "client", value: "a")])))
        #expect(filter.matches(span(labels: [SpanLabel(key: "client", value: "")])))
        #expect(!filter.matches(span(labels: [SpanLabel(key: "project", value: "a")])))
    }

    @Test func quotedEmptyValueMatchesOnlyEmpty() {
        // Unlike the bare `client:` match-any, `client:""` pins the value.
        let filter = LogFilter.parse("client:\"\"")
        #expect(filter.matches(span(labels: [SpanLabel(key: "client", value: "")])))
        #expect(!filter.matches(span(labels: [SpanLabel(key: "client", value: "a")])))
    }

    // MARK: Term matching

    @Test func termSearchesKeysValuesAndNote() {
        let target = span(labels: [SpanLabel(key: "client", value: "acme")],
                          note: "quarterly review")
        #expect(LogFilter.parse("cli").matches(target))       // key substring
        #expect(LogFilter.parse("acm").matches(target))       // value substring
        #expect(LogFilter.parse("quarterly").matches(target)) // note substring
        #expect(LogFilter.parse("ACME").matches(target))      // case-insensitive
        #expect(!LogFilter.parse("missing").matches(target))
    }

    @Test func termsANDTogether() {
        let target = span(labels: [SpanLabel(key: "client", value: "acme")],
                          note: "review")
        #expect(LogFilter.parse("acme review").matches(target))
        #expect(!LogFilter.parse("acme missing").matches(target))
    }

    @Test func mixedPairAndTermBothApply() {
        let filter = LogFilter.parse("client:acme review")
        let match = span(labels: [SpanLabel(key: "client", value: "acme")],
                         note: "sprint review")
        let wrongNote = span(labels: [SpanLabel(key: "client", value: "acme")],
                             note: "planning")
        #expect(filter.matches(match))
        #expect(!filter.matches(wrongNote))
    }

    // MARK: Label highlighting (matched pills first)

    @Test func highlightsPairAndTermHits() {
        let client = SpanLabel(key: "client", value: "acme")
        let type = SpanLabel(key: "type", value: "meeting")
        #expect(LogFilter.parse("client:acme").highlights(client))
        #expect(!LogFilter.parse("client:acme").highlights(type))
        #expect(LogFilter.parse("meet").highlights(type))     // term in value
        #expect(LogFilter.parse("cli").highlights(client))    // term in key
        #expect(!LogFilter.parse("").highlights(client))      // empty filter: nothing
    }

    @Test func highlightedFirstMovesHitsToFrontStably() {
        let labels = [SpanLabel(key: "a", value: "1"),
                      SpanLabel(key: "b", value: "2"),
                      SpanLabel(key: "c", value: "3"),
                      SpanLabel(key: "b", value: "4")]
        #expect(LogFilter.parse("b:").highlightedFirst(labels)
            == [labels[1], labels[3], labels[0], labels[2]])
        // No filter, or no hits: order untouched.
        #expect(LogFilter.parse("").highlightedFirst(labels) == labels)
        #expect(LogFilter.parse("z:").highlightedFirst(labels) == labels)
    }

    @Test func emptyFilterMatchesEverything() {
        #expect(LogFilter.parse("").matches(span()))
        #expect(LogFilter.parse("").matches(span(labels: [SpanLabel(key: "a", value: "b")])))
    }
}
