import Testing
import Foundation
@testable import KleothCore

@Suite struct MeetingStoreVariantTests {
    private func makeBaseDir() -> URL {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kleoth-variant-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        return baseDir
    }

    /// Saves a transcript set into `dir` (creating it when needed), simulating
    /// one engine's pipeline run: transcript "\(text)" + optional summary,
    /// metadata carrying the given tier/model/language/cost.
    @discardableResult
    private func saveVariant(
        store: MeetingStore,
        dir: URL,
        text: String,
        title: String = "Meeting 2026-06-05",
        tier: String?,
        model: String? = nil,
        languageCode: String? = nil,
        cost: CostBreakdown? = nil,
        summary: MeetingSummary? = nil
    ) throws -> MeetingMetadata {
        let raw = ScribeResponse(
            transcripts: [
                ScribeChannelTranscript(
                    words: [ScribeWord(text: text, start: 0, end: 1, type: "word")],
                    channelIndex: 0
                )
            ],
            audioDurationSecs: 1,
            languageCode: languageCode ?? "en"
        )
        let transcript = TranscriptNormalizer.normalize(raw)
        let metadata = MeetingMetadata(
            title: title,
            date: "2026-06-05",
            model: model,
            languageCode: languageCode,
            cost: cost,
            transcriptTier: tier
        )
        let markdown = MarkdownRenderer.render(
            summary: summary,
            transcript: transcript,
            metadata: metadata,
            includeTranscript: true
        )
        try store.save(
            in: dir,
            raw: raw,
            transcript: transcript,
            summary: summary,
            summaryMarkdown: summary == nil ? nil : markdown,
            speakerMap: nil,
            metadata: metadata
        )
        return metadata
    }

    private func rootTranscriptText(store: MeetingStore, dir: URL) throws -> String? {
        try store.loadTranscript(in: dir).utterances.first?.text
    }

