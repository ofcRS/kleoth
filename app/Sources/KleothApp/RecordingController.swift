import Foundation
import SwiftUI
import KleothCore
import KleothCapture

/// A lightweight view-model describing a recently processed meeting,
/// surfaced in the menu bar UI.
public struct RecentMeeting: Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var date: String
    public var directory: URL
    public var costUSD: Double

    public init(
        id: UUID = UUID(),
        title: String,
        date: String,
        directory: URL,
        costUSD: Double = 0
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.directory = directory
        self.costUSD = costUSD
    }
}

/// Owns the `Recorder` and the meeting pipeline, exposing observable
/// recording state to the SwiftUI menu-bar interface.
///
/// The controller deliberately outlives any view: recording state, the
/// capture `Recorder`, and the processing pipeline all live here so a session
/// survives popover dismissal. All mutable state is confined to the main
/// actor; long-running work (`transcribe`, `summarize`) runs on the
/// cooperative pool inside `async` methods and hops back here to publish
/// results.
@MainActor
public final class RecordingController: ObservableObject {
    // MARK: - Published state

    @Published public var isRecording: Bool = false
    @Published public var statusMessage: String = "Idle"
    @Published public var recentMeetings: [RecentMeeting] = []
    @Published public var currentCostUSD: Double = 0
    @Published public var consentAcknowledged: Bool = false

    /// True only while a transcription/summarization pipeline run is in flight.
    @Published public var isProcessing: Bool = false

    // MARK: - Owned collaborators

    /// The capture recorder. Type-erased because `Recorder` requires macOS
    /// 14.4 and this class is unconditionally available; only ever populated
    /// and used inside `if #available(macOS 14.4, *)` blocks.
    private var recorderBox: AnyObject?

    /// Directory of the in-progress recording (created on `start`).
    private var activeRecordingDir: URL?

    /// Credentials and settings are resolved lazily and refreshed from the
    /// Keychain so the user can edit them at runtime via `SettingsView`.
    public private(set) var settings: KleothCore.Settings
    public private(set) var credentials: Credentials

    // MARK: - Init

    public init() {
        self.settings = KleothCore.Settings.load()
        self.credentials = Credentials.resolve()
        // Overlay any user-edited values stored in the Keychain.
        self.credentials = Self.mergeCredentialsFromKeychain(credentials)
        self.settings = Self.mergeSettingsFromKeychain(settings)
        self.consentAcknowledged = (Keychain.get(Keychain.Account.consentAcknowledged) == "true")
        loadRecentMeetings()
    }

    // MARK: - Consent

    /// Records the user's acknowledgement that everyone consents to recording.
    public func acknowledgeConsent() {
        consentAcknowledged = true
        Keychain.set("true", Keychain.Account.consentAcknowledged)
    }

    // MARK: - Settings / credentials refresh

    /// Re-reads credentials and settings (e.g. after the user edits them).
    public func refreshConfiguration() {
        credentials = Self.mergeCredentialsFromKeychain(Credentials.resolve())
        settings = Self.mergeSettingsFromKeychain(KleothCore.Settings.load())
    }

    /// Persists the ElevenLabs API key and updates the in-memory credentials.
    public func updateElevenLabsKey(_ key: String) {
        Keychain.set(key, Keychain.Account.elevenLabsKey)
        credentials.elevenLabsKey = key.isEmpty ? nil : key
    }

    /// Persists the OpenRouter API key and updates the in-memory credentials.
    public func updateOpenRouterKey(_ key: String) {
        Keychain.set(key, Keychain.Account.openRouterKey)
        credentials.openRouterKey = key.isEmpty ? nil : key
    }

    /// Persists the Slack webhook and updates the in-memory settings.
    public func updateSlackWebhook(_ webhook: String) {
        Keychain.set(webhook, Keychain.Account.slackWebhook)
        settings.slackWebhook = webhook.isEmpty ? nil : webhook
    }

    /// Persists the default model and updates the in-memory settings.
    public func updateDefaultModel(_ model: String) {
        guard !model.isEmpty else { return }
        Keychain.set(model, Keychain.Account.defaultModel)
        settings.defaultModel = model
    }

    /// Persists the output directory and updates the in-memory settings.
    public func updateOutputDir(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        Keychain.set(url.path, Keychain.Account.outputDir)
        settings.outputDir = url
    }

