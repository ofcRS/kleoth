import SwiftUI

@main
struct KleothApp: App {
    @StateObject private var controller = RecordingController()

    var body: some Scene {
        MenuBarExtra("Kleoth", systemImage: "waveform") {
            MenuView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}
