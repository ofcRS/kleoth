import SwiftUI
import AppKit
import KleothCore
import KleothCapture
import KeyboardShortcuts

/// Settings screen: API keys (persisted to the Keychain), output directory,
/// default summarization model, and Slack webhook.
///
/// Refined-native macOS 26 styling: a grouped `Form` whose sections open with a
/// `KleothSectionHeader` (accent SF Symbol + headline) for a consistent rhythm,
/// quiet captions as section footers, and the system accent throughout. All
/// edits are committed to the controller (and Keychain) on submit / change, with
/// a belt-and-suspenders commit when the window goes away.
struct SettingsView: View {
    @EnvironmentObject private var controller: RecordingController

    // Local editable copies; committed to the controller (and Keychain) on change.
    @State private var elevenLabsKey: String = ""
    @State private var openRouterKey: String = ""
    @State private var slackWebhook: String = ""
    @State private var outputDirPath: String = ""
    @State private var selectedModel: String = ""

    /// The live, filtered summarization-model catalog backing the picker. Seeded
    /// synchronously from ``ModelCatalog/curatedFallback`` for first paint /
    /// offline, then refreshed from the live OpenRouter feed in `.task`. The
    /// default and the current selection are always present (the catalog filter
    /// guarantees it), so an externally-configured choice never vanishes.
    @State private var availableModels: [String] = []
    /// True while the live catalog fetch is in flight (drives a small spinner).
    @State private var isRefreshingModels = false

    /// On-device (WhisperKit) transcription model status, read from disk on
    /// appear and refreshed when a download finishes (see
    /// ``RecordingController/modelDownloadProgress``).
    @State private var modelDownloaded = false
    @State private var modelSizeBytes: Int64 = 0

    /// Preferred on-device transcription language ("auto" = detect). Pinning a
    /// language is the bulletproof fix when auto-detection would otherwise misread
    /// a quiet/short opening as English.
    @State private var transcriptionLanguage: String = "auto"

    /// Provider prefixes that 404 under this account's no-train data policy (see
    /// CLAUDE.md). A stored default with one of these prefixes (e.g. the obsolete
    /// `openai/gpt-4.1-mini`) is migrated to ``ModelCatalog/defaultModel`` on load.
    private static let blockedProviderPrefixes = ["openai/", "mistralai/", "qwen/", "x-ai/"]

