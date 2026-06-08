import SwiftUI
import AppKit
import KleothCore
import KleothCapture
import KeyboardShortcuts

/// Settings screen: API keys (persisted to the Keychain), output directory,
/// and the default summarization model.
///
/// Refined-native macOS 26 styling: a grouped `Form` whose sections open with a
/// `KleothSectionHeader` (accent SF Symbol + headline) for a consistent rhythm,
/// quiet captions as section footers, and the system accent throughout. All
/// edits are committed to the controller (and Keychain) on submit / change, with
/// a belt-and-suspenders commit when the window goes away.
struct SettingsView: View {
    @EnvironmentObject private var controller: RecordingController
    @Environment(\.openWindow) private var openWindow

    // Local editable copies; committed to the controller (and Keychain) on change.
    @State private var elevenLabsKey: String = ""
    @State private var openRouterKey: String = ""
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

    /// Provider-reported account usage — the ONLY place money appears in the
    /// app. Both numbers come live from the providers (ElevenLabs subscription
    /// credits, OpenRouter credit balance); Kleoth keeps no tally of its own.
    @State private var elevenUsage: ElevenLabsUsage?
    @State private var openRouterCredits: OpenRouterCredits?
    @State private var usageError: String?
    @State private var isLoadingUsage = false

    /// Provider prefixes that 404 under this account's no-train data policy (see
    /// CLAUDE.md). A stored default with one of these prefixes (e.g. the obsolete
    /// `openai/gpt-4.1-mini`) is migrated to ``ModelCatalog/defaultModel`` on load.
    private static let blockedProviderPrefixes = ["openai/", "mistralai/", "qwen/", "x-ai/"]

    /// On-device transcription language choices: automatic detection plus a
    /// curated set of common languages to pin. Values are Whisper language codes
    /// ("auto" = detect). Non-private so the onboarding language picker reuses the
    /// exact same list rather than duplicating it.
    static let transcriptionLanguages: [(code: String, label: String)] = [
        ("auto", "Auto-detect"),
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
        ("ru", "Russian"),
    ]