    // MARK: - Recording lifecycle

    /// Begins a new recording session.
    ///
    /// Guards on consent and platform availability, then starts the capture
    /// `Recorder`, writing audio into a fresh per-session directory under the
    /// configured output directory. Errors are surfaced into `statusMessage`
    /// rather than thrown, so the UI never crashes.
    public func start() async {
        guard !isRecording else { return }

        guard consentAcknowledged else {
            statusMessage = "Acknowledge the recording consent notice first."
            return
        }

        guard #available(macOS 14.4, *) else {
            statusMessage = "Recording requires macOS 14.4 or later."
            return
        }

        do {
            let dir = try makeSessionDirectory()
            let recorder = Recorder()
            try recorder.start(outputDir: dir)
            recorderBox = recorder
            activeRecordingDir = dir
            isRecording = true
            statusMessage = "Recording…"
        } catch {
            recorderBox = nil
            activeRecordingDir = nil
            isRecording = false
            statusMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    /// Stops the current session and runs the processing pipeline
    /// (transcribe, and summarize when an OpenRouter key is present).
    public func stop() async {
        guard isRecording, #available(macOS 14.4, *) else {
            isRecording = false
            return
        }

        isRecording = false
        statusMessage = "Finalizing recording…"

        guard let recorder = recorderBox as? Recorder, let dir = activeRecordingDir else {
            statusMessage = "No active recording to stop."
            recorderBox = nil
            activeRecordingDir = nil
            return
        }

        // Finalize capture files.
        let audioFileURL: URL
        do {
            try recorder.stop()
            // Prefer a single 2-channel file (mic + system) for multi-channel STT.
            let twoChannel = dir.appendingPathComponent("meeting.m4a")
            audioFileURL = (try? recorder.buildTwoChannelFile(outputURL: twoChannel))
                ?? dir.appendingPathComponent("mic.m4a")
        } catch {
            statusMessage = "Recording stopped with errors: \(error.localizedDescription)"
            recorderBox = nil
            activeRecordingDir = nil
            return
        }

        recorderBox = nil
        activeRecordingDir = nil

        await process(audioFile: audioFileURL, title: defaultMeetingTitle(), useMultiChannel: true)
    }

    /// Transcribes (and optionally summarizes) an existing audio file the user
    /// selected, reusing the same pipeline as live recordings.
    public func transcribeExistingFile(_ url: URL) async {
        let title = url.deletingPathExtension().lastPathComponent
        await process(audioFile: url, title: title.isEmpty ? defaultMeetingTitle() : title, useMultiChannel: false)
    }

    // MARK: - Speaker renaming

    /// Applies a `SpeakerMap` to the transcript stored in `meetingDir`, then
    /// re-renders and re-saves the meeting artifacts in place.
    public func rename(meetingDir: URL, map: SpeakerMap) {
        do {
            let store = MeetingStore(baseDir: meetingDir.deletingLastPathComponent())
            let transcript = try store.loadTranscript(in: meetingDir)
            let summary = try store.loadSummary(in: meetingDir)
            let metadata = loadMetadata(in: meetingDir)

            let renamed = SpeakerMapper.apply(map, to: transcript)
            let markdown = MarkdownRenderer.render(
                summary: summary,
                transcript: renamed,
                metadata: metadata,
                includeTranscript: true
            )

            // Reuse the meeting's existing directory by saving under its name.
            try store.save(
                meetingName: meetingDir.lastPathComponent,
                raw: nil,
                transcript: renamed,
                summary: summary,
                summaryMarkdown: markdown,
                speakerMap: map,
                metadata: metadata
            )
            statusMessage = "Updated speaker names."
        } catch {
            statusMessage = "Could not rename speakers: \(error.localizedDescription)"
        }
    }

    // MARK: - Pipeline

