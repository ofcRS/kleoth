import Foundation

/// Persists meeting artifacts (raw response, transcript, summary, markdown,
/// speaker map, metadata) to a per-meeting directory under `baseDir`.
public struct MeetingStore {
    public let baseDir: URL

    public init(baseDir: URL) {
        self.baseDir = baseDir
    }

    /// Saves all artifacts for a meeting into an explicit directory and returns
    /// it. The directory is created if needed; existing artifacts in it are
    /// overwritten (used both for fresh saves and for in-place re-saves such as
    /// speaker renaming).
    ///
    /// Layout (inside `dir`):
    /// - `transcript.json` — raw `ScribeResponse` (only when non-nil)
    /// - `summary.json`    — `MeetingSummary` (only when non-nil)
    /// - `speakers.json`   — `SpeakerMap` (only when non-nil)
    /// - `meta.json`       — `MeetingMetadata` (always)
    /// - `transcript.md`   — the normalized transcript as "Name: text" lines
    /// - `summary.md`      — `summaryMarkdown` (only when non-nil)
    ///
    /// For live recordings `dir` is the same folder the audio (`mic.m4a` /
    /// `system.m4a` / `meeting.m4a`) was captured into, so one meeting is one
    /// self-contained folder. Use ``uniqueMeetingDirectory(in:date:)`` to derive
    /// a fresh, collision-free `dir` when there is no pre-existing folder.
    ///
    /// JSON is encoded pretty-printed, with sorted keys and snake_case keys so
    /// it round-trips with the read side and the rest of the toolchain.
    @discardableResult
    public func save(
        in dir: URL,
        raw: ScribeResponse?,
        transcript: Transcript,
        summary: MeetingSummary?,
        summaryMarkdown: String?,
        speakerMap: SpeakerMap?,
        metadata: MeetingMetadata
    ) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = Self.makeEncoder()

        // transcript.json holds the raw Scribe response (only when present).
        if let raw {
            let data = try encoder.encode(raw)
            try data.write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        }

        if let summary {
            let data = try encoder.encode(summary)
            try data.write(to: dir.appendingPathComponent("summary.json"), options: .atomic)
        }

        if let speakerMap {
            let data = try encoder.encode(speakerMap)
            try data.write(to: dir.appendingPathComponent("speakers.json"), options: .atomic)
        }

