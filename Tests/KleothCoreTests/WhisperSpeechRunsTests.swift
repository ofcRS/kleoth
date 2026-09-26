import Testing
@testable import KleothCore

/// One Whisper segment's aligned words → entries that start and end where the
/// speaker spoke. Word texts are WhisperKit's raw `WordTiming.word`: a leading
/// space starts a new word, a token without one continues the word before it.
@Suite struct WhisperSpeechRunsTests {
    private func word(_ text: String, _ start: Double, _ end: Double) -> WhisperSpeechRuns.Word {
        WhisperSpeechRuns.Word(text: text, start: start, end: end)
    }

    @Test func continuousWordsBecomeOneEntryWithWhispersOwnText() {
        // "%" has no leading space: it belongs to "5", so the text must read
        // "5%", not "5 %" as joining the words with spaces would.
        let entries = WhisperSpeechRuns.entries(from: [
            word(" Starter", 21.14, 21.60),
            word(" got", 21.60, 21.80),
            word(" under", 21.80, 22.10),
            word(" 5", 22.10, 22.40),
            word("%", 22.40, 22.70),
            word(" of", 22.70, 22.80),
            word(" signups.", 22.80, 23.30),
        ])

        #expect(entries.count == 1)
        #expect(entries.first?.text == "Starter got under 5% of signups.")
        #expect(entries.first?.start == 21.14)
        #expect(entries.first?.end == 23.30)
        #expect(entries.first?.type == "word")
    }

    @Test func aPauseBeforeANewWordStartsANewEntry() {
        // One segment that runs on over the other speaker's reply: the aligner
        // puts the second sentence 2.5 s after the first one ends.
        let entries = WhisperSpeechRuns.entries(from: [
            word(" I", 23.00, 23.06),
            word(" can", 23.06, 23.24),
            word(" review.", 23.24, 24.92),
            word(" Then", 27.45, 27.66),
            word(" we", 27.66, 27.80),
            word(" ship.", 27.80, 28.06),
        ])

        #expect(entries.map(\.text) == ["I can review.", "Then we ship."])
        #expect(entries.map(\.start) == [23.00, 27.45])
        #expect(entries.map(\.end) == [24.92, 28.06])
    }

    @Test func aPauseInsideAWordDoesNotSplitIt() {
        // "-seat" / "-то" continue the word before them (no leading space), so
        // a gap the aligner left before them is not a place to cut.
        let english = WhisperSpeechRuns.entries(from: [
            word(" three", 82.00, 82.30),
            word("-seat", 82.50, 82.90),
            word(" minimum", 82.90, 83.30),
        ])
        #expect(english.map(\.text) == ["three-seat minimum"])
        #expect(english.first?.end == 83.30)

        let russian = WhisperSpeechRuns.entries(from: [
            word(" Что", 4.00, 4.20),
            word("-то", 4.40, 4.60),
            word(" сломалось.", 4.60, 5.20),
        ])
        #expect(russian.map(\.text) == ["Что-то сломалось."])
    }

    @Test func aWordEndingEarlierThanTheOneBeforeItOpensNoPause() {
        // WhisperKit's long-word truncation moves starts and ends on their own,
        // so a word can end before the previous one did. Speech has not paused
        // until the latest end so far: " ship." starts before " review." ends.
        let entries = WhisperSpeechRuns.entries(from: [
            word(" review", 23.00, 24.90),
            word(" it", 23.60, 23.80),
            word(" ship.", 24.00, 24.50),
        ])

        #expect(entries.map(\.text) == ["review it ship."])
        #expect(entries.first?.end == 24.90)
    }

    @Test func aRunWithNoWordsInItIsDropped() {
        // A lone "." the aligner placed in the padding after the audio ends.
        let entries = WhisperSpeechRuns.entries(from: [
            word(" me.", 38.04, 38.30),
            word(" .", 43.50, 43.54),
        ])

        #expect(entries.map(\.text) == ["me."])
        #expect(entries.first?.end == 38.30)
        #expect(WhisperSpeechRuns.entries(from: [word(" .", 43.50, 43.54)]).isEmpty)
    }

    @Test func noWordsGiveNoEntries() {
        #expect(WhisperSpeechRuns.entries(from: []).isEmpty)
    }
}
