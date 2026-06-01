import Foundation
import Darwin
import AppKit
import EventKit
import SwiftUI
import os
import KleothCore
import KleothCapture

/// A lightweight view-model describing a recently processed meeting,
/// surfaced in the menu bar UI.
public struct RecentMeeting: Identifiable, Sendable, Hashable {
    /// Stable identity = the meeting folder path, so selection survives the
    /// list being re-scanned (the directory watcher reloads on every change).
    public var id: String { directory.path }
    public var title: String
    public var date: String
    /// When the meeting started (parsed from `meta.json`), used for sort order
    /// and for showing a time, not just a day. `nil` for legacy meetings.
    public var startedAt: Date?
    public var directory: URL
    public var costUSD: Double
    /// Audio length in seconds, when known (from the cost breakdown).
    public var durationSecs: Double?
    /// Transcription quality tier (see `TranscriptTier`); `nil` for legacy meetings.
    public var transcriptTier: String?
    /// False for folders that hold only raw audio (no `meta.json`/transcript yet)
    /// — e.g. a recording whose processing failed. These can be transcribed in place.
    public var isProcessed: Bool

    public init(
        title: String,
        date: String,
        startedAt: Date? = nil,
        directory: URL,
        costUSD: Double = 0,
        durationSecs: Double? = nil,
        transcriptTier: String? = nil,
        isProcessed: Bool = true
    ) {
        self.title = title
        self.date = date
        self.startedAt = startedAt
        self.directory = directory
        self.costUSD = costUSD
        self.durationSecs = durationSecs
        self.transcriptTier = transcriptTier
        self.isProcessed = isProcessed
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
    /// The single app-lifetime controller, so out-of-view entry points
    /// (App Intents, the `kleoth://` URL scheme, the global hotkey) can drive
    /// recording without a view. Set in `init`.
    public static var shared: RecordingController?

    // MARK: - Published state

    @Published public var isRecording: Bool = false
    @Published public var statusMessage: String = "Idle"
    @Published public var recentMeetings: [RecentMeeting] = []

    /// Set by the popover to deep-link the History window to a specific meeting.
    @Published public var selectedMeetingID: RecentMeeting.ID?
    @Published public var currentCostUSD: Double = 0
    @Published public var consentAcknowledged: Bool = false

    /// True only while a transcription/summarization pipeline run is in flight.
    @Published public var isProcessing: Bool = false

    /// Whether Kleoth has full calendar access, enabling meetings to be named
    /// from the overlapping calendar event. Opt-in (see `requestCalendarAccess`).
    @Published public var calendarAuthorized: Bool = false

    /// Fractional progress (0…1) while the on-device transcription model is
    /// downloading at launch; `nil` when idle or already available.
    @Published public var modelDownloadProgress: Double?

    // MARK: - Owned collaborators

    /// The capture recorder. Type-erased because `Recorder` requires macOS
    /// 14.4 and this class is unconditionally available; only ever populated
    /// and used inside `if #available(macOS 14.4, *)` blocks.
    private var recorderBox: AnyObject?

    /// Directory of the in-progress recording (created on `start`).
    private var activeRecordingDir: URL?

    /// Wall-clock time the in-progress recording began (for `startedAt`).
    private var activeRecordingStartedAt: Date?

    /// Watches the output directory so externally-created meetings (the CLI, a
    /// second instance) and our own saves keep `recentMeetings` current without
    /// relying on view lifecycle. See `startWatchingOutputDir()`.
    private var outputDirWatcher: DispatchSourceFileSystemObject?

    private let log = Logger(subsystem: "dev.kleoth", category: "RecordingController")

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
        startWatchingOutputDir()
        self.calendarAuthorized = (EKEventStore.authorizationStatus(for: .event) == .fullAccess)
        Self.shared = self
        // Fetch the on-device transcription model in the background so a meeting
        // never waits on (or times out during) a ~600 MB first-run download.
        Task { await prewarmTranscriptionModel() }
    }

    // MARK: - Calendar auto-naming (opt-in)

    /// Requests full calendar access so meetings can be named from the calendar
    /// event you're in. Triggered explicitly from Settings — never automatically.
    public func requestCalendarAccess() async {
        let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        calendarAuthorized = granted
        statusMessage = granted
            ? "Calendar access granted — meetings will be named from your events."
            : "Calendar access was not granted."
    }

