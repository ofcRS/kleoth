import Foundation

/// `-KleothDemo <folder>`: a launch that renders the README's meeting and
/// recordings-viewer films from the app's own windows over demo data, and
/// touches nothing of the user's (design: `docs/plans/2026-09-24-demo-mode.md`).
///
/// `app/branding-src/demo/make-app-demos.sh` runs it from a temporary copy
/// of the app with its own bundle id (`dev.kleoth.demo`), so a demo run has
/// its own defaults, saved state and privacy grants. This flag is the second
/// layer, in code. When it is set:
/// - `Keychain` reads a fixed in-memory seed and never calls `SecItem*`;
/// - `AppConfig` points every folder at `<folder>` and hands out no API keys;
/// - `AppDelegate` installs no hotkey or pill and runs no launch sweep, and
///   hands the launch to `DemoDirector`;
/// - there is no menu-bar item, provider detection, model download or
///   activation-policy change.
///
/// Read from the argument domain alone, like `-KleothSimulateFirstRun`, so a
/// `defaults write` can never leave a real install in demo mode. Nonisolated
/// and immutable: the Keychain reads it from any thread.
enum DemoMode {
    /// The flag alone decides: a demo launch with a bad folder is still gated
    /// everywhere, and `DemoDirector` quits it — it never falls through to a
    /// normal launch.
    static let isOn: Bool = argument("KleothDemo") != nil

    /// The demo data folder, standing in for `~/Kleoth`: nil unless the flag
    /// holds an absolute path.
    static let folder: URL? = path("KleothDemo")

    /// What every `outputDir` reads in demo mode. Never the real `~/Kleoth`,
    /// even when the folder argument is unusable.
    static var outputDir: URL {
        folder ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kleoth-demo-unset", isDirectory: true)
    }

    /// Where `DemoDirector` writes the film (`-KleothDemoFilm <dir>`).
    static let filmDirectory: URL? = path("KleothDemoFilm")

    /// Which film to shoot (`-KleothDemoScript meeting|viewer|still`).
    static let script: String? = argument("KleothDemoScript")

    /// The only Keychain a demo launch sees: consent and onboarding done,
    /// output in the demo folder, dictation and auto-transcribe off, the AI
    /// provider on Automatic (so the one-time provider migration never runs),
    /// and no keys.
    static var keychainSeed: [String: String] {
        [
            Keychain.Account.consentAcknowledged: "true",
            Keychain.Account.onboardingCompleted: "true",
            Keychain.Account.outputDir: outputDir.path,
            Keychain.Account.autoTranscribe: "false",
            Keychain.Account.dictationEnabled: "false",
            Keychain.Account.aiProvider: "auto",
        ]
    }

    /// Posted by `DemoDirector` to start playback in the recordings viewer —
    /// the one thing its script cannot reach through a controller.
    static let playNotification = Notification.Name("dev.kleoth.demo.play")

    private static func argument(_ key: String) -> String? {
        let value = UserDefaults.standard
            .volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// An absolute path argument. A relative one is refused rather than
    /// resolved against a working directory nobody chose.
    private static func path(_ key: String) -> URL? {
        guard let value = argument(key) else { return nil }
        let expanded = (value as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
}
