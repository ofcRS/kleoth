import SwiftUI
import AppKit
import KleothCore
import KleothCapture
import KeyboardShortcuts

/// Settings window: a sidebar of six pages (`SettingsPage`), each a plain
/// grouped `Form` of that page's sections under its own title — the System
/// Settings idiom, no chrome of its own. Section headers are plain text and
/// each section ends in a quiet caption. All edits are committed to the controller (and Keychain)
/// on submit / change, with a belt-and-suspenders commit when the window goes
/// away — the state for every page lives here so `commitAll()` sees it all.
struct SettingsView: View {
    @EnvironmentObject private var controller: RecordingController
    /// Dictation state and settings. `@EnvironmentObject`, never
    /// `DictationController.shared` — a plain static read doesn't subscribe the
    /// view, so the live Accessibility state would never refresh.
    @EnvironmentObject private var dictation: DictationController
    @Environment(\.openWindow) private var openWindow

    // Local editable copies; committed to the controller (and Keychain) on change.
    @State private var elevenLabsKey: String = ""
    @State private var openRouterKey: String = ""
    @State private var outputDirPath: String = ""
    @State private var selectedModel: String = ""

    /// The AI provider pick ("auto" or an `AIProvider` raw value), the local
    /// server's API root and its optional bearer token.
    @State private var aiProvider: String = "auto"
    @State private var localServerURL: String = ""
    @State private var localServerKey: String = ""
    /// The model each task uses on a NON-OpenRouter provider (OpenRouter keeps
    /// `selectedModel` / `dictationModel` and its catalog picker). Re-seeded by
    /// `syncProviderModels()` whenever the resolved provider changes.
    @State private var summaryProviderModel: String = ""
    @State private var dictationProviderModel: String = ""

    /// The dictation polish model, and the personal dictionary as editor text.
    /// Both live here (rather than inside `SettingsDictationSection`) so
    /// `commitAll()` can flush unsubmitted edits when the window goes away, and
    /// so `refreshModels` can pin the slug in the catalog.
    @State private var dictationModel: String = ""
    @State private var dictionaryText: String = ""
    /// What the editor showed when the window opened. `commitAll()` writes the
    /// dictionary only when the text changed: `PersonalDictionaryStore.load()`
    /// is fail-soft (a malformed `dictionary.json` reads as empty), so an
    /// unconditional write on close would replace the user's unreadable file
    /// with `[]` — every term gone, no Trash, no undo.
    @State private var loadedDictionaryText: String = ""

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

    /// Whether a finished recording is transcribed automatically (opt-in; off
    /// means recordings wait in the list as "Untranscribed").
    @State private var autoTranscribe: Bool = false

    /// The microphone pick (a device UID; "" = Automatic) and the devices
    /// CoreAudio lists, refreshed while the window is open so a headset that
    /// connects shows up without reopening Settings.
    @State private var inputDeviceId: String = ""
    @State private var inputDevices: [InputDevice] = []

    /// Provider-reported account usage — the ONLY place money appears in the
    /// app. Both numbers come live from the providers (ElevenLabs subscription
    /// credits, OpenRouter credit balance); the covers row is the one tally
    /// Kleoth keeps itself (`coverTally`).
    @State private var elevenUsage: ElevenLabsUsage?
    @State private var openRouterCredits: OpenRouterCredits?
    @State private var usageError: String?
    @State private var isLoadingUsage = false
    /// Covers drawn in the last 30 days that cost something, added up from
    /// each meeting's `cover.json`. Kleoth's only tally of its own (spec
    /// §3.6): OpenRouter's per-model spend needs a management key.
    @State private var coverTally: CoverTally?

    /// Meeting covers (`SettingsCoversSection`): the engine ("off" or a
    /// `CoverEngine` raw value), the automatic toggle, the style ("auto" or a
    /// `CoverStyle` raw value) and the picked engine's image-model override.
    /// Here rather than in the section so `commitAll()` can flush an
    /// unsubmitted model edit.
    @State private var coverEngine: String = CoverEngine.offValue
    @State private var coverAutomatic: Bool = true
    @State private var coverStyle: String = "auto"
    @State private var coverModel: String = ""

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

    /// The selected sidebar page, remembered across openings.
    @AppStorage("dev.kleoth.settings.page") private var pageId: String = SettingsPage.meetings.rawValue
    @EnvironmentObject private var screenRecording: ScreenRecordingController

