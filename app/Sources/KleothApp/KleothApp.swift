import SwiftUI

/// Menu-bar agent entry point.
///
/// Presents a `MenuBarExtra` whose icon reflects recording state, plus a
/// standard `Settings` scene. The single `RecordingController` is created here
/// and shared into every view via the environment so a recording survives any
/// view being torn down.
///
/// - Note: As a menu-bar `LSUIElement` agent this needs an app bundle with the
///   appropriate `Info.plist` and TCC usage descriptions to run; it compiles
///   under Command Line Tools but will not fully launch as a bare executable.
@main
struct KleothApp: App {
    @StateObject private var controller = RecordingController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(controller)
        } label: {
            // The menu-bar label is the only view mounted at launch, so it's the
            // single place with a live SwiftUI environment from which the
            // first-run onboarding window can be opened (`@Environment(\.openWindow)`
            // is unavailable from `App.init` / the `AppDelegate`). It self-opens the
            // welcome window shortly after launch when this is a fresh install.
            KleothMenuBarLabel(
                isRecording: controller.isRecording,
                needsOnboarding: controller.needsOnboarding
            )
        }
        .menuBarExtraStyle(.window)

        // Resizable window for browsing all meetings (opened from the popover).
        Window("Meeting History", id: "kleoth-history") {
            HistoryView()
                .environmentObject(controller)
        }
        .defaultSize(width: 960, height: 640)

        // First-run onboarding. A fixed-size window (the step machine lays itself
        // out at exactly this size) opened automatically on a fresh install and
        // re-openable from Settings → "Show Welcome Window".
        Window("Welcome to Kleoth", id: "kleoth-onboarding") {
            OnboardingView()
                .environmentObject(controller)
        }
        .defaultSize(width: 560, height: 600)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(controller)
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
/// a fresh install.
private struct KleothMenuBarLabel: View {
    let isRecording: Bool
    let needsOnboarding: Bool

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon
            .task {
                guard needsOnboarding else { return }
                // A brief beat lets the menu-bar item settle and the scene graph
                // finish mounting before we present a window, so the welcome
                // window reliably comes to the front on first launch.
                try? await Task.sleep(for: .milliseconds(500))
                guard needsOnboarding else { return }
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "kleoth-onboarding")
            }
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
