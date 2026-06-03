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
            KleothMenuBarLabel(isRecording: controller.isRecording)
        }
        .menuBarExtraStyle(.window)

        // Resizable window for browsing all meetings (opened from the popover).
        Window("Meeting History", id: "kleoth-history") {
            HistoryView()
                .environmentObject(controller)
        }
        .defaultSize(width: 960, height: 640)

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
private struct KleothMenuBarLabel: View {
    let isRecording: Bool

    var body: some View {
        if isRecording {
            Image(systemName: "record.circle")
        } else if let glyph = KleothAssets.menuBarGlyph() {
            Image(nsImage: glyph)
        } else {
            Image(systemName: "waveform")
        }
    }
}