    /// Archive the on-device set, rerun as cloud, then switch back and forth:
    /// both variants stay intact and meta's tier/model/language/cost swap.
    @Test func archiveActivateRoundTripSwapsArtifactsAndMeta() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)

        try saveVariant(
            store: store, dir: dir, text: "LocalWords",
            tier: TranscriptTier.local, languageCode: "ru",
            cost: CostBreakdown(transcriptionUSD: 0, summaryUSD: 0.01, audioDurationSecs: 60),
            summary: MeetingSummary(tldr: "Local tldr.")
        )
        try store.archiveActiveVariant(in: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))

        // Simulate the cloud rerun writing a fresh root set.
        try saveVariant(
            store: store, dir: dir, text: "CloudWords",
            tier: TranscriptTier.sotaScribe, model: "google/gemini-3-flash-preview",
            languageCode: "rus",
            cost: CostBreakdown(transcriptionUSD: 0.22, summaryUSD: 0.02, audioDurationSecs: 60),
            summary: MeetingSummary(tldr: "Cloud tldr.")
        )
        #expect(store.availableVariantTiers(in: dir) == [TranscriptTier.sotaScribe, TranscriptTier.local])

        try store.activateVariant(TranscriptTier.local, in: dir)
        #expect(try rootTranscriptText(store: store, dir: dir) == "LocalWords")
        var meta = try store.loadMetadata(in: dir)
        #expect(meta.transcriptTier == TranscriptTier.local)
        #expect(meta.model == nil)
        #expect(meta.languageCode == "ru")
        #expect(meta.cost?.transcriptionUSD == 0)
        #expect(meta.cost?.summaryUSD == 0.01)
        #expect(try store.loadSummary(in: dir)?.tldr == "Local tldr.")
        #expect(store.availableVariantTiers(in: dir) == [TranscriptTier.local, TranscriptTier.sotaScribe])

        try store.activateVariant(TranscriptTier.sotaScribe, in: dir)
        #expect(try rootTranscriptText(store: store, dir: dir) == "CloudWords")
        meta = try store.loadMetadata(in: dir)
        #expect(meta.transcriptTier == TranscriptTier.sotaScribe)
        #expect(meta.model == "google/gemini-3-flash-preview")
        #expect(meta.languageCode == "rus")
        #expect(meta.cost?.transcriptionUSD == 0.22)
        #expect(try store.loadSummary(in: dir)?.tldr == "Cloud tldr.")
        // The local set survived the second switch, archived again.
        #expect(store.availableVariantTiers(in: dir) == [TranscriptTier.sotaScribe, TranscriptTier.local])
    }

    /// Activating a variant that has no summary leaves the root without one —
    /// `loadSummary` returns nil and no stale summary.md lingers.
    @Test func activatingSummarylessVariantLeavesNoRootSummary() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)

        try saveVariant(store: store, dir: dir, text: "LocalWords", tier: TranscriptTier.local)
        try store.archiveActiveVariant(in: dir)
        try saveVariant(
            store: store, dir: dir, text: "CloudWords",
            tier: TranscriptTier.sotaScribe,
            summary: MeetingSummary(tldr: "Cloud tldr.")
        )

        try store.activateVariant(TranscriptTier.local, in: dir)
        #expect(try store.loadSummary(in: dir) == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.json").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
        #expect(try rootTranscriptText(store: store, dir: dir) == "LocalWords")
    }

    /// Re-archiving the same tier replaces the previous archive: exactly one
    /// copy per tier, holding the newest content.
    @Test func reArchivingTierReplacesPreviousArchive() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)

        try saveVariant(store: store, dir: dir, text: "FirstRun", tier: TranscriptTier.local)
        try store.archiveActiveVariant(in: dir)
        try saveVariant(store: store, dir: dir, text: "SecondRun", tier: TranscriptTier.local)
        try store.archiveActiveVariant(in: dir)

        let variantsDir = dir.appendingPathComponent("variants", isDirectory: true)
        let subdirs = try FileManager.default.contentsOfDirectory(atPath: variantsDir.path)
        #expect(subdirs == [TranscriptTier.local])
        let archived = variantsDir
            .appendingPathComponent(TranscriptTier.local)
            .appendingPathComponent("transcript.json")
        let raw = try MeetingStore.makeDecoder()
            .decode(ScribeResponse.self, from: Data(contentsOf: archived))
        #expect(TranscriptNormalizer.normalize(raw).utterances.first?.text == "SecondRun")
    }

    /// Renaming a meeting, then switching variants, re-renders the promoted
    /// Markdown with the NEW title — the archived summary.md (whose H1 carries
    /// the title from before the rename) is never trusted.
    @Test func renameThenSwitchRendersNewTitle() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)

        try saveVariant(
            store: store, dir: dir, text: "LocalWords", title: "Old Title",
            tier: TranscriptTier.local, summary: MeetingSummary(tldr: "Local tldr.")
        )
        try store.archiveActiveVariant(in: dir)
        try saveVariant(
            store: store, dir: dir, text: "CloudWords", title: "Old Title",
            tier: TranscriptTier.sotaScribe, summary: MeetingSummary(tldr: "Cloud tldr.")
        )

        try store.renameMeeting(in: dir, to: "Renamed Meeting")
        try store.activateVariant(TranscriptTier.local, in: dir)

        #expect(try store.loadMetadata(in: dir).title == "Renamed Meeting")
        #expect(try rootTranscriptText(store: store, dir: dir) == "LocalWords")
        let markdown = try String(
            contentsOf: dir.appendingPathComponent("summary.md"),
            encoding: .utf8
        )
        #expect(markdown.contains("# Renamed Meeting"))
        #expect(!markdown.contains("Old Title"))
        #expect(markdown.contains("Local tldr."))
    }

    /// A corrupt archived transcript fails the pre-validation and throws BEFORE
    /// anything moves: the active root set, its meta, and the archive layout
    /// are all untouched.
    @Test func activatingCorruptVariantThrowsWithRootUntouched() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)

        try saveVariant(store: store, dir: dir, text: "LocalWords", tier: TranscriptTier.local)
        try store.archiveActiveVariant(in: dir)
        try saveVariant(
            store: store, dir: dir, text: "CloudWords",
            tier: TranscriptTier.sotaScribe,
            summary: MeetingSummary(tldr: "Cloud tldr.")
        )
        let archivedTranscript = dir
            .appendingPathComponent("variants")
            .appendingPathComponent(TranscriptTier.local)
            .appendingPathComponent("transcript.json")
        try Data("not json {".utf8).write(to: archivedTranscript)

        #expect(throws: (any Error).self) {
            try store.activateVariant(TranscriptTier.local, in: dir)
        }
        // The active cloud set survived intact and was never archived away.
        #expect(try rootTranscriptText(store: store, dir: dir) == "CloudWords")
        let meta = try store.loadMetadata(in: dir)
        #expect(meta.transcriptTier == TranscriptTier.sotaScribe)
        #expect(try store.loadSummary(in: dir)?.tldr == "Cloud tldr.")
        let cloudArchive = dir
            .appendingPathComponent("variants")
            .appendingPathComponent(TranscriptTier.sotaScribe)
        #expect(!FileManager.default.fileExists(atPath: cloudArchive.path))
    }

    /// Promoting a summaryless variant into a root that still carries another
    /// tier's summary (a crashed switch left the root without a transcript, so
    /// nothing gets archived) removes the stale summary artifacts instead of
    /// pairing them with the promoted transcript.
    @Test func promotingSummarylessVariantDropsStaleForeignSummary() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)
        let fm = FileManager.default

        try saveVariant(store: store, dir: dir, text: "LocalWords", tier: TranscriptTier.local)
        try store.archiveActiveVariant(in: dir)
        try saveVariant(
            store: store, dir: dir, text: "CloudWords",
            tier: TranscriptTier.sotaScribe,
            summary: MeetingSummary(tldr: "Cloud tldr.")
        )
        // Simulate the crashed switch: the root transcript is gone but the
        // cloud summary artifacts linger.
        try fm.removeItem(at: dir.appendingPathComponent("transcript.json"))

        try store.activateVariant(TranscriptTier.local, in: dir)
        #expect(try rootTranscriptText(store: store, dir: dir) == "LocalWords")
        #expect(try store.loadMetadata(in: dir).transcriptTier == TranscriptTier.local)
        #expect(try store.loadSummary(in: dir) == nil)
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("summary.json").path))
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("summary.md").path))
    }

    /// Legacy folder (no variants/) reports just the active tier; an
    /// untranscribed folder reports none.
    @Test func availableTiersOnLegacyAndUntranscribedFolders() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)

        let legacy = MeetingStore.uniqueMeetingDirectory(in: baseDir)
        try saveVariant(store: store, dir: legacy, text: "Words", tier: TranscriptTier.sotaScribe)
        #expect(store.availableVariantTiers(in: legacy) == [TranscriptTier.sotaScribe])

        // Legacy meta with no tier at all → treated as local.
        let legacyNilTier = baseDir.appendingPathComponent("meeting-legacy-nil-tier", isDirectory: true)
        try saveVariant(store: store, dir: legacyNilTier, text: "Words", tier: nil)
        #expect(store.availableVariantTiers(in: legacyNilTier) == [TranscriptTier.local])

        let untranscribed = baseDir.appendingPathComponent("meeting-untranscribed", isDirectory: true)
        try FileManager.default.createDirectory(at: untranscribed, withIntermediateDirectories: true)
        #expect(store.availableVariantTiers(in: untranscribed) == [])
    }

    /// Activating a missing tier throws without mutating anything; activating
    /// the already-active tier is a clean no-op.
    @Test func activateMissingTierThrowsAndActiveTierNoOps() throws {
        let baseDir = makeBaseDir()
        defer { try? FileManager.default.removeItem(at: baseDir) }
        let store = MeetingStore(baseDir: baseDir)
        let dir = MeetingStore.uniqueMeetingDirectory(in: baseDir)

        try saveVariant(
            store: store, dir: dir, text: "LocalWords",
            tier: TranscriptTier.local,
            summary: MeetingSummary(tldr: "Tldr.")
        )

        #expect(throws: MeetingStoreError.variantNotFound(tier: TranscriptTier.sotaScribe)) {
            try store.activateVariant(TranscriptTier.sotaScribe, in: dir)
        }
        // Nothing moved or was created by the failed activation.
        #expect(try rootTranscriptText(store: store, dir: dir) == "LocalWords")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("variants").path))

        // Same-tier activation: a no-op that leaves every artifact in place.
        try store.activateVariant(TranscriptTier.local, in: dir)
        #expect(try rootTranscriptText(store: store, dir: dir) == "LocalWords")
        #expect(try store.loadSummary(in: dir)?.tldr == "Tldr.")
        #expect(store.availableVariantTiers(in: dir) == [TranscriptTier.local])
    }
}
