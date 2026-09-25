import Foundation

/// Converts a raw `ScribeResponse` (single- or multi-channel) into a
/// normalized, speaker-grouped `Transcript`.
public enum TranscriptNormalizer {
    /// Maximum silence (in seconds) tolerated within a single utterance.
    /// A larger gap between consecutive words starts a new utterance.
    private static let maxGap: Double = 1.5

    /// Groups Scribe words into utterances per speaker / channel.
    ///
    /// `tier` is the transcript's `TranscriptTier`. An on-device
    /// (`local-whisper`) multi-channel transcript also starts a new utterance
    /// where another channel said something inside a speaker's pause: each
    /// channel is transcribed on its own, and a short reply ("Sure.") leaves
    /// the other channel a pause shorter than `maxGap`, which would glue the
    /// turns on either side of it together. Any other tier (Scribe) groups
    /// exactly as before.
    public static func normalize(_ response: ScribeResponse, tier: String? = nil) -> Transcript {
        let utterances: [Utterance]

        if let channels = response.transcripts {
            // Multi-channel: each channel maps to a single speaker derived
            // from its channel index (falling back to its array position).
            let channelWords = channels.enumerated().map { index, channel in
                (speakerId: "speaker_\(channel.channelIndex ?? index)",
                 words: (channel.words ?? []).filter { isSpeechToken($0) })
            }
            let splitsTurns = tier == TranscriptTier.local
            var collected: [Utterance] = []
            for (index, channel) in channelWords.enumerated() {
                let others = splitsTurns
                    ? channelWords.indices.filter { $0 != index }.flatMap { channelWords[$0].words }
                    : []
                collected.append(contentsOf: group(channel.words, speakerId: channel.speakerId, others: others))
            }
            // Sort across channels by start time; nil starts sort last.
            // Use the collection index as a tiebreaker so equal/nil starts
            // keep a deterministic (channel) order regardless of the sort's
            // stability.
            utterances = collected.enumerated()
                .sorted { startOrder($0, $1) }
                .map(\.element)
        } else {
            // Single-channel: group consecutive words sharing a speaker id.
            let words = response.words ?? []
            utterances = groupBySpeaker(words)
        }

        return Transcript(
            utterances: utterances,
            languageCode: response.languageCode,
            durationSecs: response.audioDurationSecs
        )
    }

    // MARK: - Single-channel grouping

    /// Groups single-channel words into utterances, breaking on a speaker
    /// change or a silence gap greater than `maxGap`. `spacing` tokens are
    /// ignored for grouping (their text is not emitted); a missing
    /// `speaker_id` is treated as `"speaker_0"`.
    private static func groupBySpeaker(_ words: [ScribeWord]) -> [Utterance] {
        var utterances: [Utterance] = []
        var current: [ScribeWord] = []
        var currentSpeaker: String? = nil

        func flush() {
            guard !current.isEmpty else { return }
            utterances.append(makeUtterance(current, speakerId: currentSpeaker ?? "speaker_0"))
            current = []
        }

        for word in words {
            // Skip spacing tokens entirely when forming utterances.
            guard isSpeechToken(word) else { continue }

            let speaker = word.speakerId ?? "speaker_0"
            let breakOnSpeaker = currentSpeaker != nil && speaker != currentSpeaker
            let breakOnGap = exceedsGap(previous: current.last, next: word)

            if breakOnSpeaker || breakOnGap {
                flush()
            }
            currentSpeaker = speaker
            current.append(word)
        }
        flush()
        return utterances
    }

    // MARK: - Multi-channel grouping

    /// Groups a single channel's (already speech-filtered) words into
    /// utterances for a fixed speaker id, breaking on a silence gap greater
    /// than `maxGap` or where one of `others` (the other channels' words;
    /// empty unless on-device) falls entirely inside the pause.
    private static func group(_ words: [ScribeWord], speakerId: String, others: [ScribeWord]) -> [Utterance] {
        var utterances: [Utterance] = []
        var current: [ScribeWord] = []

        func flush() {
            guard !current.isEmpty else { return }
            utterances.append(makeUtterance(current, speakerId: speakerId))
            current = []
        }

        for word in words {
            if exceedsGap(previous: current.last, next: word)
                || spokeInPause(previous: current.last, next: word, others: others) {
                flush()
            }
            current.append(word)
        }
        flush()
        return utterances
    }

    // MARK: - Helpers

    /// A token contributes to an utterance when it is a spoken word or an
    /// audio event; `spacing` (and any unknown/nil type other than these)
    /// is excluded. `nil` type is treated as a word so callers that omit
    /// `type` still produce content.
    private static func isSpeechToken(_ word: ScribeWord) -> Bool {
        switch word.type {
        case "word", "audio_event", nil:
            return true
        default:
            return false
        }
    }

    /// True when the silence between `previous.end` and `next.start`
    /// exceeds `maxGap`. Missing timestamps never force a break.
    private static func exceedsGap(previous: ScribeWord?, next: ScribeWord) -> Bool {
        guard let prevEnd = previous?.end, let nextStart = next.start else { return false }
        return (nextStart - prevEnd) > maxGap
    }

    /// True when one of `others` starts at or after `previous.end` and ends
    /// at or before `next.start`: another speaker said something while this
    /// one paused. Speech that only overlaps the pause (crosstalk, the mic
    /// picking up the other side) doesn't count. Missing timestamps never
    /// force a break.
    ///
    /// A linear scan per pause, so O(n·m) for a channel of n entries against
    /// m on the other side. That's fine for what reaches it: on-device
    /// speech-run entries, about 35 a minute per channel. It isn't meant for
    /// per-word input, and Scribe transcripts never get here.
    private static func spokeInPause(previous: ScribeWord?, next: ScribeWord, others: [ScribeWord]) -> Bool {
        guard let pauseStart = previous?.end, let pauseEnd = next.start, pauseEnd > pauseStart else {
            return false
        }
        return others.contains { word in
            guard let start = word.start, let end = word.end else { return false }
            return start >= pauseStart && end <= pauseEnd
        }
    }

    /// Builds an utterance from a non-empty run of speech tokens: each token's
    /// text is cleaned of Whisper special tokens (`<|…|>`) and trimmed/collapsed
    /// via `WhisperText.clean`, tokens that become empty are dropped, and the
    /// survivors are joined by single spaces; start/end come from the
    /// first/last token. Cleaning here means re-normalizing an existing
    /// transcript (e.g. `loadTranscript`) retroactively scrubs legacy local
    /// meetings whose stored text still carries the tokens.
    private static func makeUtterance(_ words: [ScribeWord], speakerId: String) -> Utterance {
        let text = words
            .map { WhisperText.clean($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return Utterance(
            speakerId: speakerId,
            start: words.first?.start,
            end: words.last?.end,
            text: text
        )
    }

    /// Sort predicate ordering `(index, utterance)` pairs by `start`
    /// ascending, with `nil` starts placed last. The collection `index`
    /// is the tiebreaker, giving a total, deterministic order.
    private static func startOrder(
        _ lhs: (offset: Int, element: Utterance),
        _ rhs: (offset: Int, element: Utterance)
    ) -> Bool {
        switch (lhs.element.start, rhs.element.start) {
        case let (l?, r?):
            return l != r ? l < r : lhs.offset < rhs.offset
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.offset < rhs.offset
        }
    }
}