    var body: some View {
        Form {
            credentialsSection
            outputSection
            localModelSection
            summarizationSection
            usageSection
            shortcutsSection
            calendarSection
            onboardingSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
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
        // Fetch provider-reported usage (fail-soft; errors surface in-section).
        .task { await refreshUsage() }
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
            captionFooter("Stored in your macOS Keychain and never logged. ElevenLabs powers cloud transcription; OpenRouter powers summaries.")
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
            captionFooter("Kleoth transcribes locally on the Apple Neural Engine — free, private, offline, and multilingual. The model downloads once (~626 MB) and is cached on this Mac. Leave Language on Auto-detect, or pin one if detection ever guesses wrong.")
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

    /// Account usage as reported live by the providers — deliberately the only
    /// money surface in the app. Nothing here is computed by Kleoth: ElevenLabs
    /// reports its billing-cycle credit quota, OpenRouter its credit balance.
    private var usageSection: some View {
        Section {
            if !hasUsageKeys {
                Text("Add an API key above to see your account usage here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if let usage = elevenUsage {
                    elevenLabsUsageRow(usage)
                }
                if let credits = openRouterCredits {
                    openRouterUsageRow(credits)
                }
                if isLoadingUsage && elevenUsage == nil && openRouterCredits == nil {
                    HStack(spacing: KleothMetrics.spacingS) {
                        ProgressView().controlSize(.small)
                        Text("Fetching from the providers…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let usageError {
                    Label(usageError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(KleothPalette.pendingTint)
                }
            }
        } header: {
            HStack(spacing: KleothMetrics.spacingS) {
                KleothSectionHeader("Usage", systemImage: "chart.bar")
                if isLoadingUsage {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await refreshUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Refresh usage from ElevenLabs and OpenRouter")
                .accessibilityLabel("Refresh usage")
                .disabled(isLoadingUsage || !hasUsageKeys)
            }
        } footer: {
            captionFooter("Account-wide numbers reported live by ElevenLabs and OpenRouter — Kleoth keeps no tally of its own.")
        }
    }

    /// "ElevenLabs · 17,231 of 100,000 credits this cycle · resets Jun 12" with a
    /// thin consumption gauge.
    private func elevenLabsUsageRow(_ usage: ElevenLabsUsage) -> some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
            HStack(spacing: KleothMetrics.spacingS) {
                Text("ElevenLabs")
                    .font(.callout.weight(.medium))
                if let tier = usage.tier, !tier.isEmpty {
                    KleothPill(tier.capitalized)
                }
                Spacer(minLength: 0)
            }
            Text(elevenLabsDetail(usage))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if usage.characterLimit > 0 {
                ProgressView(value: min(1, Double(usage.characterCount) / Double(usage.characterLimit)))
                    .controlSize(.small)
                    .tint(.accentColor)
            }
        }
        .padding(.vertical, KleothMetrics.spacingXS)
    }

    private func elevenLabsDetail(_ usage: ElevenLabsUsage) -> String {
        var text = "\(usage.characterCount.formatted()) of \(usage.characterLimit.formatted()) credits this cycle"
        if let reset = usage.nextReset {
            text += " · resets \(Self.shortDate(reset))"
        }
        return text
    }

    /// "OpenRouter · $10.03 left of $25.00 purchased · $14.97 used all-time".
    private func openRouterUsageRow(_ credits: OpenRouterCredits) -> some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
            Text("OpenRouter")
                .font(.callout.weight(.medium))
            Text("\(Self.money(credits.remaining)) left of \(Self.money(credits.totalCredits)) purchased · \(Self.money(credits.totalUsage)) used all-time")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, KleothMetrics.spacingXS)
    }

    /// Whether any provider key is available to fetch usage with.
    private var hasUsageKeys: Bool {
        !elevenLabsKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !openRouterKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Fetches usage from each configured provider. Fail-soft per provider: one
    /// failing (offline, revoked key) doesn't hide the other; errors surface as
    /// a quiet caption. Keys go only into request headers and are never logged.
    private func refreshUsage() async {
        guard hasUsageKeys else { return }
        isLoadingUsage = true
        defer { isLoadingUsage = false }
        usageError = nil

        let transport = URLSessionTransport()
        var errors: [String] = []

        let elevenKey = elevenLabsKey.trimmingCharacters(in: .whitespaces)
        if !elevenKey.isEmpty {
            do {
                elevenUsage = try await ElevenLabsUsageClient(apiKey: elevenKey, transport: transport).fetch()
            } catch ProviderUsageError.httpStatus(401) {
                // A key scoped to Speech-to-Text only (no "User" read permission)
                // can transcribe fine but can't report usage — verified live.
                errors.append("ElevenLabs: the API key needs the “User” read permission to report usage")
            } catch {
                errors.append("ElevenLabs: \(Self.shortError(error))")
            }
        }

        let routerKey = openRouterKey.trimmingCharacters(in: .whitespaces)
        if !routerKey.isEmpty {
            do {
                openRouterCredits = try await OpenRouterUsageClient(apiKey: routerKey, transport: transport).fetch()
            } catch {
                errors.append("OpenRouter: \(Self.shortError(error))")
            }
        }

        usageError = errors.isEmpty ? nil : errors.joined(separator: " · ")
    }

    /// Compact, user-facing error text (no raw error dumps in the form).
    private static func shortError(_ error: Error) -> String {
        if case let ProviderUsageError.httpStatus(code) = error {
            return code == 401 ? "key rejected (HTTP 401)" : "HTTP \(code)"
        }
        return error.localizedDescription
    }

    /// "$12.34" — provider balances in USD, formatted for the user's locale.
    private static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }

    /// "Jun 12, 2026"
    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
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

    /// Re-runs the first-run welcome flow on demand (name, permissions, model,
    /// and the start-recording finish). Opening it does not reset any state — it's
    /// purely a way back into the guided setup.
    private var onboardingSection: some View {
        Section {
            Button("Show Welcome Window") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "kleoth-onboarding")
            }
        } header: {
            KleothSectionHeader("Onboarding", systemImage: "sparkles.rectangle.stack")
        } footer: {
            captionFooter("Replay the first-run setup.")
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
