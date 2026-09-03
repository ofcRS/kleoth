import AppKit
import Foundation
import KleothCore

// ============================================================================
// T0 STUB — replaced wholesale by T8 (design doc §3.18 / §5.10).
//
// Exposes the full §3.18 API with no-op bodies so every view / lane compiles
// against the real surface from day one. Settings-facing setters persist to the
// Keychain and update the published mirrors (so the Settings section built in
// T5 behaves sensibly), but nothing installs a hotkey monitor, records, or
// pastes. `shared` is set by the production `convenience init()`.
// ============================================================================

/// Owns a dictation session end to end: hotkey → capture → STT → polish →
/// insert → log → pill. Internal, not `public`: it lives in an executable
/// target where `public` buys nothing.
@MainActor
final class DictationController: ObservableObject {
    private(set) static var shared: DictationController?

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isTrusted: Bool
    @Published private(set) var isMonitoring: Bool
    @Published private(set) var dictationModel: String
    /// True from `.began`/`.toggledOn` until `endSession()` (listening or pipeline in flight).
    @Published private(set) var isSessionActive: Bool = false
    /// Bumped AFTER `await logStore.append` returns (the row is on disk); DictationsListView reloads on change.
    @Published private(set) var logRevision: Int = 0

    let logStore: DictationLogStore

    private let monitor: any DictationHotkeyMonitoring
    private let pill: any DictationPillPresenting
    private let inserter: any TextInserting
    private let dictionary: PersonalDictionaryStore
    /// The STT seam. nil in production → `makeTranscriber(elevenLabsKey:)` builds a
    /// `ScribeClient` per run (the key can change in Settings between dictations).
    /// Injected by the `dictate` probe / tests.
    private let injectedTranscriber: (any Transcriber)?

    /// Short-timeout session: `URLSessionTransport.defaultSession` waits 1200 s between bytes.
    private let transport = URLSessionTransport(session: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }())

    // MARK: - Init

    /// Production init (used by KleothApp.swift). Sets `shared`. `transcriber` nil → `ScribeClient`
    /// built per run from the current ElevenLabs key (see `makeTranscriber`).
    convenience init() {
        let settings = AppConfig.settings()
        self.init(
            monitor: StubHotkeyMonitor(),
            pill: StubPill(),
            inserter: StubInserter(),
            logStore: DictationLogStore(outputDir: settings.outputDir),
            dictionary: PersonalDictionaryStore(),
            transcriber: nil
        )
        Self.shared = self
    }

    /// Injected init (dictate probe / future tests). `transcriber` is THE seam the scope asks for:
    /// pass any `Transcriber` (a fake, or later `ScribeRealtimeTranscriber`) and `run()` uses it
    /// verbatim — cost logging reads `usdPerHour` from it.
    init(
        monitor: any DictationHotkeyMonitoring,
        pill: any DictationPillPresenting,
        inserter: any TextInserting,
        logStore: DictationLogStore,
        dictionary: PersonalDictionaryStore,
        transcriber: (any Transcriber)? = nil
    ) {
        let settings = AppConfig.settings()
        self.monitor = monitor
        self.pill = pill
        self.inserter = inserter
        self.logStore = logStore
        self.dictionary = dictionary
        self.injectedTranscriber = transcriber
        self.isEnabled = settings.dictationEnabled
        self.isTrusted = AccessibilityPermission.isTrusted
        self.isMonitoring = false
        self.dictationModel = settings.dictationModel
    }

    /// Default engine factory; the only place `ScribeClient` is named in this file.
    private func makeTranscriber(elevenLabsKey: String) -> any Transcriber {
        ScribeClient(apiKey: elevenLabsKey, transport: transport)
    }

    // MARK: - Lifecycle

    /// AppDelegate.applicationDidFinishLaunching (via MainActor.assumeIsolated).
    func startIfEnabled() {}

    /// applicationWillTerminate: cancel(); monitor.stop(); eventTask?.cancel()
    func shutdown() {}

    /// didBecomeActive; reinstalls monitors on grant.
    func refreshTrust() {
        isTrusted = AccessibilityPermission.isTrusted
    }

    /// Esc / pill ✕ / external.
    func cancel() {}

    // MARK: - Settings surface

    /// Keychain + (un)install; prompts for Accessibility when turning on untrusted.
    func setEnabled(_ on: Bool) {
        Keychain.set(on ? "true" : "false", Keychain.Account.dictationEnabled)
        isEnabled = on
    }

    func setDictationModel(_ slug: String) {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? DictationDefaults.polishModel : ModelCatalog.migrating(trimmed)
        Keychain.set(resolved, Keychain.Account.dictationModel)
        dictationModel = resolved
    }

    /// promptIfNeeded + refreshTrust.
    func requestAccessibility() {
        AccessibilityPermission.promptIfNeeded()
        refreshTrust()
    }

    func resetPillPosition() {
        pill.resetPosition()
    }

    // MARK: - Dictionary + log surfaces (views touch one object)

    func dictionaryTerms() -> [String] {
        dictionary.load()
    }

    func saveDictionaryTerms(_ terms: [String]) {
        try? dictionary.save(terms)
    }

    /// Sync: nonisolated store reads.
    func loadDictations(limit: Int = 500) -> [DictationLogEntry] {
        logStore.loadAll(limit: limit)
    }

    /// Hops to the store actor; bumps logRevision.
    func deleteDictations(ids: Set<String>) async throws {
        _ = try await logStore.delete(ids: ids)
        logRevision += 1
    }
}

// MARK: - No-op collaborators for the production init (T0 stub only)
//
// T8 swaps these for `DictationHotkeyMonitor` (T1), `DictationPillController`
// (T6) and `TextInserter.shared` (T7).

