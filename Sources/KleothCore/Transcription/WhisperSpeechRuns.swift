import Foundation

/// Times on-device transcript entries by Whisper's word alignment, so each one
/// starts and ends where the speaker actually spoke.
///
/// A Whisper segment's own timestamps don't mark speech: consecutive segments
/// abut, the silence after a sentence absorbed into it or into the next one
/// (a silent stretch can even come back as one filler segment that spans it).
/// A two-channel meeting timed that way shows no pause on either channel, so
/// `TranscriptNormalizer` has nothing to split a speaker's turns on. With
/// `wordTimestamps` on, WhisperKit times every word; this cuts one segment's
/// aligned words into runs of continuous speech, a new run at each word that
/// begins after a pause. A run keeps Whisper's own text for its words, so
/// "5%" and "что-то" read as they did in the segment.
///
/// A cut needs a word with a leading space. Languages written without spaces
/// (zh, ja, th, lo, my, yue) come from WhisperKit with none, so a segment in
/// one of them is never cut: it stays one entry, timed by its first word's
/// start and its latest word end.
public enum WhisperSpeechRuns {
    /// One word as WhisperKit aligned it. `text` is `WordTiming.word` as is:
    /// a leading space starts a new word; a token without one ("%", "-то")
    /// continues the word before it.
    public struct Word: Sendable, Equatable {
        public var text: String
        public var start: Double
        public var end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// One segment's aligned words → one entry per run of continuous speech.
    ///
    /// A run ends where the next word starts after the latest end so far and
    /// begins a new word; a pause before a continuation token never cuts a
    /// word in two. A run's text is its words' raw texts concatenated and
    /// cleaned (`WhisperText.clean`); its start is its first word's start, its
    /// end the latest end among its words. A run with no letter or digit in it
    /// (a lone "." aligned into the silence after the audio) is dropped.
    public static func entries(from words: [Word]) -> [ScribeWord] {
        var entries: [ScribeWord] = []
        var text = ""
        var start: Double?
        var end = 0.0

        func flush() {
            defer { text = ""; start = nil }
            guard let start else { return }
            let cleaned = WhisperText.clean(text)
            guard cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            entries.append(ScribeWord(
                text: cleaned,
                start: start,
                end: max(start, end),
                type: "word",
                speakerId: nil,
                logprob: nil
            ))
        }

        for word in words {
            let afterPause = start != nil && word.start > end
            let beginsWord = word.text.first?.isWhitespace ?? false
            if afterPause && beginsWord { flush() }
            if start == nil { start = word.start }
            text += word.text
            // The latest end so far: WhisperKit's long-word truncation moves a
            // word's start and end on their own, so a later word can end first.
            end = max(end, word.end)
        }
        flush()
        return entries
    }
}
