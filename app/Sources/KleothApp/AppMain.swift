import AppKit

/// The executable's entry point. A normal launch is exactly `KleothApp`: its
/// scenes, its menu-bar item, its `AppDelegate`. A `-KleothDemo` launch
/// (`DemoMode`) builds none of that — no menu-bar scene, no hotkey, no launch
/// sweeps — just a plain AppKit app that hands off to `DemoDirector`.
@main
enum KleothMain {
    @MainActor
    static func main() {
        if DemoMode.isOn {
            DemoDirector.launch()
        } else {
            KleothApp.main()
        }
    }
}