    private var page: SettingsPage { SettingsPage(rawValue: pageId) ?? .meetings }
    private var pageSelection: Binding<SettingsPage?> {
        Binding(get: { page }, set: { pageId = ($0 ?? .meetings).rawValue })
    }

    var body: some View {
        // A flat two-column layout — deliberately NOT a `NavigationSplitView`.
        // On macOS 26 a split view inside the Settings scene renders its sidebar
        // as a floating glass card under an empty toolbar band with a sidebar
        // toggle nobody needs (rejected on sight, 2026-09-20). System Settings
        // itself is a plain vibrant list beside a grouped form; so is this.
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail(for: page)
        }
        .navigationTitle(page.title)
        .frame(width: 780, height: 560)
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

    // MARK: - Sidebar + pages

    private var sidebar: some View {
        List(selection: pageSelection) {
            Section("Features") {
                ForEach(SettingsPage.features) { page in
                    Label(page.title, systemImage: page.systemImage).tag(page)
                }
            }
            Section("App") {
                ForEach(SettingsPage.app) { page in
                    Label(page.title, systemImage: page.systemImage).tag(page)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(width: 200)
        // The source-list vibrancy a split view's sidebar column would have
        // supplied; without it the list sits on the flat window grey.
        .background(SidebarMaterial().ignoresSafeArea())
    }

    /// One page: the page's sections in a grouped form, titled by the
    /// navigation bar. A banner-per-page cut with a serif title was rejected on
    /// sight (2026-09-10) — this window stays undecorated.
    private func detail(for page: SettingsPage) -> some View {
        Form {
            pageSections(page)
        }
        .formStyle(.grouped)
        .kleothSoftScrollEdge()
        .id(page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Switching provider (or Automatic landing somewhere else) changes what
        // the model controls below are editing — re-seed them from the stored
        // settings so they never show the previous provider's slug.
        .onChange(of: controller.providerStatus) { _, _ in syncProviderModels() }
    }

    /// The provider each task resolves to (nil until the first status lands).
    private func resolvedProvider(_ task: AIProvider.Task) -> AIProvider? {
        guard let status = controller.providerStatus else { return nil }
        let result = task == .summary ? status.summary : status.dictation
        if case let .success(selection) = result { return selection.provider }
        return nil
    }

    /// The model ids the local server currently lists.
    private var serverModels: [String] {
        if case let .available(_, models)? = controller.providerStatus?.snapshot[.localServer] { return models }
        return []
    }

    /// Re-reads both non-OpenRouter model fields from the STORED provider
    /// settings. Deliberately never `effectiveProviderSettings`: that one seeds
    /// OpenRouter's models from the legacy `default_model` / `dictation_model`
    /// keys, and persisting those into `ai_models` would pin a legacy slug on a
    /// provider that never had one.
    private func syncProviderModels() {
        let settings = controller.settings.providerSettings
        if let provider = resolvedProvider(.summary), provider != .openRouter {
            summaryProviderModel = settings.model(for: .summary, on: provider)
        }
        if let provider = resolvedProvider(.dictation), provider != .openRouter {
            dictationProviderModel = settings.model(for: .dictation, on: provider)
        }
    }

    /// Flushes one provider model field on close — but only when the user
    /// actually changed it. Comparing against `model(for:on:)` (the stored
    /// override, else the provider's own default) means an untouched field, and
    /// a value retyped to equal the default, both write nothing: an override
    /// nobody asked for would outlive any future change of that default.
    private func commitProviderModel(_ model: String, for task: AIProvider.Task) {
        guard let provider = resolvedProvider(task), provider != .openRouter,
              provider.modelChoice != .fixed,
              model != controller.settings.providerSettings.model(for: task, on: provider) else { return }
        controller.updateProviderModel(model, for: task, on: provider)
    }

    @ViewBuilder
    private func pageSections(_ page: SettingsPage) -> some View {
        switch page {
        case .meetings:
            localModelSection
            summarizationSection
            SettingsCoversSection(
                coverEngine: $coverEngine,
                coverAutomatic: $coverAutomatic,
                coverStyle: $coverStyle,
                coverModel: $coverModel
            )
            calendarSection
            historySection("Open Meetings", target: .meetings)
        case .dictation:
            SettingsDictationSection(
                dictationModel: $dictationModel,
                dictionaryText: $dictionaryText,
                availableModels: availableModels,
                provider: resolvedProvider(.dictation) ?? .openRouter,
                providerModel: $dictationProviderModel,
                serverModels: serverModels
            )
            historySection("Open Dictations", target: .dictations)
        case .screenRecording:
            SettingsScreenRecordingSection()
            screenRecordingActionsSection
        case .microphone:
            microphoneSection
        case .accounts:
            SettingsAIProviderSection(
                aiProvider: $aiProvider,
                localServerURL: $localServerURL,
                localServerKey: $localServerKey
            )
            credentialsSection
            usageSection
        case .general:
            outputSection
            shortcutsSection
            onboardingSection
        }
    }

    /// The way from a feature's settings to its records: one ordinary row.
    private func historySection(_ buttonTitle: String, target: HistoryTarget) -> some View {
        Section {
            LabeledContent("History") {
                Button(buttonTitle) { openHistory(target) }
            }
        }
    }

    private var screenRecordingActionsSection: some View {
        Section {
            LabeledContent("Record") {
                Button("Record Screen…") { screenRecording.start(from: .popover) }
            }
            LabeledContent("History") {
                Button("Open Recordings") { openHistory(.recordings) }
            }
        }
    }

    private enum HistoryTarget { case meetings, dictations, recordings }

    /// Opens the History window on a scope (the popover's idiom: bump the
    /// scope's request counter, which `HistoryView` observes, then open).
    private func openHistory(_ target: HistoryTarget) {
        switch target {
        case .meetings:
            HistoryRouting.requestedScope = .meetings
            controller.meetingsHistoryRequest += 1
        case .dictations:
            dictation.requestDictationHistory()
        case .recordings:
            HistoryRouting.requestedScope = .recordings
            screenRecording.recordingsHistoryRequest += 1
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "kleoth-history")
    }

    // MARK: - Sections

    private var credentialsSection: some View {
        Section {
            SecureField("ElevenLabs API key", text: $elevenLabsKey)
                .onSubmit { controller.updateElevenLabsKey(elevenLabsKey) }
            SecureField("OpenRouter API key (optional)", text: $openRouterKey)
                .onSubmit { controller.updateOpenRouterKey(openRouterKey) }
            LabeledContent("Get a key") {
                HStack(spacing: KleothMetrics.spacingM) {
                    if let url = URL(string: "https://elevenlabs.io/app/settings/api-keys") {
                        Link("ElevenLabs", destination: url)
                    }
                    if let url = URL(string: "https://openrouter.ai/settings/keys") {
                        Link("OpenRouter", destination: url)
                    }
                }
            }
        } header: {
            Text("Credentials")
        } footer: {
            captionFooter("Stored in your macOS Keychain and never logged. ElevenLabs powers cloud transcription; OpenRouter is one of the AI providers above.")
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
            Text("Output")
        } footer: {
            captionFooter(outputFooterText)
        }
    }

    /// The output footer, with a live "N meetings · X on disk" tally appended
    /// once folder sizes have resolved (they're computed in the background, so
    /// the plain caption shows until at least one size is known).
    private var outputFooterText: String {
        let base = "Each meeting is written to its own folder here — audio, transcript, summary, and metadata you own."
        let meetings = controller.recentMeetings
        let bytes = meetings.compactMap(\.sizeBytes).reduce(0, +)
        guard let size = MeetingFormat.fileSize(bytes) else { return base }
        let count = meetings.count == 1 ? "1 meeting" : "\(meetings.count) meetings"
        return "\(base) \(count) · \(size) on disk."
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

            Toggle("Transcribe automatically after recording", isOn: $autoTranscribe)
                .onChange(of: autoTranscribe) { _, newValue in
                    controller.updateAutoTranscribe(newValue)
                }
        } header: {
            Text("On-device transcription")
        } footer: {
            captionFooter("Kleoth transcribes locally on the Apple Neural Engine — free, private, offline, and multilingual. The model downloads once (~626 MB) and is cached on this Mac. Leave Language on Auto-detect, or pin one if detection ever guesses wrong. With automatic transcription off, finished recordings wait in the list as Untranscribed until you choose an engine.")
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
            // OpenRouter is the only provider with a catalog to pick from; every
            // other one gets the control its `modelChoice` asks for.
            let provider = resolvedProvider(.summary) ?? .openRouter
            if provider == .openRouter {
                Picker("Default model", selection: $selectedModel) {
                    ForEach(availableModels, id: \.self) { model in
                        Text(modelLabel(model)).tag(model)
                    }
                }
                .onChange(of: selectedModel) { _, newValue in
                    controller.updateDefaultModel(newValue)
                }
            } else {
                ProviderModelField(title: "Model", provider: provider, task: .summary,
                                   model: $summaryProviderModel, serverModels: serverModels)
            }
        } header: {
            HStack(spacing: KleothMetrics.spacingS) {
                Text("Summarization")
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
            captionFooter(summarizationFooterText)
        }
    }

    /// Names the provider summaries resolve to, so the model control above it
    /// never looks like OpenRouter's when another provider is in charge.
    private var summarizationFooterText: String {
        switch resolvedProvider(.summary) ?? .openRouter {
        case .openRouter: "The models your OpenRouter account's data policy allows. Choose the provider in Accounts."
        case .localServer: "Summaries run on your local server. Choose the provider in Accounts."
        case let provider: "Summaries run on \(provider.displayName). Choose the provider in Accounts."
        }
    }

    /// Account usage as reported live by the providers — deliberately the only
    /// money surface in the app. ElevenLabs reports its billing-cycle credit
    /// quota, OpenRouter its credit balance; the one number Kleoth computes is
    /// the covers row, a sum of what OpenRouter reported for each cover.
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
                if let tally = coverTally, tally.covers > 0, tally.cost > 0 {
                    coversUsageRow(tally)
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
                Text("Usage")
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
            captionFooter("Account-wide numbers reported live by ElevenLabs and OpenRouter; the covers row adds up what OpenRouter reported for each cover.")
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

    /// "Meeting covers · $0.41 in the last 30 days (12 covers)". Only covers
    /// that cost something are counted, so Codex and local-server covers never
    /// show here; the caller hides the row when the window's total is zero.
    private func coversUsageRow(_ tally: CoverTally) -> some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
            Text("Meeting covers")
                .font(.callout.weight(.medium))
            Text("\(Self.money(tally.cost)) in the last 30 days (\(tally.covers) cover\(tally.covers == 1 ? "" : "s"))")
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
        // The covers tally is local, cheap and synchronous (one small
        // `cover.json` read per meeting), so it runs ahead of the key guard.
        // Its row still shows only beside the provider rows: covers cost money
        // only on OpenRouter, which needs a key anyway.
        coverTally = CoverStore().tally(
            meetingDirs: controller.recentMeetings.map(\.directory),
            since: Date().addingTimeInterval(-30 * 86_400)
        )
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

    /// The one microphone setting, honoured by meeting recordings, dictation
    /// and screen recordings (the pill's Microphone submenu writes the same
    /// value). A pick that is not connected stays selectable, says so, and
    /// falls back to the system input at capture time.
    private var microphoneSection: some View {
        Section {
            Picker("Microphone", selection: $inputDeviceId) {
                Text("Automatic").tag("")
                ForEach(inputDevices) { device in
                    Text(device.name).tag(device.id)
                }
                if !inputDeviceId.isEmpty, !inputDevices.contains(where: { $0.id == inputDeviceId }) {
                    Text("Not connected").tag(inputDeviceId)
                }
            }
            .onChange(of: inputDeviceId) { _, newValue in
                dictation.setInputDevice(newValue.isEmpty ? nil : newValue)
            }
            // Devices come and go (a headset connecting) and CoreAudio posts
            // nothing SwiftUI can observe, so poll gently while the window is
            // open — the dictation section's trust-poll idiom.
            .task {
                while !Task.isCancelled {
                    let devices = InputDevices.list()
                    if devices != inputDevices { inputDevices = devices }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        } header: {
            Text("Microphone")
        } footer: {
            captionFooter("Used for meetings, dictation and screen recordings. Automatic follows the system input; a microphone that is not connected falls back to it.")
        }
    }

    private var shortcutsSection: some View {
        Section {
            KeyboardShortcuts.Recorder("Start / stop recording:", name: .toggleRecording)
        } header: {
            Text("Shortcuts")
        } footer: {
            captionFooter("Scripts and launchers can do the same with kleoth://toggle.")
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
            Text("Calendar")
        } footer: {
            captionFooter("When enabled, a recording started during a calendar event takes that event's title.")
        }
    }

    /// Replays the first-run setup (welcome, name, permissions, model + language,
    /// and the start-recording finish). Opening it does not reset any state — it's
    /// purely a way back into the guided setup.
    private var onboardingSection: some View {
        Section {
            Button("Show Welcome Window") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "kleoth-onboarding")
            }
        } header: {
            Text("Onboarding")
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
        // disk cache, else the curated list. Both picker selections are pinned,
        // so neither the summary model nor the dictation polish model can vanish
        // from its picker and silently reset.
        let models = await catalog.fetch(
            transport: URLSessionTransport(),
            keepingAll: [selectedModel, dictationModel]
        )
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
        autoTranscribe = controller.settings.autoTranscribe
        dictationModel = dictation.dictationModel
        dictionaryText = PersonalDictionaryStore.render(dictation.dictionaryTerms())
        loadedDictionaryText = dictionaryText
        inputDevices = InputDevices.list()
        inputDeviceId = dictation.inputDeviceId ?? ""
        aiProvider = controller.settings.providerSettings.pick?.rawValue ?? "auto"
        localServerURL = controller.settings.providerSettings.localServerURL.absoluteString
        localServerKey = controller.settings.providerSettings.localServerKey ?? ""
        syncProviderModels()
        // Meeting covers. The model field shows the stored override, never the
        // engine's default (that is its placeholder): `commitAll()` writes the
        // field only when it differs from the override, so an untouched field
        // writes nothing.
        let covers = controller.settings.coverSettings
        coverEngine = covers.engineStorageValue
        coverAutomatic = covers.automatic
        coverStyle = covers.styleStorageValue
        coverModel = covers.engine.map { covers.models[$0] ?? "" } ?? ""

        // Migrate a stored model whose provider 404s under this account's
        // no-train policy (e.g. the obsolete "openai/gpt-4.1-mini") or that has
        // simply been retired upstream, and PERSIST it so it stops reappearing.
        // `AppConfig.migrating` already rewrites it in memory on every load;
        // this is the one place the Keychain itself gets cleaned up.
        if Self.needsModelMigration(selectedModel) {
            selectedModel = ModelCatalog.defaultModel
            controller.updateDefaultModel(selectedModel)
        }
        // The polish slot also retires former polish defaults that are merely
        // slow (`DictationDefaults.retiredPolishModels`), not just dead ones.
        let migratedPolish = Self.isBlockedModel(dictationModel)
            ? DictationDefaults.polishModel
            : DictationDefaults.migratingPolishModel(dictationModel)
        if migratedPolish != dictationModel {
            dictationModel = migratedPolish
            dictation.setDictationModel(dictationModel)
        }

        // Seed the picker synchronously for first paint / offline; `.task` then
        // refreshes from the live feed. The filter keeps the default + both
        // current selections.
        availableModels = ModelCatalog.filtered(
            from: ModelCatalog.curatedFallback,
            keepingAll: [selectedModel, dictationModel]
        )
    }

    /// Whether a stored slug must be rewritten: its provider prefix 404s under
    /// the no-train policy, or `ModelCatalog` maps it away as retired. The
    /// prefix list stays — it also covers slugs `retiredModels` doesn't name.
    private static func needsModelMigration(_ slug: String) -> Bool {
        isBlockedModel(slug) || ModelCatalog.migrating(slug) != slug
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
        // The provider picker and the model pickers commit when they are
        // operated; the free-text fields only commit on Return, so an
        // unsubmitted edit lands here.
        controller.updateLocalServerURL(localServerURL)
        controller.updateLocalServerKey(localServerKey)
        commitProviderModel(summaryProviderModel, for: .summary)
        commitProviderModel(dictationProviderModel, for: .dictation)
        // The cover pickers commit when operated; the image-model field only on
        // Return. Compared trimmed, as `CoverSettings.settingModel` stores it,
        // so a stray space is not an edit.
        if let engine = CoverEngine(rawValue: coverEngine), engine.takesModel,
           coverModel.trimmingCharacters(in: .whitespacesAndNewlines)
               != (controller.settings.coverSettings.models[engine] ?? "") {
            controller.updateCoverModel(coverModel, for: engine)
        }
        dictation.setDictationModel(dictationModel)
        // Flushes whatever the dictionary editor's 0.5 s debounce hasn't written —
        // but only if the user actually edited it (see `loadedDictionaryText`).
        if dictionaryText != loadedDictionaryText {
            dictation.saveDictionaryTerms(PersonalDictionaryStore.parse(text: dictionaryText))
        }
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

/// The sidebar's vibrant source-list backdrop (`NSVisualEffectView` with the
/// `.sidebar` material, behind-window blending) — what AppKit draws under a
/// split view's sidebar column, wrapped so a plain `HStack` gets the same look.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