        // meta.json is always written.
        let metaData = try encoder.encode(metadata)
        try metaData.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)

        // transcript.md is the human-readable rendering of the utterances.
        let transcriptText = Self.renderTranscriptLines(transcript)
        try Data(transcriptText.utf8).write(
            to: dir.appendingPathComponent("transcript.md"),
            options: .atomic
        )

        if let summaryMarkdown {
            try Data(summaryMarkdown.utf8).write(
                to: dir.appendingPathComponent("summary.md"),
                options: .atomic
            )
        }

        return dir
    }

    /// Loads the normalized transcript stored in `dir`, with speaker names
    /// applied from `speakers.json` when present.
    ///
    /// `transcript.json` is the raw `ScribeResponse`, so it is normalized back
    /// into a `Transcript` (yielding bare `speaker_0` / `speaker_1` ids). This
    /// is the single chokepoint every reader goes through, so applying any saved
    /// `SpeakerMap` here is what keeps "You"/"Them" (and renamed) labels intact
    /// on re-summarize and redisplay — not just on first processing.
    public func loadTranscript(in dir: URL) throws -> Transcript {
        let decoder = Self.makeDecoder()
        let rawURL = dir.appendingPathComponent("transcript.json")
        let data = try Data(contentsOf: rawURL)
        let raw = try decoder.decode(ScribeResponse.self, from: data)
        let transcript = TranscriptNormalizer.normalize(raw)

        if let map = loadSpeakerMap(in: dir) {
            return SpeakerMapper.apply(map, to: transcript)
        }
        return transcript
    }

    /// Loads the `SpeakerMap` stored in `dir/speakers.json`, if any.
    public func loadSpeakerMap(in dir: URL) -> SpeakerMap? {
        let url = dir.appendingPathComponent("speakers.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.makeDecoder().decode(SpeakerMap.self, from: data)
    }

    /// Loads the summary stored in `dir`, if any.
    public func loadSummary(in dir: URL) throws -> MeetingSummary? {
        let url = dir.appendingPathComponent("summary.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.makeDecoder().decode(MeetingSummary.self, from: data)
    }

    /// Loads the metadata stored in `dir/meta.json`.
    public func loadMetadata(in dir: URL) throws -> MeetingMetadata {
        let data = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        return try Self.makeDecoder().decode(MeetingMetadata.self, from: data)
    }

    /// Renames a meeting in place: rewrites `meta.json` with the new title and,
    /// when the meeting has a transcript, re-renders the Markdown artifacts
    /// (whose headers carry the title) so the user-owned files match. Every
    /// other artifact — raw transcript, summary JSON, speaker map — is untouched.
    /// The title is the caller's responsibility to validate (trim / non-empty).
    @discardableResult
    public func renameMeeting(in dir: URL, to title: String) throws -> MeetingMetadata {
        var metadata = try loadMetadata(in: dir)
        metadata.title = title

        if let transcript = try? loadTranscript(in: dir) {
            let summary = (try? loadSummary(in: dir)) ?? nil
            let markdown = MarkdownRenderer.render(
                summary: summary,
                transcript: transcript,
                metadata: metadata,
                includeTranscript: true
            )
            try save(
                in: dir,
                raw: nil,
                transcript: transcript,
                summary: summary,
                // Mirror the pipeline guard: never write a summary.md for a
                // transcript-only meeting (summarization failed / no key), or
                // other readers would treat the empty file as a real summary.
                summaryMarkdown: summary == nil ? nil : markdown,
                speakerMap: nil,
                metadata: metadata
            )
        } else {
            // No transcript yet (e.g. processing failed): persist just the title.
            let data = try Self.makeEncoder().encode(metadata)
            try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        }
        return metadata
    }

    // MARK: - Transcript variants

    /// The root artifacts that belong to one transcript variant. Everything else
    /// in a meeting folder — audio, `speakers.json`, `meta.json` — is shared
    /// across tiers and never moves.
    private static let variantArtifacts = [
        "transcript.json", "transcript.md", "summary.json", "summary.md",
    ]

    private func variantsDir(in dir: URL) -> URL {
        dir.appendingPathComponent("variants", isDirectory: true)
    }

    private func variantDir(for tier: String, in dir: URL) -> URL {
        variantsDir(in: dir).appendingPathComponent(tier, isDirectory: true)
    }

    /// Moves the active (root) transcript set into `variants/<tier>/`, where
    /// `<tier>` is the tier recorded in `meta.json` (`nil` → local). A no-op when
    /// there is no root `transcript.json`. Re-archiving a tier replaces its
    /// previous archive, so there is at most one copy per tier. The files are
    /// *moved*, not copied — which also removes today's stale-summary hazard
    /// (`save` never deletes an old `summary.json` when a rerun's summary fails).
    public func archiveActiveVariant(in dir: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) else {
            return
        }
        let metadata = try? loadMetadata(in: dir)
        let tier = metadata?.transcriptTier ?? TranscriptTier.local
        let target = variantDir(for: tier, in: dir)
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in Self.variantArtifacts {
            let source = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.moveItem(at: source, to: target.appendingPathComponent(name))
        }
        let info = TranscriptVariantInfo(
            transcriptTier: tier,
            model: metadata?.model,
            languageCode: metadata?.languageCode,
            cost: metadata?.cost
        )
        let data = try Self.makeEncoder().encode(info)
        try data.write(to: target.appendingPathComponent("variant.json"), options: .atomic)
    }

    /// Every transcript tier available for this meeting: the active (root) one
    /// plus each archived `variants/<tier>/` holding a `transcript.json`. The
    /// filesystem is the source of truth — no meta.json key tracks variants.
    /// The active tier (when any) comes first.
    public func availableVariantTiers(in dir: URL) -> [String] {
        let fm = FileManager.default
        var tiers: [String] = []
        if fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) {
            tiers.append((try? loadMetadata(in: dir))?.transcriptTier ?? TranscriptTier.local)
        }
        if let subdirs = try? fm.contentsOfDirectory(
            at: variantsDir(in: dir),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for subdir in subdirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let tier = subdir.lastPathComponent
                guard !tiers.contains(tier),
                      fm.fileExists(atPath: subdir.appendingPathComponent("transcript.json").path)
                else { continue }
                tiers.append(tier)
            }
        }
        return tiers
    }

    /// Promotes an archived transcript variant to be the active (root) set,
    /// archiving the current root set under its own tier first. The root
    /// Markdown is re-rendered from the promoted JSON + the *current* meta title
    /// + `speakers.json` (never trusted from the archive, whose `.md` may carry
    /// a title from before a rename), and the transcript-derived meta fields
    /// (tier/model/language/cost) are swapped in from the variant's sidecar.
    /// Activating the already-active tier is a no-op. Everything that can
    /// ordinarily fail (decoding meta and the variant's transcript) is
    /// pre-validated BEFORE any file moves, so a corrupt variant can never
    /// strand the root mid-swap; the remaining failure window is a crash or
    /// disk-full during the moves/save themselves, ordered so a crash leaves a
    /// re-runnable state: archive → promote → render + meta.
    public func activateVariant(_ tier: String, in dir: URL) throws {
        let fm = FileManager.default
        let source = variantDir(for: tier, in: dir)
        let hasActive = fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
        if hasActive,
           ((try? loadMetadata(in: dir))?.transcriptTier ?? TranscriptTier.local) == tier {
            return
        }
        guard fm.fileExists(atPath: source.appendingPathComponent("transcript.json").path) else {
            throw MeetingStoreError.variantNotFound(tier: tier)
        }
        guard fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) else {
            throw MeetingStoreError.metadataMissing
        }

        // 1. Pre-validate: decode the current meta, the variant's transcript,
        //    and its sidecar up front, before anything on disk is touched.
        var metadata = try loadMetadata(in: dir)
        let rawData = try Data(contentsOf: source.appendingPathComponent("transcript.json"))
        let raw = try Self.makeDecoder().decode(ScribeResponse.self, from: rawData)
        let info: TranscriptVariantInfo
        if let data = try? Data(contentsOf: source.appendingPathComponent("variant.json")),
           let decoded = try? Self.makeDecoder().decode(TranscriptVariantInfo.self, from: data) {
            info = decoded
        } else {
            info = TranscriptVariantInfo(transcriptTier: tier)
        }
        let variantHasSummary = fm.fileExists(atPath: source.appendingPathComponent("summary.json").path)

        // 2. Archive the current root set under its own tier (no-op when the
        //    root is already empty, e.g. recovering from a crashed switch).
        try archiveActiveVariant(in: dir)

        // 3. Promote the variant's JSON to root. The archived `.md` files are
        //    deliberately left behind (and removed with the emptied dir below):
        //    they are re-rendered fresh in step 4.
        for name in ["transcript.json", "summary.json"] {
            let promoted = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: promoted.path) else { continue }
            let destination = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: promoted, to: destination)
        }
        // A summaryless variant must not inherit another tier's leftover
        // summary (possible when a crashed switch left the root without a
        // transcript, so the archive above no-oped): drop the stale artifacts.
        if !variantHasSummary {
            for name in ["summary.json", "summary.md"] {
                let stale = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: stale.path) {
                    try fm.removeItem(at: stale)
                }
            }
        }

        // 4. Swap the transcript-derived meta fields from the variant's sidecar
        //    and re-render the root Markdown; one `save` writes transcript.md,
        //    summary.md (only when a summary exists), and meta.json atomically.
        metadata.transcriptTier = info.transcriptTier ?? tier
        metadata.model = info.model
        metadata.languageCode = info.languageCode
        metadata.cost = info.cost

        var transcript = TranscriptNormalizer.normalize(raw)
        if let map = loadSpeakerMap(in: dir) {
            transcript = SpeakerMapper.apply(map, to: transcript)
        }
        let summary = (try? loadSummary(in: dir)) ?? nil
        let markdown = MarkdownRenderer.render(
            summary: summary,
            transcript: transcript,
            metadata: metadata,
            includeTranscript: true
        )
        try save(
            in: dir,
            raw: nil,
            transcript: transcript,
            summary: summary,
            summaryMarkdown: summary == nil ? nil : markdown,
            speakerMap: nil,
            metadata: metadata
        )

        // 5. Drop the emptied variant dir (and `variants/` itself when empty).
        try? fm.removeItem(at: source)
        if let remaining = try? fm.contentsOfDirectory(atPath: variantsDir(in: dir).path),
           remaining.isEmpty {
            try? fm.removeItem(at: variantsDir(in: dir))
        }
    }

    /// Reverts a meeting to "Untranscribed": removes the four root transcript
    /// artifacts and the entire `variants/` archive, keeping the audio files and
    /// `speakers.json` (so a rename like You→Anna survives re-transcription —
    /// the pipeline re-applies the map and `writeDefaultSpeakerMapIfNeeded`
    /// never clobbers an existing one). `meta.json` is KEPT, with its
    /// transcript-derived fields (tier/model/language/cost) stripped while the
    /// identity fields (title/date/startedAt/participants/consent) survive, so
    /// the title outlives a re-transcription. Removals go to the Trash by
    /// default (recoverable, matching row deletes); pass `trash: false` to
    /// delete outright. Idempotent — a second call is a clean no-op.
    public func removeTranscription(in dir: URL, trash: Bool = true) throws {
        let fm = FileManager.default
        var doomed = Self.variantArtifacts.map { dir.appendingPathComponent($0) }
        doomed.append(variantsDir(in: dir))
        for url in doomed where fm.fileExists(atPath: url.path) {
            if trash {
                try fm.trashItem(at: url, resultingItemURL: nil)
            } else {
                try fm.removeItem(at: url)
            }
        }

        let metaURL = dir.appendingPathComponent("meta.json")
        guard fm.fileExists(atPath: metaURL.path) else { return }
        var metadata = try loadMetadata(in: dir)
        metadata.transcriptTier = nil
        metadata.model = nil
        metadata.languageCode = nil
        metadata.cost = nil
        let data = try Self.makeEncoder().encode(metadata)
        try data.write(to: metaURL, options: .atomic)
    }

    // MARK: - Helpers

    /// A unique, sortable meeting directory under `baseDir`, named
    /// `meeting-yyyy-MM-dd-HHmmss`. If that already exists (e.g. two recordings
    /// started within the same second), `-2`, `-3`, … is appended. The directory
    /// is NOT created here — `save(in:)` creates it on write.
    ///
    /// This replaces the old "slug of the meeting title" naming, which was
    /// date-only for live recordings and therefore overwrote any earlier meeting
    /// from the same day. The human title still lives in `meta.json`.
    public static func uniqueMeetingDirectory(in baseDir: URL, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = "meeting-\(formatter.string(from: date))"

        let fm = FileManager.default
        var candidate = baseDir.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = baseDir.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    /// Renders transcript utterances as "Name: text" lines (one per line),
    /// preferring the resolved speaker name and falling back to the speaker id.
    static func renderTranscriptLines(_ transcript: Transcript) -> String {
        transcript.utterances.map { utterance in
            let name = utterance.speakerName ?? utterance.speakerId
            return "\(name): \(utterance.text)"
        }
        .joined(separator: "\n")
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// Sidecar (`variants/<tier>/variant.json`) carrying the transcript-derived
/// `meta.json` fields that swap when a variant is (de)activated. Keys are
/// acronym-free so they round-trip under the snake_case strategies; `cost`
/// reuses `CostBreakdown`'s explicit CodingKeys.
public struct TranscriptVariantInfo: Codable, Sendable {
    public var transcriptTier: String?
    public var model: String?
    public var languageCode: String?
    public var cost: CostBreakdown?

    public init(
        transcriptTier: String?,
        model: String? = nil,
        languageCode: String? = nil,
        cost: CostBreakdown? = nil
    ) {
        self.transcriptTier = transcriptTier
        self.model = model
        self.languageCode = languageCode
        self.cost = cost
    }
}

/// Errors thrown by `MeetingStore`'s variant operations.
public enum MeetingStoreError: Error, LocalizedError, Equatable {
    /// `activateVariant` was asked for a tier with no archived transcript.
    case variantNotFound(tier: String)
    /// The meeting has no `meta.json` to carry the swapped variant fields.
    case metadataMissing

    public var errorDescription: String? {
        switch self {
        case .variantNotFound(let tier):
            return "No saved \(TranscriptTier.label(tier)) transcript exists for this meeting."
        case .metadataMissing:
            return "The meeting has no metadata file to update."
        }
    }
}
