import SwiftUI

/// Menu-bar agent entry point.
///
/// Presents a `MenuBarExtra` whose icon reflects recording state, plus a
/// standard `Settings` scene. The single `RecordingController` is created here
/// and shared into every view via the environment so a recording survives any
/// view being torn down. The `DictationController` (fn+shift dictation) is
/// created the same way and injected alongside it — dictation views read it
/// via `@EnvironmentObject`, never through `DictationController.shared`. The
/// `ScreenRecordingController` is created and injected the same way.
///
/// - Note: As a menu-bar `LSUIElement` agent this needs an app bundle with the
///   appropriate `Info.plist` and TCC usage descriptions to run; it compiles
///   under Command Line Tools but will not fully launch as a bare executable.
///
/// Started by `KleothMain` (`AppMain.swift`), which runs a `-KleothDemo`
/// launch without any of this.
struct KleothApp: App {
    @StateObject private var controller = RecordingController()
    @StateObject private var dictation = DictationController()
    @StateObject private var screenRecording = ScreenRecordingController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(controller)
                .environmentObject(dictation)
                .environmentObject(screenRecording)
        } label: {
            // The menu-bar label is the only view mounted at launch, so it's the
            // single place with a live SwiftUI environment from which the
            // first-run onboarding window can be opened (`@Environment(\.openWindow)`
            // is unavailable from `App.init` / the `AppDelegate`). It self-opens the
            // welcome window shortly after launch when this is a fresh install.
            KleothMenuBarLabel(
                // A hot microphone must always have a menu-bar indicator: the
                // pill can be on a display the user is not looking at (§2.3).
                isRecording: controller.isRecording || screenRecording.isActive,
                needsOnboarding: controller.needsOnboarding,
                historyRequest: dictation.dictationsHistoryRequest,
                consentRequest: controller.consentRequest
            )
        }
        .menuBarExtraStyle(.window)

        // Resizable window for browsing all meetings (opened from the popover).
        Window("Meeting History", id: "kleoth-history") {
            HistoryView()
                .environmentObject(controller)
                .environmentObject(dictation)
                .environmentObject(screenRecording)
        }
        .defaultSize(width: 960, height: 640)

        // First-run onboarding. A fixed-size window (the step machine lays itself
        // out at exactly this size) opened automatically on a fresh install and
        // re-openable from Settings → "Show Welcome Window".
        Window("Welcome to Kleoth", id: "kleoth-onboarding") {
            OnboardingView()
                .environmentObject(controller)
                .environmentObject(dictation)
                .environmentObject(screenRecording)
        }
        .defaultSize(width: 560, height: 600)
        .windowResizability(.contentSize)

        // Recording consent for a start refused away from the popover (the
        // global hotkey, `kleoth://record|toggle`, the Start Recording intent):
        // the menu-bar label opens it on `RecordingController.consentRequest`.
        // Sized by its content, like onboarding.
        Window("Before you record", id: "kleoth-consent") {
            ConsentView(startsRecording: true)
                .environmentObject(controller)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(controller)
                .environmentObject(dictation)
                .environmentObject(screenRecording)
        }
    }
}

/// The menu-bar item's icon: the custom Kleoth lyre template glyph at rest, and
/// the system record symbol while capturing (both monochrome templates that
/// follow the menu bar's appearance). Falls back to an SF Symbol if the bundled
/// glyph is unavailable.
///
/// This view doubles as the launch hook for first-run onboarding: as the only
/// view mounted at launch it has the live SwiftUI environment that
/// `@Environment(\.openWindow)` requires (`App.init` and the `AppDelegate` don't),
/// so its `.task` opens the welcome window once, after a short beat, when this is
/// a fresh install (and the consent window, when a refusal came before it
/// mounted). For the same reason it opens windows that controllers ask for
/// through request counters (`historyRequest`, `consentRequest`).
private struct KleothMenuBarLabel: View {
    let isRecording: Bool
    let needsOnboarding: Bool
    /// `DictationController.dictationsHistoryRequest` — the pill menu's
    /// "Dictation history…" needs a window opened from a controller that has
    /// no SwiftUI environment, and this label always has one.
    let historyRequest: Int
    /// `RecordingController.consentRequest` — bumped when `start()` refuses
    /// for missing consent. The hotkey, `kleoth://` links and the Start intent
    /// have no view of their own to show that refusal in.
    let consentRequest: Int

    /// The last `consentRequest` a consent window was opened for, so no
    /// refusal is answered twice. `.task` runs each time this label appears —
    /// nothing guarantees that is once a launch — and a re-run must not bring
    /// back a window the user already closed. Static rather than `@State`, so
    /// a re-mount can't reset it either (the `HistoryRouting` idiom).
    @MainActor private static var answeredConsentRequest = 0

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon
            .task {
                // SwiftUI `onChange` never fires for the value a view MOUNTS
                // with, so a consent refusal from before this label existed —
                // a `kleoth://record` link or the Start intent that launched
                // Kleoth — never reaches `onChange(of: consentRequest)` below.
                // The mount value catches it: a count above the last one
                // answered is a refusal no window has shown yet.
                let consentPending = consentRequest > Self.answeredConsentRequest
                guard needsOnboarding || consentPending else { return }
                // A brief beat lets the menu-bar item settle and the scene graph
                // finish mounting before we present a window, so the welcome
                // window reliably comes to the front on first launch.
                try? await Task.sleep(for: .milliseconds(500))
                // Consent first, so a fresh install's welcome window opens on
                // top of it: onboarding asks for consent too, and the consent
                // window closes by itself once a recording starts.
                if consentPending { openConsentWindow(for: consentRequest) }
                guard needsOnboarding else { return }
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "kleoth-onboarding")
            }
            .onChange(of: historyRequest) { _, _ in
                // `HistoryView` observes the same counter and flips its scope
                // to Dictations; this only puts the window on screen.
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "kleoth-history")
            }
            .onChange(of: consentRequest) { _, request in openConsentWindow(for: request) }
    }

    /// Brings the "Before you record" window forward for refusal number
    /// `request` — one that arrives while this label is mounted (`onChange`)
    /// or one from before it mounted (`.task`) — unless a window was already
    /// opened for it. `ConsentView(startsRecording: true)` takes it from there:
    /// it acknowledges, starts, and closes once the recording runs. A repeat
    /// refusal carries a new count, so an open window comes back to the front.
    private func openConsentWindow(for request: Int) {
        guard request > Self.answeredConsentRequest else { return }
        Self.answeredConsentRequest = request
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "kleoth-consent")
    }

    @ViewBuilder
    private var icon: some View {
        if isRecording {
            Image(systemName: "record.circle")
        } else if let glyph = KleothAssets.menuBarGlyph() {
            Image(nsImage: glyph)
        } else {
            Image(systemName: "waveform")
        }
    }
}