    private func process(audioFile: URL, title: String, useMultiChannel: Bool) async {
        guard let elevenKey = credentials.elevenLabsKey, !elevenKey.isEmpty else {
            statusMessage = "Add your ElevenLabs API key in Settings to transcribe."
            return
        }

        isProcessing = true
        statusMessage = "Transcribing…"

        let transport = URLSessionTransport()
        let scribe = ScribeClient(apiKey: elevenKey, transport: transport)

        // Summarize only when an OpenRouter key is configured.
        var summarizer: Summarizer?
        if let openRouterKey = credentials.openRouterKey, !openRouterKey.isEmpty {
            summarizer = Summarizer(
                client: OpenRouterClient(apiKey: openRouterKey, transport: transport),
                model: settings.defaultModel
            )
        }
        let canSummarize = (summarizer != nil)

        let store = MeetingStore(baseDir: settings.outputDir)
        let pipeline = MeetingPipeline(scribe: scribe, summarizer: summarizer, store: store)

        var options = ScribeOptions()
        options.useMultiChannel = useMultiChannel

        let metadata = MeetingMetadata(
            title: title,
            date: Self.isoDate(),
            participants: [],
            consentAcknowledged: consentAcknowledged,
            model: canSummarize ? settings.defaultModel : nil
        )

        if canSummarize {
            statusMessage = "Transcribing and summarizing…"
        }

        do {
            let result = try await pipeline.run(
                audioFile: audioFile,
                metadata: metadata,
                options: options,
                summarize: canSummarize
            )

            let meeting = RecentMeeting(
                title: title,
                date: metadata.date,
                directory: result.meetingDir,
                costUSD: result.cost.totalUSD
            )
            recentMeetings.insert(meeting, at: 0)
            currentCostUSD += result.cost.totalUSD
            isProcessing = false
            statusMessage = "Saved \"\(title)\" — $\(Self.formatUSD(result.cost.totalUSD))"
        } catch {
            isProcessing = false
            statusMessage = "Processing failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Recent meetings discovery

    /// Scans the output directory for previously saved meetings (each is a
    /// subdirectory containing a `meta.json`) and populates `recentMeetings`.
    public func loadRecentMeetings() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: settings.outputDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            recentMeetings = []
            return
        }

        let meetings: [(RecentMeeting, Date)] = entries.compactMap { dir in
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return nil }
            let metaURL = dir.appendingPathComponent("meta.json")
            guard fm.fileExists(atPath: metaURL.path) else { return nil }

            let metadata = loadMetadata(in: dir)
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let meeting = RecentMeeting(
                title: metadata.title,
                date: metadata.date,
                directory: dir,
                costUSD: metadata.cost?.totalUSD ?? 0
            )
            return (meeting, modified)
        }

        recentMeetings = meetings
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // MARK: - Helpers

    private func loadMetadata(in dir: URL) -> MeetingMetadata {
        let url = dir.appendingPathComponent("meta.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let data = try? Data(contentsOf: url),
           let metadata = try? decoder.decode(MeetingMetadata.self, from: data) {
            return metadata
        }
        // Fall back to a minimal record keyed off the directory name.
        return MeetingMetadata(title: dir.lastPathComponent, date: Self.isoDate())
    }

    private func makeSessionDirectory() throws -> URL {
        let fm = FileManager.default
        let stamp = Self.timestampSlug()
        let dir = settings.outputDir
            .appendingPathComponent("recording-\(stamp)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func defaultMeetingTitle() -> String {
        "Meeting \(Self.isoDate())"
    }

    private static func mergeCredentialsFromKeychain(_ base: Credentials) -> Credentials {
        var merged = base
        if let key = Keychain.get(Keychain.Account.elevenLabsKey), !key.isEmpty {
            merged.elevenLabsKey = key
        }
        if let key = Keychain.get(Keychain.Account.openRouterKey), !key.isEmpty {
            merged.openRouterKey = key
        }
        return merged
    }

    private static func mergeSettingsFromKeychain(_ base: KleothCore.Settings) -> KleothCore.Settings {
        var merged = base
        if let webhook = Keychain.get(Keychain.Account.slackWebhook), !webhook.isEmpty {
            merged.slackWebhook = webhook
        }
        if let model = Keychain.get(Keychain.Account.defaultModel), !model.isEmpty {
            merged.defaultModel = model
        }
        if let path = Keychain.get(Keychain.Account.outputDir), !path.isEmpty {
            merged.outputDir = URL(fileURLWithPath: path, isDirectory: true)
        }
        return merged
    }

    private static func isoDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func timestampSlug() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func formatUSD(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
