import Testing
import Foundation
import KleothCore
@testable import kleoth

/// What `kleoth transcribe` and `kleoth summarize` send from the personal
/// dictionary, and what `kleoth summarize <dir>` records as the meeting's
/// cost. Each test parses the real command line and asks the command itself —
/// no network, no key. Invented terms only.
@Suite struct MeetingVocabularyCLITests {
    /// A dictionary file in a fresh folder, holding `terms` (or none at all).
    private func dictionary(_ terms: [String]?) throws -> (store: PersonalDictionaryStore, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-cli-vocab-\(UUID().uuidString)", isDirectory: true)
        let store = PersonalDictionaryStore(url: dir.appendingPathComponent("dictionary.json"))
        if let terms { try store.save(terms) }
        return (store, { try? FileManager.default.removeItem(at: dir) })
    }

    // MARK: - kleoth transcribe

    @Test func transcribeSendsTheDictionaryAsKeyterms() throws {
        let (store, cleanup) = try dictionary(["Acmeflow", "Зорблатов", "bad<term"])
        defer { cleanup() }
        let command = try Transcribe.parse(["meeting.m4a", "--num-speakers", "2", "--language", "ru"])

        let options = command.scribeOptions(dictionary: store)
        #expect(options.keyterms == ["Acmeflow", "Зорблатов"])
        // The command's own flags still land.
        #expect(options.numSpeakers == 2)
        #expect(options.languageCode == "ru")
        #expect(options.useMultiChannel == false)
        #expect(options.diarize == true)
        #expect(options.modelId == "scribe_v2")
    }

    @Test func transcribeWithNoDictionarySendsNoKeyterms() throws {
        let (store, cleanup) = try dictionary(["Acmeflow"])
        defer { cleanup() }
        let command = try Transcribe.parse(["meeting.m4a", "--multi-channel", "--no-dictionary"])

        let options = command.scribeOptions(dictionary: store)
        #expect(options.keyterms.isEmpty)
        #expect(options.useMultiChannel == true)
    }

    @Test func transcribeWithNoDictionaryFileSendsNoKeyterms() throws {
        let (store, cleanup) = try dictionary(nil)
        defer { cleanup() }
        let options = try Transcribe.parse(["meeting.m4a"]).scribeOptions(dictionary: store)
        #expect(options.keyterms.isEmpty)
    }

    // MARK: - kleoth summarize

    @Test func summarizeUsesTheDictionaryUnlessToldNot() throws {
        let (store, cleanup) = try dictionary(["Acmeflow", "Zorblat"])
        defer { cleanup() }

        // One list for both halves: the Scribe keyterms of fresh audio and the
        // summary's preferred spellings.
        #expect(try Summarize.parse(["meeting.m4a"]).vocabulary(dictionary: store) == ["Acmeflow", "Zorblat"])
        #expect(try Summarize.parse(["meeting-dir", "--no-dictionary"]).vocabulary(dictionary: store).isEmpty)
    }

    // MARK: - kleoth summarize <dir>: the recorded cost

    @Test func resummarizingKeepsTheStoredTranscriptionCost() {
        // A cloud transcription with keyterms cost 1.2× the base rate; a new
        // summary must not rewrite it at the base rate.
        let stored = CostBreakdown(transcriptionUSD: 0.264, summaryUSD: 0.01, audioDurationSecs: 3600)
        let cost = Summarize.resummarizedCost(
            stored: stored, transcriptTier: TranscriptTier.sotaScribe, probedDurationSecs: 3500, summaryUSD: 0.02)
        #expect(cost.transcriptionUSD == 0.264)
        #expect(cost.audioDurationSecs == 3600)
        #expect(cost.summaryUSD == 0.02, "The new summary's cost replaces the old one's.")
    }

    @Test func resummarizingWithoutAStoredCostPricesTheTier() {
        let cloud = Summarize.resummarizedCost(
            stored: nil, transcriptTier: TranscriptTier.sotaScribe, probedDurationSecs: 1800, summaryUSD: 0.02)
        #expect(abs(cloud.transcriptionUSD - TranscriptTier.scribeUSDPerHour / 2) < 1e-12)
        #expect(cloud.audioDurationSecs == 1800)

        let onDevice = Summarize.resummarizedCost(
            stored: nil, transcriptTier: TranscriptTier.local, probedDurationSecs: 1800, summaryUSD: 0)
        #expect(onDevice.transcriptionUSD == 0)
    }
}