@MainActor
private final class StubHotkeyMonitor: DictationHotkeyMonitoring {
    let events: AsyncStream<DictationHotkeyEvent> = AsyncStream { _ in }
    private(set) var isRunning = false
    var escapeCancels = false

    @discardableResult
    func start() -> Bool { false }
    func stop() {}
    func abort() {}
}

@MainActor
private final class StubPill: DictationPillPresenting {
    var onAction: ((DictationPillAction) -> Void)?
    var onDismiss: (() -> Void)?

    func show(_ state: DictationPillState) {}
    func setLevel(_ level: Double) {}
    func dismiss() {}
    func resetPosition() {}
}

@MainActor
private final class StubInserter: TextInserting {
    @discardableResult
    func insert(_ text: String, pressTimeTarget: DictationTarget) async throws -> DictationTarget {
        pressTimeTarget
    }
}

// ============================================================================
// TEMPORARY PLACEHOLDERS — DELETE THIS WHOLE SECTION WHEN T1 / T5 LAND.
//
// The contract (§3.14) and the §3.18 API reference four KleothCore types that
// other lanes own and that do not exist yet in this tree:
//   • `DictationHotkeyEvent`                    → T1, KleothCore/Dictation/DictationChordMachine.swift
//   • `DictationLogEntry`, `DictationInsertMethod` → T5, KleothCore/Dictation/DictationLogEntry.swift
//   • `DictationLogStore`                       → T5, KleothCore/Dictation/DictationLogStore.swift
//   • `PersonalDictionaryStore`                 → T5, KleothCore/Dictation/PersonalDictionaryStore.swift
// Without stand-ins the app package cannot build (a T0 acceptance bullet). They
// are declared here — inside the file T8 rewrites wholesale — with the exact
// public shapes from §3.2 / §3.8–3.10 and trivial bodies. Because they live in
// the KleothApp module they SHADOW the KleothCore versions once those exist:
// a type-mismatch or "cannot convert" error mentioning both `KleothApp.X` and
// `KleothCore.X` means this section is overdue for deletion.
// ============================================================================

enum DictationHotkeyEvent: Sendable, Equatable {
    case armed
    case began
    case ended
    case toggledOn
    case toggledOff
    case cancelled(CancelReason)
    case escapePressed

    enum CancelReason: Sendable, Equatable {
        case tooShort
        case otherKey
        case external
    }
}

enum DictationInsertMethod: String, Codable, Sendable {
    case paste
    case clipboard
}

struct DictationLogEntry: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var timestamp: String
    var appBundleId: String?
    var appName: String?
    var language: String?
    var rawText: String
    var polishedText: String
    var usedRawFallback: Bool
    var fallbackReason: String?
    var transcriptionModel: String?
    var polishModel: String?
    var durationSeconds: Double?
    var insertMethod: DictationInsertMethod
    var transcriptionCost: Double?
    var polishCost: Double?

    init(
        id: String = UUID().uuidString, timestamp: String,
        appBundleId: String? = nil, appName: String? = nil, language: String? = nil,
        rawText: String, polishedText: String, usedRawFallback: Bool = false,
        fallbackReason: String? = nil, transcriptionModel: String? = nil,
        polishModel: String? = nil, durationSeconds: Double? = nil,
        insertMethod: DictationInsertMethod = .paste,
        transcriptionCost: Double? = nil, polishCost: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appBundleId = appBundleId
        self.appName = appName
        self.language = language
        self.rawText = rawText
        self.polishedText = polishedText
        self.usedRawFallback = usedRawFallback
        self.fallbackReason = fallbackReason
        self.transcriptionModel = transcriptionModel
        self.polishModel = polishModel
        self.durationSeconds = durationSeconds
        self.insertMethod = insertMethod
        self.transcriptionCost = transcriptionCost
        self.polishCost = polishCost
    }

    var date: Date? {
        ISO8601DateFormatter().date(from: timestamp)
    }

    static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

actor DictationLogStore {
    nonisolated let baseDir: URL

    init(outputDir: URL) {
        baseDir = outputDir.appendingPathComponent(DictationDefaults.logDirectoryName, isDirectory: true)
    }

    static func dayFileName(for date: Date, calendar: Calendar = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date) + ".json"
    }

    @discardableResult
    func append(_ entry: DictationLogEntry, on date: Date = Date()) throws -> URL {
        dayFileURL(named: Self.dayFileName(for: date))
    }

    nonisolated func loadDay(named day: String) -> [DictationLogEntry] { [] }
    nonisolated func loadAll(limit: Int = 500) -> [DictationLogEntry] { [] }
    nonisolated func availableDays() -> [String] { [] }
    nonisolated func dayFileURL(named day: String) -> URL {
        baseDir.appendingPathComponent(day.hasSuffix(".json") ? day : day + ".json")
    }

    @discardableResult
    func delete(ids: Set<String>) throws -> Int { 0 }
}

struct PersonalDictionaryStore: Sendable {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("kleoth", isDirectory: true)
            .appendingPathComponent("dictionary.json")
    }

    let url: URL

    init(url: URL = PersonalDictionaryStore.defaultURL) {
        self.url = url
    }

    func load() -> [String] { [] }
    func save(_ terms: [String]) throws {}

    static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == DictationDefaults.maxStoredDictionaryTerms { break }
        }
        return result
    }

    static func parse(text: String) -> [String] {
        normalize(text.split(whereSeparator: \.isNewline).map(String.init))
    }

    static func render(_ terms: [String]) -> String {
        terms.joined(separator: "\n")
    }
}
