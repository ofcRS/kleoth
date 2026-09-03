import Testing
import Foundation
@testable import KleothCore

@Suite struct KeytermsTests {
    @Test func dropsForbiddenCharacters() {
        let sanitized = Keyterms.sanitize([
            "Kleoth",
            "bad<term",
            "bad>term",
            "bad{term",
            "bad}term",
            "bad[term",
            "bad]term",
            "bad\\term",
            "  spaced  ",
            "",
            "   ",
        ])
        #expect(sanitized == ["Kleoth", "spaced"])
    }

    @Test func dropsOverlongAndMultiWordTerms() {
        let overlong = String(repeating: "a", count: Keyterms.maxCharacters + 1)
        let atLimit = String(repeating: "b", count: Keyterms.maxCharacters)
        let sixWords = "one two three four five six"
        let fiveWords = "one two three four five"

        let sanitized = Keyterms.sanitize([overlong, atLimit, sixWords, fiveWords])
        #expect(sanitized == [atLimit, fiveWords])
    }

    @Test func dedupesCaseInsensitivelyKeepingFirstCasing() {
        let sanitized = Keyterms.sanitize(["WhisperKit", "whisperkit", " WHISPERKIT ", "Scribe"])
        #expect(sanitized == ["WhisperKit", "Scribe"])
    }

    @Test func capsAtOneHundred() {
        let many = (1...250).map { "term\($0)" }
        let sanitized = Keyterms.sanitize(many)
        #expect(Keyterms.maxTerms == 100)
        #expect(sanitized.count == 100)
        #expect(sanitized.first == "term1")
        #expect(sanitized.last == "term100", "The cap keeps the first 100 in order.")
    }
}
