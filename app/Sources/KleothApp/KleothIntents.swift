import AppIntents
import Foundation

// App Intents expose Kleoth's actions to Shortcuts, Spotlight (macOS 26 runs
// them directly), Siri, and Focus automations — and are reachable from Raycast
// by running the generated Shortcut. Each intent runs in-process against the
// shared RecordingController, so it has the app's Keychain credentials and the
// live capture session (no CLI credential split). `openAppWhenRun` launches the
// menu-bar agent first if it isn't already running.
//
// DISCOVERY CAVEAT: for these to AUTO-SURFACE in Shortcuts/Spotlight/Siri, the
// app needs an App Intents *metadata* bundle (`Metadata.appintents`) produced by
// `appintentsmetadataprocessor` from Swift const-value extraction. Xcode runs
// that as a build phase; the SwiftPM `make-app.sh` bundling path does NOT, so
// from that build the intents are present but not yet discoverable. The
// kleoth:// URL scheme, the global hotkey, and the Raycast scripts need no
// metadata and work today. To enable Shortcuts discovery, build the app target
// through an Xcode project (or add a metadata-extraction step to make-app.sh).

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Kleoth Recording"
    static let description = IntentDescription("Start recording system + microphone audio for a meeting.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = RecordingController.shared else {
            return .result(dialog: "Kleoth isn't ready yet — open it and try again.")
        }
        await controller.start()
        return .result(dialog: IntentDialog(stringLiteral: controller.statusMessage))
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Kleoth Recording"
    static let description = IntentDescription("Stop the current recording and transcribe it.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = RecordingController.shared else {
            return .result(dialog: "Kleoth isn't running.")
        }
        // `stop()` returns once capture is finalized and processing is queued in
        // the background — its message describes that, not the eventual result.
        let outcome = await controller.stop()
        return .result(dialog: IntentDialog(stringLiteral: outcome))
    }
}

struct SummarizeLatestIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Latest Kleoth Meeting"
    static let description = IntentDescription("Summarize the most recent meeting with the configured model.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let controller = RecordingController.shared else {
            return .result(dialog: "Kleoth isn't ready yet.")
        }
        await controller.summarizeLatestMeeting()
        return .result(dialog: IntentDialog(stringLiteral: controller.statusMessage))
    }
}

struct LatestTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Kleoth Transcript"
    static let description = IntentDescription("Return the transcript of the most recent meeting.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let text = RecordingController.shared?.latestTranscriptText(), !text.isEmpty else {
            return .result(value: "", dialog: "No transcript found yet.")
        }
        return .result(value: text, dialog: "Here's the latest transcript.")
    }
}

/// Surfaces the intents in Shortcuts / Spotlight / Siri automatically.
struct KleothAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start recording with \(.applicationName)", "\(.applicationName) start recording"],
            shortTitle: "Start Recording",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: ["Stop recording with \(.applicationName)", "\(.applicationName) stop recording"],
            shortTitle: "Stop & Transcribe",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: SummarizeLatestIntent(),
            phrases: ["Summarize the latest \(.applicationName) meeting", "\(.applicationName) summarize latest"],
            shortTitle: "Summarize Latest",
            systemImageName: "text.append"
        )
        AppShortcut(
            intent: LatestTranscriptIntent(),
            phrases: ["Get the latest \(.applicationName) transcript", "\(.applicationName) latest transcript"],
            shortTitle: "Latest Transcript",
            systemImageName: "doc.text"
        )
    }
}