    /// The title + attendees of the calendar event overlapping `date`, when
    /// calendar access is granted and a matching event exists.
    private func calendarMeetingInfo(at date: Date) -> (title: String, participants: [String])? {
        guard calendarAuthorized else { return nil }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-300),
            end: date.addingTimeInterval(300),
            calendars: nil
        )
        let events = store.events(matching: predicate)
        let spanning = events.first { $0.startDate <= date && $0.endDate >= date }
        let chosen = spanning ?? events.min {
            abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date))
        }
        guard let event = chosen, let title = event.title, !title.isEmpty else { return nil }
        let participants = (event.attendees ?? []).compactMap { $0.name }
        return (title, participants)
    }

    // MARK: - External commands (App Intents / URL scheme / global hotkey)

    /// Verbs that external entry points can dispatch. Raw values double as the
    /// `kleoth://<verb>` URL hosts.
    public enum Command: String, Sendable {
        case record
        case stop
        case toggle
        case summarizeLatest = "summarize-latest"
        case slackLatest = "slack-latest"
    }

    /// Single dispatch point shared by every external surface, so they all run
    /// the exact same code path.
    public func handle(_ command: Command) {
        switch command {
        case .record:
            Task { await start() }
        case .stop:
            Task { await stop() }
        case .toggle:
            Task { if isRecording { await stop() } else { await start() } }
        case .summarizeLatest:
            Task { await summarizeLatestMeeting() }
        case .slackLatest:
            Task { await postLatestToSlack() }
        }
    }

    /// Summarizes the most recent meeting in place using the configured
    /// OpenRouter model. (For the free path, use the `summarize-meeting` skill.)
    public func summarizeLatestMeeting() async {
        guard let latest = recentMeetings.first else {
            statusMessage = "No meeting to summarize yet."
            return
        }
        guard let key = credentials.openRouterKey, !key.isEmpty else {
            statusMessage = "Add an OpenRouter key in Settings to summarize."
            return
        }

        isProcessing = true
        statusMessage = "Summarizing latest meeting…"
        let dir = latest.directory
        let store = MeetingStore(baseDir: dir.deletingLastPathComponent())
        do {
            let transcript = try store.loadTranscript(in: dir)
            var meta = loadMetadata(in: dir)
            meta.model = settings.defaultModel

            let summarizer = Summarizer(
                client: OpenRouterClient(apiKey: key, transport: URLSessionTransport()),
                model: settings.defaultModel
            )
            let (summary, summaryUSD) = try await summarizer.summarize(transcript: transcript, metadata: meta)

            // Adopt the model-generated title for auto-named meetings only (keep
            // calendar/user titles), mirroring MeetingPipeline.run and the CLI.
            if let generated = summary.title?.trimmingCharacters(in: .whitespacesAndNewlines),
               !generated.isEmpty, MeetingMetadata.isPlaceholderTitle(meta.title) {
                meta.title = generated
            }

            let previous = meta.cost ?? CostBreakdown()
            meta.cost = CostBreakdown(
                transcriptionUSD: previous.transcriptionUSD,
                summaryUSD: summaryUSD,
                audioDurationSecs: previous.audioDurationSecs
            )
            let markdown = MarkdownRenderer.render(
                summary: summary,
                transcript: transcript,
                metadata: meta,
                includeTranscript: true
            )
            try store.save(
                in: dir,
                raw: nil,
                transcript: transcript,
                summary: summary,
                summaryMarkdown: markdown,
                speakerMap: nil,
                metadata: meta
            )
            loadRecentMeetings()
            statusMessage = "Summarized \"\(meta.title)\"."
        } catch {
            statusMessage = "Summarize failed: \(error.localizedDescription)"
        }
        isProcessing = false
    }

    /// Posts the most recent meeting's summary to the configured Slack webhook,
    /// or copies it to the clipboard if no webhook is set.
    public func postLatestToSlack() async {
        guard let latest = recentMeetings.first else {
            statusMessage = "No meeting to post yet."
            return
        }
        let dir = latest.directory
        let store = MeetingStore(baseDir: dir.deletingLastPathComponent())
        guard let summary = (try? store.loadSummary(in: dir)).flatMap({ $0 }) else {
            statusMessage = "Latest meeting has no summary to post."
            return
        }
        let message = SlackRenderer.render(summary: summary, metadata: loadMetadata(in: dir))

        guard let webhook = settings.slackWebhook, let url = URL(string: webhook), !webhook.isEmpty else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
            statusMessage = "No Slack webhook set — copied the summary to the clipboard."
            return
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": message])
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            statusMessage = (200..<300).contains(status)
                ? "Posted the latest meeting to Slack."
                : "Slack returned HTTP \(status)."
        } catch {
            statusMessage = "Slack post failed: \(error.localizedDescription)"
        }
    }

    /// The most recent meeting's rendered transcript text, for `GetLatestTranscript`.
    public func latestTranscriptText() -> String? {
        guard let latest = recentMeetings.first else { return nil }
        let url = latest.directory.appendingPathComponent("transcript.md")
        return try? String(contentsOf: url, encoding: .utf8)
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

    /// Whether an ElevenLabs key is configured — gates the SOTA "Fully transcribe".
    public var hasElevenLabsKey: Bool {
        !(credentials.elevenLabsKey ?? "").isEmpty
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
        loadRecentMeetings()
        startWatchingOutputDir()
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
            activeRecordingStartedAt = Date()
            isRecording = true
            statusMessage = "Recording…"
        } catch {
            recorderBox = nil
            activeRecordingDir = nil
            activeRecordingStartedAt = nil
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

        let startedAt = activeRecordingStartedAt ?? Date()
        recorderBox = nil
        activeRecordingDir = nil
        activeRecordingStartedAt = nil

        // Name the meeting from the overlapping calendar event when available.
        let calendar = calendarMeetingInfo(at: startedAt)

        // Save the transcript into the SAME folder the audio was captured into,
        // so one meeting is one self-contained folder.
        await process(
            audioFile: audioFileURL,
            title: calendar?.title ?? defaultMeetingTitle(),
            useMultiChannel: true,
            meetingDir: dir,
            startedAt: startedAt,
            participants: calendar?.participants ?? []
        )
    }

    /// Transcribes (and optionally summarizes) an existing audio file the user
    /// selected, reusing the same pipeline as live recordings.
    public func transcribeExistingFile(_ url: URL) async {
        let title = url.deletingPathExtension().lastPathComponent
        // An imported file has no capture folder; let the pipeline create a fresh
        // unique meeting folder for it.
        await process(
            audioFile: url,
            title: title.isEmpty ? defaultMeetingTitle() : title,
            useMultiChannel: false,
            meetingDir: nil,
            startedAt: Date()
        )
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

            // Reuse the meeting's existing directory, saving in place.
            try store.save(
                in: meetingDir,
                raw: nil,
                transcript: renamed,
                summary: summary,
                summaryMarkdown: markdown,
                speakerMap: map,
                metadata: metadata
            )
            loadRecentMeetings()
            statusMessage = "Updated speaker names."
        } catch {
            statusMessage = "Could not rename speakers: \(error.localizedDescription)"
        }
    }

    /// Moves a meeting folder to the Trash and refreshes the list.
    @discardableResult
    public func deleteMeeting(_ meeting: RecentMeeting) -> Bool {
        do {
            try FileManager.default.trashItem(at: meeting.directory, resultingItemURL: nil)
            if selectedMeetingID == meeting.id { selectedMeetingID = nil }
            loadRecentMeetings()
            statusMessage = "Moved \"\(meeting.title)\" to Trash."
            return true
        } catch {
            statusMessage = "Could not delete: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Pipeline

    private func process(
        audioFile: URL,
        title: String,
        useMultiChannel: Bool,
        meetingDir: URL?,
        startedAt: Date,
        participants: [String] = []
    ) async {
        isProcessing = true
        statusMessage = "Transcribing…"

        let transport = URLSessionTransport()

        // Default engine: free, on-device, private (WhisperKit / Whisper on Apple
        // Silicon). Works for every language — including Russian — with automatic
        // language detection, no API key, and no network after the one-time model
        // download. The paid SOTA path is the explicit "Fully transcribe" action.
        var channelFiles: [URL] = []
        if let meetingDir {
            // `Recorder` writes these per-channel files; transcribing them
            // separately gives free "You" vs "Them" attribution.
            let mic = meetingDir.appendingPathComponent("mic.m4a")
            let system = meetingDir.appendingPathComponent("system.m4a")
            channelFiles = [mic, system].filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        let transcriber: any Transcriber = LocalTranscriber(channelFiles: channelFiles)
        let tier = TranscriptTier.local
        let options = ScribeOptions()
        if channelFiles.count == 2, let meetingDir {
            writeDefaultSpeakerMapIfNeeded(["speaker_0": "You", "speaker_1": "Them"], in: meetingDir)
        }

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
        let pipeline = MeetingPipeline(transcriber: transcriber, summarizer: summarizer, store: store)

        let metadata = MeetingMetadata(
            title: title,
            date: Self.dayString(startedAt),
            startedAt: Self.isoDateTime(startedAt),
            participants: participants,
            consentAcknowledged: consentAcknowledged,
            model: canSummarize ? settings.defaultModel : nil,
            transcriptTier: tier
        )

        if canSummarize {
            statusMessage = "Transcribing and summarizing…"
        }

        do {
            let result = try await pipeline.run(
                audioFile: audioFile,
                metadata: metadata,
                options: options,
                summarize: canSummarize,
                meetingDir: meetingDir
            )

            // Re-scan from disk so the saved meeting (with its real startedAt)
            // lands in the list in the right position — the disk is the source
            // of truth now that one meeting is one folder.
            loadRecentMeetings()
            currentCostUSD += result.cost.totalUSD
            isProcessing = false
            if let summaryError = result.summaryError {
                statusMessage = "Transcribed \"\(title)\" — summary skipped (\(summaryError))"
            } else {
                statusMessage = "Saved \"\(title)\" — $\(Self.formatUSD(result.cost.totalUSD))"
            }
        } catch {
            isProcessing = false
            // The audio is safe on disk — only processing failed. Re-scan so the
            // recording reappears as an "Untranscribed" item that can be
            // re-transcribed in place. Without this it silently drops off the
            // list (the last refresh ran while it was still the active recording)
            // and looks as though the whole meeting was lost.
            loadRecentMeetings()
            statusMessage = "Processing failed: \(error.localizedDescription) — audio saved; re-transcribe it from the list."
        }
    }

    /// Re-transcribes an existing meeting with ElevenLabs Scribe (SOTA, diarized)
    /// in place — the opt-in paid upgrade from the free local transcript. Reuses
    /// the meeting's folder, audio, and original metadata, keeps any speaker map,
    /// and re-summarizes when an OpenRouter key is configured.
    public func fullyTranscribe(_ meeting: RecentMeeting) async {
        guard let elevenKey = credentials.elevenLabsKey, !elevenKey.isEmpty else {
            statusMessage = "Add an ElevenLabs API key in Settings to fully transcribe."
            return
        }
        let dir = meeting.directory
        guard let audio = Self.meetingAudioURL(in: dir) else {
            statusMessage = "No audio found for \"\(meeting.title)\" to transcribe."
            return
        }

        isProcessing = true
        statusMessage = "Fully transcribing \"\(meeting.title)\" with ElevenLabs Scribe…"

        let transport = URLSessionTransport()

        // Validated mono-Scribe path: when both per-channel files exist, mix
        // mic+system to mono (1× cost, correct duration) and attribute each word
        // to You/Them by channel energy. Otherwise fall back to a single-channel
        // Scribe request with its default diarization.
        let mic = dir.appendingPathComponent("mic.m4a")
        let system = dir.appendingPathComponent("system.m4a")
        let fm = FileManager.default
        let transcriber: any Transcriber
        if fm.fileExists(atPath: mic.path), fm.fileExists(atPath: system.path) {
            transcriber = ChannelAttributedScribeTranscriber(
                scribe: ScribeClient(apiKey: elevenKey, transport: transport),
                micURL: mic,
                systemURL: system
            )
        } else {
            transcriber = ScribeClient(apiKey: elevenKey, transport: transport)
        }

        var summarizer: Summarizer?
        if let openRouterKey = credentials.openRouterKey, !openRouterKey.isEmpty {
            summarizer = Summarizer(
                client: OpenRouterClient(apiKey: openRouterKey, transport: transport),
                model: settings.defaultModel
            )
        }
        let canSummarize = (summarizer != nil)

        let store = MeetingStore(baseDir: dir.deletingLastPathComponent())
        let pipeline = MeetingPipeline(transcriber: transcriber, summarizer: summarizer, store: store)

        // Preserve the meeting's original metadata; only the tier, model, and
        // cost change. The pipeline re-applies any existing speakers.json.
        var metadata = loadMetadata(in: dir)
        metadata.transcriptTier = TranscriptTier.sotaScribe
        if canSummarize { metadata.model = settings.defaultModel }

        // The attributed transcriber handles channels internally and the plain
        // fallback uses single-channel diarization, so multi-channel is never set.
        var options = ScribeOptions()
        options.useMultiChannel = false

        do {
            let result = try await pipeline.run(
                audioFile: audio,
                metadata: metadata,
                options: options,
                summarize: canSummarize,
                meetingDir: dir
            )
            loadRecentMeetings()
            currentCostUSD += result.cost.totalUSD
            isProcessing = false
            if let summaryError = result.summaryError {
                statusMessage = "Fully transcribed \"\(metadata.title)\" — summary skipped (\(summaryError))"
            } else {
                statusMessage = "Fully transcribed \"\(metadata.title)\" — $\(Self.formatUSD(result.cost.totalUSD))"
            }
        } catch {
            isProcessing = false
            statusMessage = "Full transcription failed: \(error.localizedDescription)"
        }
    }

    /// Transcribes a previously-recorded but unprocessed meeting (audio only, no
    /// transcript — e.g. a recording whose processing failed) in place, using the
    /// free on-device engine.
    public func transcribeSaved(_ meeting: RecentMeeting) async {
        let dir = meeting.directory
        guard let audio = Self.meetingAudioURL(in: dir) else {
            statusMessage = "No audio found for \"\(meeting.title)\"."
            return
        }
        let started = meeting.startedAt ?? Self.folderDate(dir) ?? Date()
        await process(
            audioFile: audio,
            title: meeting.title,
            useMultiChannel: Self.isTwoChannelCapture(in: dir),
            meetingDir: dir,
            startedAt: started
        )
    }

    /// Downloads the on-device transcription model in the background at launch,
    /// resilient to the URLSession request timeout, so a recording never waits on
    /// a ~600 MB download mid-processing. Best-effort: failures are logged and
    /// swallowed (the transcribe path retries, also via a background session).
    public func prewarmTranscriptionModel() async {
        guard modelDownloadProgress == nil else { return }
        modelDownloadProgress = 0
        do {
            try await LocalTranscriber.downloadModel { [weak self] frac in
                Task { @MainActor in self?.modelDownloadProgress = (frac < 1.0) ? frac : nil }
            }
        } catch {
            log.notice("prewarmTranscriptionModel failed: \(String(describing: error), privacy: .public)")
        }
        modelDownloadProgress = nil
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
            log.notice("loadRecentMeetings: cannot read outputDir \(self.settings.outputDir.path, privacy: .public)")
            recentMeetings = []
            return
        }

        let isoParser = ISO8601DateFormatter()
        isoParser.formatOptions = [.withInternetDateTime]

        let meetings: [(RecentMeeting, Date)] = entries.compactMap { dir in
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { return nil }
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let metaURL = dir.appendingPathComponent("meta.json")

            if fm.fileExists(atPath: metaURL.path) {
                let metadata = loadMetadata(in: dir)
                // Prefer the logical start time; fall back to file mtime so legacy
                // meetings (no startedAt) still sort sensibly and never blank the list.
                let started = metadata.startedAt.flatMap { isoParser.date(from: $0) }
                // Prefer the real wall-clock duration from the audio file: Scribe's
                // multichannel response reports a summed (≈2×) duration, so the
                // stored cost value can overstate length. Falls back to the stored
                // value when the audio can't be probed.
                let realDur = Self.meetingAudioURL(in: dir).flatMap { AudioProbe.durationSeconds(of: $0) }
                let meeting = RecentMeeting(
                    title: metadata.title,
                    date: metadata.date,
                    startedAt: started,
                    directory: dir,
                    costUSD: metadata.cost?.totalUSD ?? 0,
                    durationSecs: realDur ?? metadata.cost?.audioDurationSecs,
                    transcriptTier: metadata.transcriptTier,
                    isProcessed: true
                )
                return (meeting, started ?? modified)
            }

            // No meta.json but audio present: a recording whose processing didn't
            // finish. Surface it (so the audio isn't invisible) as transcribable —
            // but never the in-progress recording itself.
            if let active = activeRecordingDir,
               dir.standardizedFileURL == active.standardizedFileURL { return nil }
            guard Self.meetingAudioURL(in: dir) != nil else { return nil }
            let started = Self.folderDate(dir)
            let meeting = RecentMeeting(
                title: Self.recoveredTitle(for: dir, started: started),
                date: Self.dayString(started ?? modified),
                startedAt: started,
                directory: dir,
                costUSD: 0,
                durationSecs: nil,
                transcriptTier: nil,
                isProcessed: false
            )
            return (meeting, started ?? modified)
        }

        recentMeetings = meetings
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        log.notice("loadRecentMeetings: outputDir=\(self.settings.outputDir.path, privacy: .public) entries=\(entries.count, privacy: .public) meetings=\(self.recentMeetings.count, privacy: .public)")
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

    /// Creates the per-meeting folder that audio is captured into and that the
    /// transcript is later saved into — one self-contained `meeting-…` folder.
    private func makeSessionDirectory() throws -> URL {
        let dir = MeetingStore.uniqueMeetingDirectory(in: settings.outputDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func defaultMeetingTitle() -> String {
        "Meeting \(Self.isoDate())"
    }

    /// Writes a default speaker map (e.g. mic → "You", system → "Them") into a
    /// meeting folder when none exists yet, so a fresh local two-channel
    /// transcript is labeled by source. A later rename — or a SOTA pass — reuses
    /// or overwrites it.
    private func writeDefaultSpeakerMapIfNeeded(_ names: [String: String], in dir: URL) {
        let url = dir.appendingPathComponent("speakers.json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(SpeakerMap(names: names)) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The best available audio file co-located with a meeting (prefers the
    /// combined 2-channel capture for multi-channel STT), if any.
    static func meetingAudioURL(in dir: URL) -> URL? {
        let fm = FileManager.default
        for name in ["meeting.m4a", "combined.m4a", "mic.m4a", "system.m4a"] {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Whether a meeting folder holds a combined 2-channel capture (so Scribe can
    /// diarize by channel for free).
    static func isTwoChannelCapture(in dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("meeting.m4a").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("combined.m4a").path)
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

    private static func isoDateTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// "yyyy-MM-dd" for a date (the meeting's calendar day).
    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Parses the start time encoded in a `meeting-yyyy-MM-dd-HHmmss[-n]` folder name.
    static func folderDate(_ dir: URL) -> Date? {
        let name = dir.lastPathComponent
        guard name.hasPrefix("meeting-") else { return nil }
        let stamp = String(name.dropFirst("meeting-".count).prefix(17)) // yyyy-MM-dd-HHmmss
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: stamp)
    }

    /// A display title for a recovered (audio-only) recording.
    static func recoveredTitle(for dir: URL, started: Date?) -> String {
        guard let started else { return "Recording · \(dir.lastPathComponent)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return "Recording · \(formatter.string(from: started))"
    }

    // MARK: - Output directory watch

    /// Starts (or restarts) a lightweight watch on the output directory so the
    /// meeting list stays current when meetings appear from the CLI or another
    /// instance — fixing the "stale, launch-time snapshot" that left the list
    /// empty even though valid meetings existed on disk.
    private func startWatchingOutputDir() {
        outputDirWatcher?.cancel()
        outputDirWatcher = nil

        let dir = settings.outputDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else {
            log.notice("startWatchingOutputDir: cannot open \(dir.path, privacy: .public)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.loadRecentMeetings() }
        }
        source.setCancelHandler { close(fd) }
        outputDirWatcher = source
        source.resume()
    }

    private static func formatUSD(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}
