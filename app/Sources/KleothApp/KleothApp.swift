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

    var body: some Scene {
        MenuBarExtra(
            "Kleoth",
            systemImage: controller.isRecording ? "record.circle" : "waveform"
        ) {
            MenuView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(controller)
        }
    }
}