    /// On-device transcription language choices: automatic detection plus a
    /// curated set of common languages to pin. Values are Whisper language codes
    /// ("auto" = detect). Russian is surfaced near the top as the primary use case.
    private static let transcriptionLanguages: [(code: String, label: String)] = [
        ("auto", "Auto-detect"),
        ("ru", "Russian"),
        ("en", "English"),
        ("uk", "Ukrainian"),
        ("de", "German"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("pl", "Polish"),
        ("nl", "Dutch"),
        ("tr", "Turkish"),
        ("zh", "Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
    ]

    var body: some View {
        Form {
            credentialsSection
            outputSection
            localModelSection
            summarizationSection
            slackSection
            shortcutsSection
            calendarSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .kleothSoftScrollEdge()
        .onAppear {
            loadFromController()
            refreshModelStatus()
            // Make the Settings window ⌘-Tab-able too, and keep it counted so the
            // app doesn't drop out of the switcher when another window closes.
            AppActivation.shared.windowOpened()
        }
        // Commit any unsubmitted edits when the window goes away, and re-evaluate
        // whether the app should remain a regular (⌘-Tab) app.
        .onDisappear {
            commitAll()
            AppActivation.shared.windowClosed()
        }
        // Refresh the model catalog from the live feed (fail-soft; never throws).
        .task { await refreshModels() }
        // Re-read on-device model status when a background download completes.
        .onChange(of: controller.modelDownloadProgress) { _, progress in
            if progress == nil { refreshModelStatus() }
        }
    }

    // MARK: - Sections

    private var credentialsSection: some View {
        Section {
            SecureField("ElevenLabs API key", text: $elevenLabsKey)
                .onSubmit { controller.updateElevenLabsKey(elevenLabsKey) }
            SecureField("OpenRouter API key (optional)", text: $openRouterKey)
                .onSubmit { controller.updateOpenRouterKey(openRouterKey) }
        } header: {
            KleothSectionHeader("Credentials", systemImage: "key.fill")
        } footer: {
            captionFooter("Stored in your macOS Keychain and never logged. ElevenLabs powers SOTA transcription; OpenRouter powers summaries.")
        }
    }

    private var outputSection: some View {
        Section {
            HStack(spacing: KleothMetrics.spacingS) {
                TextField("Output folder", text: $outputDirPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { controller.updateOutputDir(outputDirPath) }
                Button("Choose…") { chooseFolder() }
            }
        } header: {
            KleothSectionHeader("Output", systemImage: "folder.fill")
        } footer: {
            captionFooter("Each meeting is written to its own folder here — audio, transcript, summary, and metadata you own.")
        }
    }

    /// On-device transcription engine status: model name, ready/downloading/missing
    /// state with size, and a Download / Reveal action. Reactive to the live
    /// download progress published by the controller.
    private var localModelSection: some View {
        Section {
            HStack(spacing: KleothMetrics.spacingM) {
                Image(systemName: modelStatusSymbol)
                    .font(.title3)
                    .foregroundStyle(modelStatusTint)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisper Large v3 Turbo")
                        .font(.callout.weight(.medium))
                    Text(modelStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: KleothMetrics.spacingM)

                modelAction
            }
            .padding(.vertical, KleothMetrics.spacingXS)

            Picker("Language", selection: $transcriptionLanguage) {
                ForEach(Self.transcriptionLanguages, id: \.code) { lang in
                    Text(lang.label).tag(lang.code)
                }
            }
            .onChange(of: transcriptionLanguage) { _, newValue in
                controller.updateTranscriptionLanguage(newValue)
            }
        } header: {
            KleothSectionHeader("On-device transcription", systemImage: "cpu")
        } footer: {
            captionFooter("Kleoth transcribes locally on the Apple Neural Engine — free, private, offline, and multilingual. The model downloads once (~626 MB) and is cached on this Mac. Leave Language on Auto-detect, or pin one (e.g. Russian) if detection ever guesses wrong.")
        }
    }

    /// The Download / Reveal / progress control for the local model section.
    @ViewBuilder
    private var modelAction: some View {
        if isDownloadingModel {
            ProgressView(value: controller.modelDownloadProgress ?? 0)
                .controlSize(.small)
                .frame(width: 84)
        } else if modelDownloaded {
            Button("Reveal") { revealModel() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show the downloaded model in Finder")
        } else {
            Button("Download") { Task { await controller.prewarmTranscriptionModel() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Download the on-device transcription model now")
        }
    }

    private var summarizationSection: some View {
        Section {
            Picker("Default model", selection: $selectedModel) {
                ForEach(availableModels, id: \.self) { model in
                    Text(modelLabel(model)).tag(model)
                }
            }
            .onChange(of: selectedModel) { _, newValue in
                controller.updateDefaultModel(newValue)
            }
        } header: {
            HStack(spacing: KleothMetrics.spacingS) {
                KleothSectionHeader("Summarization", systemImage: "sparkles")
                if isRefreshingModels {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await refreshModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Refresh the model list from OpenRouter")
                .accessibilityLabel("Refresh model list")
                .disabled(isRefreshingModels)
            }
        } footer: {
            captionFooter("Models available under your OpenRouter data policy. The default runs locally-friendly Gemini Flash; pick any provider that fits your privacy and cost.")
        }
    }

    private var slackSection: some View {
        Section {
            TextField("Incoming webhook URL", text: $slackWebhook)
                .textFieldStyle(.roundedBorder)
                .onSubmit { controller.updateSlackWebhook(slackWebhook) }
        } header: {
            KleothSectionHeader("Slack", systemImage: "paperplane.fill")
        } footer: {
            captionFooter("Optional. Post a meeting's summary to a channel via an incoming webhook.")
        }
    }

    private var shortcutsSection: some View {
        Section {
            KeyboardShortcuts.Recorder("Start / stop recording:", name: .toggleRecording)
        } header: {
            KleothSectionHeader("Shortcuts", systemImage: "command")
        } footer: {
            captionFooter("Also available as Shortcuts / Spotlight actions and via kleoth:// URLs.")
        }
    }

    private var calendarSection: some View {
        Section {
            if controller.calendarAuthorized {
                Label("Meetings are named from your calendar event.", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .tint(KleothPalette.successTint)
            } else {
                HStack {
                    Text("Name meetings from your calendar")
                    Spacer(minLength: KleothMetrics.spacingM)
                    Button("Enable") { Task { await controller.requestCalendarAccess() } }
                }
            }
        } header: {
            KleothSectionHeader("Calendar", systemImage: "calendar")
        } footer: {
            captionFooter("When enabled, a recording started during a calendar event takes that event's title.")
        }
    }

    // MARK: - Section helpers

    /// The standard quiet footer caption used under each section.
    private func captionFooter(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, KleothMetrics.spacingXS)
    }

    /// Display label for a model slug — show the bare slug, but tag the default so
    /// users recognize the recommended choice.
    private func modelLabel(_ slug: String) -> String {
        slug == ModelCatalog.defaultModel ? "\(slug)  (default)" : slug
    }

    // MARK: - Model catalog

    /// Fetches the live, filtered model catalog (fail-soft) and updates the
    /// picker. Keeps the current selection present and shows a spinner while in
    /// flight. Safe to call repeatedly (Refresh button + initial `.task`).
    private func refreshModels() async {
        isRefreshingModels = true
        defer { isRefreshingModels = false }

        let catalog = ModelCatalog()
        // `fetch` never throws: offline/non-2xx/bad-JSON falls back to a fresh
        // disk cache, else the curated list — both filtered to keep `selectedModel`.
        let models = await catalog.fetch(transport: URLSessionTransport(), keeping: selectedModel)
        availableModels = models
    }

    // MARK: - On-device model status

    private var isDownloadingModel: Bool { controller.modelDownloadProgress != nil }

    private var modelStatusSymbol: String {
        if isDownloadingModel { return "arrow.down.circle" }
        return modelDownloaded ? "checkmark.circle.fill" : "exclamationmark.circle"
    }

    private var modelStatusTint: Color {
        if isDownloadingModel { return .accentColor }
        return modelDownloaded ? KleothPalette.successTint : KleothPalette.pendingTint
    }

    private var modelStatusDetail: String {
        if let progress = controller.modelDownloadProgress {
            return "Downloading… \(Int(progress * 100))%"
        }
        if modelDownloaded {
            return "Ready · \(Self.formatBytes(modelSizeBytes)) on disk"
        }
        return "Not downloaded — downloads automatically on first recording"
    }

    /// Reads the on-device model's on-disk status (cheap — a directory listing).
    private func refreshModelStatus() {
        let info = LocalTranscriber.cachedModelInfo()
        modelDownloaded = info.downloaded
        modelSizeBytes = info.sizeBytes
    }

    /// Reveals the cached model folder in Finder.
    private func revealModel() {
        if let (folder, _) = LocalTranscriber.cachedModel(variant: LocalTranscriber.defaultModel) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    /// Human-readable byte size (e.g. "626 MB").
    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Loading / committing

    private func loadFromController() {
        elevenLabsKey = controller.credentials.elevenLabsKey ?? ""
        openRouterKey = controller.credentials.openRouterKey ?? ""
        slackWebhook = controller.settings.slackWebhook ?? ""
        outputDirPath = controller.settings.outputDir.path
        selectedModel = controller.settings.defaultModel
        transcriptionLanguage = controller.settings.transcriptionLanguage ?? "auto"

        // Migrate a stored model whose provider 404s under this account's
        // no-train policy (e.g. the obsolete "openai/gpt-4.1-mini") to the
        // working default, and persist it so it stops reappearing.
        if Self.isBlockedModel(selectedModel) {
            selectedModel = ModelCatalog.defaultModel
            controller.updateDefaultModel(selectedModel)
        }

        // Seed the picker synchronously for first paint / offline; `.task` then
        // refreshes from the live feed. The filter keeps the default + selection.
        availableModels = ModelCatalog.filtered(from: ModelCatalog.curatedFallback, keeping: selectedModel)
    }

    /// Whether `slug`'s provider prefix is one that 404s under the no-train policy.
    private static func isBlockedModel(_ slug: String) -> Bool {
        blockedProviderPrefixes.contains { slug.hasPrefix($0) }
    }

    private func commitAll() {
        controller.updateElevenLabsKey(elevenLabsKey)
        controller.updateOpenRouterKey(openRouterKey)
        controller.updateSlackWebhook(slackWebhook)
        controller.updateOutputDir(outputDirPath)
        controller.updateDefaultModel(selectedModel)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirPath = url.path
            controller.updateOutputDir(url.path)
        }
    }
}
