import AppKit
import CoreAudio
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import KleothCore
import KleothPillUI

/// Pill sandbox — the dictation pill on its own, with no app around it.
///
/// Two modes:
///
///     swift run --package-path app pillsandbox
///         A control window that drives the REAL `DictationPillController`
///         (the same panel, view and motion the app ships) through every phase,
///         edge, and mic level, so a human can play with the motion without
///         rebuilding, signing, or re-granting anything. Placement is kept in
///         its own defaults suite, never the app's.
///
///     swift run --package-path app pillsandbox --film <dir> [--edge bottom|top|left|right]
///         [--fraction 0.5] [--fps 30] [--hold 1.2] [--backdrop hidden|idle|recording]
///         [--levels off|speech|steady] [--sequence idle,listening,transcribing,done,idle]
///         (sequence items: idle armed listening handsfree transcribing polishing done warning
///          failed recording saving saved hidden, plus peek / unpeek = pointer enters / leaves
///          the resting pill)
///         `--levels` feeds synthetic mic + system RMS into the REAL
///         `setRecordingLevels`, so the recording toolbar's meters move in the
///         film; `off` (the default) leaves them at rest.
///         `--backdrop` is what the pill collapses to between phases: `idle` (the
///         dictation resting sliver, the default and today's behavior),
///         `recording` (a screen recording in flight — the pill never tucks) or
///         `hidden` (no pill at all between phases).
///         Headless: runs the sequence, renders the panel every 1/fps s
///         (`DictationPillController.captureFrame` — no screen-recording
///         permission needed), composes each frame on a fixed canvas around the
///         anchor with the screen edge drawn in, writes `frame-NNNN.png` and a
///         labelled contact sheet `sheet.png`, then exits. This is how an
///         agent SEES the animation instead of guessing from a description.

// MARK: - Arguments

struct Arguments {
    var filmDirectory: URL?
    var edge: PillGeometry.Edge = .bottom
    var fraction: Double = 0.5
    var fps: Double = 30
    var hold: TimeInterval = 1.2
    /// What the pill collapses to between phases. `.idle` is the dictation
    /// resting sliver (today's behavior); `.recording` puts a screen recording
    /// in flight, so the pill never tucks and every `dismiss()` lands back on
    /// the dot-and-digits capsule.
    var backdrop: DictationPillBackdrop = .idle
    var sequence: [String] = ["idle", "listening", "transcribing", "polishing", "done", "idle"]
    /// Synthetic mic + system levels for the `.recording` toolbar's meters, fed
    /// through the real `setRecordingLevels` (raw RMS in, the pill shapes it).
    /// `speech` = syllable bursts on the mic over a steadier system feed;
    /// `steady` = two constant mid levels; `off` = silence (the default, so the
    /// old films are unchanged).
    var levels: LevelPattern = .off
    /// The peek dock's look and scale for a film (`PillDockMetrics`).
    var dockStyle: PillDockStyle = .glass
    var dockScale: Double = Double(PillDockMetrics.defaultScale)
    /// A backdrop the film opens BEHIND the pill (`StagePanel`), so a screen
    /// grab of a Liquid Glass surface does not depend on whatever window the
    /// user happens to have under the pill.
    var stage: StageTone = .none
    /// Also take a REAL screen grab of a fixed region around the pill on every
    /// tick (`shot-NNNN.png`) — the only way to film Liquid Glass in motion
    /// (`captureFrame` sees just our window's own pixels).
    var grabFrames = false

    enum LevelPattern: String {
        case off, speech, steady
    }

    static func parse(_ args: [String]) -> Arguments {
        var out = Arguments()
        var i = 0
        func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
        while i < args.count {
            switch args[i] {
            case "--film": out.filmDirectory = value().map { URL(fileURLWithPath: $0, isDirectory: true) }; i += 1
            case "--edge": out.edge = value().flatMap(PillGeometry.Edge.init(rawValue:)) ?? .bottom; i += 1
            case "--fraction": out.fraction = value().flatMap(Double.init) ?? 0.5; i += 1
            case "--fps": out.fps = value().flatMap(Double.init) ?? 30; i += 1
            case "--hold": out.hold = value().flatMap(Double.init) ?? 1.2; i += 1
            case "--dock-style": out.dockStyle = value().flatMap(PillDockStyle.init(rawValue:)) ?? .glass; i += 1
            case "--dock-scale": out.dockScale = value().flatMap(Double.init) ?? out.dockScale; i += 1
            case "--stage": out.stage = value().flatMap(StageTone.init(rawValue:)) ?? .none; i += 1
            case "--grab-frames": out.grabFrames = true
            case "--backdrop": out.backdrop = value().flatMap(backdrop(named:)) ?? .idle; i += 1
            case "--sequence": out.sequence = value()?.split(separator: ",").map(String.init) ?? out.sequence; i += 1
            // `--levels` on its own means "speech"; a following pattern name wins.
            case "--levels":
                if let name = value(), let pattern = LevelPattern(rawValue: name.lowercased()) {
                    out.levels = pattern
                    i += 1
                } else {
                    out.levels = .speech
                }
            default: break
            }
            i += 1
        }
        return out
    }
}

/// One date per process so every `.recording` re-show compares equal — the
/// same rule the real session follows (§6.1).
enum SandboxClock {
    static let filmStart = Date()
}

/// Synthetic RAW RMS for the recording meters — the same units
/// `ScreenRecorder.levels` reports, so the pill's own normalize + smooth runs
/// exactly as it does live. RMS 0.02 ≈ a quarter meter, 0.30 ≈ nearly full.
func syntheticLevels(_ pattern: Arguments.LevelPattern, at t: Double) -> AudioLevels {
    switch pattern {
    case .off:
        return .zero
    case .steady:
        return AudioLevels(mic: 0.09, system: 0.045)
    case .speech:
        // Mic: syllables inside slower breath groups. System: a calmer bed
        // (music/voice from the machine) so the two meters never move together.
        let syllable = max(0, sin(t * 9.0)) * (0.5 + 0.5 * sin(t * 1.3))
        let mic = 0.008 + 0.34 * syllable
        let system = 0.02 + 0.09 * (0.5 + 0.5 * sin(t * 0.7 + 1.1))
        return AudioLevels(mic: mic, system: system)
    }
}

/// `--backdrop` / the control window's toggle. `recording` always uses
/// `SandboxClock.filmStart`, so the backdrop the pill collapses to and the
/// `recording` sequence item are the SAME value and never re-transition.
func pillAction(named name: String) -> DictationPillAction? {
    switch name {
    case "startScreenRecording": return .startScreenRecording
    case "stopScreenRecording": return .stopScreenRecording
    case "startHandsFreeDictation": return .startHandsFreeDictation
    case "stopHandsFreeDictation": return .stopHandsFreeDictation
    default: return nil
    }
}

func backdrop(named name: String) -> DictationPillBackdrop? {
    switch name.lowercased() {
    case "hidden": return .hidden
    case "idle": return .idle
    case "recording": return .recording(since: SandboxClock.filmStart)
    default: return nil
    }
}

func pillState(named name: String) -> DictationPillState? {
    switch name.lowercased() {
    case "idle": return .idle
    case "armed": return .armed
    case "listening": return .listening(handsFree: false)
    case "handsfree", "hands-free": return .listening(handsFree: true)
    case "transcribing": return .transcribing
    case "polishing": return .polishing
    case "done": return .done
    case "warning": return .warning("Pasted the raw transcript — the clean-up model timed out.")
    case "failed": return .failed(.missingElevenLabsKey)
    case "hidden": return .hidden
    case "recording": return .recording(since: SandboxClock.filmStart)
    case "saving": return .saving
    case "saved": return .saved("2:14 · 48 MB")
    default: return nil
    }
}

func phaseName(_ state: DictationPillState) -> String {
    switch state {
    case .hidden: return "hidden"
    case .idle: return "idle"
    case .armed: return "armed"
    case .listening(let h): return h ? "hands-free" : "listening"
    case .transcribing: return "transcribing"
    case .polishing: return "polishing"
    case .done: return "done"
    case .warning: return "warning"
    case .failed: return "failed"
    case .recording: return "recording"
    case .saving: return "saving"
    case .saved: return "saved"
    }
}

// MARK: - Shared driver

@MainActor
final class SandboxDriver: ObservableObject {
    let controller: DictationPillController
    @Published var edge: PillGeometry.Edge = .bottom { didSet { controller.dock(edge: edge, fraction: fraction) } }
    @Published var fraction: Double = 0.5 { didSet { controller.dock(edge: edge, fraction: fraction) } }
    @Published var level: Double = 0 { didSet { controller.setLevel(level) } }
    @Published var simulateSpeech = false { didSet { simulateSpeech ? startSpeech() : stopSpeech() } }
    /// Raw RMS pushed straight into `setRecordingLevels` — the recording
    /// toolbar's two meters. Sliders are live only while the pill is
    /// `.recording`/`.saving` (the controller ignores them otherwise).
    @Published var micRms: Double = 0.08 { didSet { pushRecordingLevels() } }
    @Published var systemRms: Double = 0.04 { didSet { pushRecordingLevels() } }
    @Published var simulateRecordingLevels = false {
        didSet { simulateRecordingLevels ? startRecordingLevels() : stopRecordingLevels() }
    }
    /// "Recording backdrop": a screen recording in flight. The pill then never
    /// tucks — every phase collapses back to the dot-and-digits capsule.
    @Published var backdropRecording = false {
        didSet {
            controller.setBackdrop(backdropRecording ? .recording(since: SandboxClock.filmStart) : .idle)
        }
    }
    @Published var phase: String = "idle"
    @Published var lastFilm: String = ""
    /// What the pill's menu / glyphs fired, newest first (the demo's "did it
    /// register?" readout).
    @Published var actionLog: [String] = []
    /// The Microphone submenu's pick; nil = Automatic. Demo-only state — the
    /// real app would persist a device UID and point every capture at it.
    @Published var selectedMicrophoneId: String?
    /// The peek dock's scale — the knob for "how big should the fields be"
    /// (the user on the first cut: "at least twice, maybe two and a half").
    @Published var dockScale: Double = Double(PillDockMetrics.defaultScale) { didSet { pushDock() } }
    /// Glass or ink — the two looks compared live (the user on the plates:
    /// "ugly gray… cheap highlighting").
    @Published var dockStyle: PillDockStyle = .glass { didSet { pushDock() } }

    private func pushDock() {
        controller.setDock(PillDockMetrics(scale: dockScale, style: dockStyle))
    }
    private var speechTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?
    private var recordingLevelTask: Task<Void, Never>?
    private var handsFreeTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults(suiteName: "dev.kleoth.pillsandbox") ?? .standard
        controller = DictationPillController(defaults: defaults)
        controller.onAction = { [weak self] action in self?.handle(action) }
        controller.onDismiss = { [weak self] in self?.phase = "dismissed" }
        controller.menuContent = { [weak self] in self?.menuContent() ?? PillMenuContent() }
    }

    // MARK: Interaction demo (2026-09-08)

    private func menuContent() -> PillMenuContent {
        let devices = InputDevices.list()
        let inUse: String? = {
            if let id = selectedMicrophoneId, let picked = devices.first(where: { $0.id == id }) { return picked.name }
            return InputDevices.defaultInputName()
        }()
        return PillMenuContent(
            microphones: devices,
            selectedMicrophoneId: selectedMicrophoneId,
            inUseMicrophoneName: inUse,
            lastDictationPreview: "Ship the pill menu tomorrow morning, then…",
            hotkeyDescription: DictationDefaults.hotkeyDescription
        )
    }

    private func log(_ line: String) {
        actionLog.insert(line, at: 0)
        if actionLog.count > 8 { actionLog.removeLast() }
    }

    /// What the app would do for each pill action, simulated: a hands-free
    /// dictation runs the real phases on synthetic speech, a screen recording
    /// puts the recording backdrop up, "hide for 1 hour" hides for 6 s.
    private func handle(_ action: DictationPillAction) {
        switch action {
        case .startHandsFreeDictation:
            log("Start dictation (hands-free)")
            handsFreeTask?.cancel()
            controller.show(.listening(handsFree: true))
            phase = "hands-free"
            simulateSpeech = true
        case .stopHandsFreeDictation:
            log("Stop dictation → transcribe → polish → paste")
            simulateSpeech = false
            handsFreeTask?.cancel()
            handsFreeTask = Task { [weak self] in
                guard let self else { return }
                for (name, seconds) in [("transcribing", 0.9), ("polishing", 0.9), ("done", 0.0)] {
                    guard !Task.isCancelled, let state = pillState(named: name) else { return }
                    controller.show(state)
                    phase = name
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
        case .startScreenRecording:
            log("Record screen… (would open the region picker)")
            backdropRecording = true
            simulateRecordingLevels = true
        case .stopScreenRecording:
            log("Stop recording → saving → saved")
            simulateRecordingLevels = false
            handsFreeTask?.cancel()
            // The app's order (`ScreenRecordingController.showSaved`): the bar
            // morphs into the saving wave while the backdrop is still
            // `.recording`; the backdrop is dropped only once the phase is
            // `.saving` (a no-op on screen — not a resting phase), so `.saved`'s
            // auto-hide lands on `.idle`. Dropping it FIRST, as this did, made
            // `setBackdrop(.idle)` tuck the bar and the wave never showed: the
            // saving capsule ran empty for its whole 1.2 s (filmed 2026-09-09).
            controller.show(.saving)
            handsFreeTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                backdropRecording = false
                controller.show(.saved("0:42 · 15 MB"))
            }
        case .revealLastRecording:
            log("Reveal the last recording in Finder")
        case .selectMicrophone(let id):
            selectedMicrophoneId = id
            let name = id.flatMap { picked in InputDevices.list().first { $0.id == picked }?.name } ?? "Automatic"
            log("Microphone → \(name)")
        case .pasteLastDictation:
            log("Paste last dictation")
        case .openDictationHistory:
            log("Open History → Dictations")
        case .hideForAnHour:
            log("Hide for 1 hour (6 s in the demo)")
            controller.setBackdrop(.hidden)
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, let self else { return }
                controller.setBackdrop(backdropRecording ? .recording(since: SandboxClock.filmStart) : .idle)
                log("…back after the hour")
            }
        case .openSettings:
            log("Open Settings")
        case .openAccessibilitySettings, .openScreenRecordingSettings:
            log("Open System Settings")
        }
    }

    func show(_ state: DictationPillState) {
        cycleTask?.cancel()
        controller.show(state)
        phase = phaseName(state)
    }

    func runCycle() {
        cycleTask?.cancel()
        cycleTask = Task { [weak self] in
            guard let self else { return }
            for (name, seconds) in [("armed", DictationDefaults.minHold), ("listening", 2.0), ("transcribing", 1.0), ("polishing", 1.0), ("done", 0)] {
                guard !Task.isCancelled, let state = pillState(named: name) else { return }
                controller.show(state)
                phase = name
                if name == "listening" { simulateSpeech = true }
                if name == "transcribing" { simulateSpeech = false }
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    private func startSpeech() {
        speechTask?.cancel()
        speechTask = Task { [weak self] in
            var t = 0.0
            while !Task.isCancelled {
                // Syllable-like envelope: bursts with pauses.
                let burst = 0.5 + 0.5 * sin(t * 1.3)
                let syllable = max(0, sin(t * 9.0)) * burst
                let value = min(1, 0.15 + 0.85 * syllable * (0.7 + 0.3 * sin(t * 0.37)))
                self?.controller.setLevel(value)
                t += 0.05
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopSpeech() {
        speechTask?.cancel()
        speechTask = nil
        controller.setLevel(0)
    }

    private func pushRecordingLevels() {
        guard !simulateRecordingLevels else { return }
        controller.setRecordingLevels(AudioLevels(mic: micRms, system: systemRms))
    }

    /// 20 Hz, exactly like `ScreenRecordingController`'s poll.
    private func startRecordingLevels() {
        recordingLevelTask?.cancel()
        recordingLevelTask = Task { [weak self] in
            var t = 0.0
            while !Task.isCancelled {
                self?.controller.setRecordingLevels(syntheticLevels(.speech, at: t))
                t += 0.05
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopRecordingLevels() {
        recordingLevelTask?.cancel()
        recordingLevelTask = nil
        controller.setRecordingLevels(.zero)
    }
}

// MARK: - Control window

struct ControlPanel: View {
    @ObservedObject var driver: SandboxDriver

    var body: some View {
        Form {
            Section("Placement") {
                Picker("Edge", selection: $driver.edge) {
                    Text("Bottom").tag(PillGeometry.Edge.bottom)
                    Text("Top").tag(PillGeometry.Edge.top)
                    Text("Left").tag(PillGeometry.Edge.left)
                    Text("Right").tag(PillGeometry.Edge.right)
                }
                .pickerStyle(.segmented)
                Slider(value: $driver.fraction, in: 0...1) { Text("Along the edge") }
            }
            Section("Pill menu + peek dock (demo)") {
                Text("Hover the resting pill: it comes out as a dock of three fields — Dictate · Record · More — each lighting up under the pointer. Click Dictate for a hands-free dictation (click the capsule again to stop). Click More, or right-click anywhere, for the menu with the Microphone picker.")
                    .font(.caption).foregroundStyle(.secondary)
                let dock = driver.controller.dockMetrics
                Picker("Dock look", selection: $driver.dockStyle) {
                    Text("Liquid Glass").tag(PillDockStyle.glass)
                    Text("Ink").tag(PillDockStyle.ink)
                }
                .pickerStyle(.segmented)
                Slider(value: $driver.dockScale, in: 1...4, step: 0.25) {
                    Text("Dock scale ×\(driver.dockScale, specifier: "%.2f") — \(Int(dock.size.width))×\(Int(dock.size.height)) pt")
                }
                if driver.actionLog.isEmpty {
                    Text("Nothing fired yet.").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(driver.actionLog.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(index == 0 ? .primary : .secondary)
                    }
                }
            }
            Section("Phase — \(driver.phase)") {
                HStack {
                    ForEach(["idle", "armed", "listening", "handsfree", "transcribing"], id: \.self) { name in
                        Button(name) { driver.show(pillState(named: name)!) }
                    }
                }
                HStack {
                    ForEach(["polishing", "done", "warning", "failed", "hidden"], id: \.self) { name in
                        Button(name) { driver.show(pillState(named: name)!) }
                    }
                }
                HStack {
                    ForEach(["recording", "saving", "saved"], id: \.self) { name in
                        Button(name) { driver.show(pillState(named: name)!) }
                    }
                    Toggle("Recording backdrop", isOn: $driver.backdropRecording)
                }
                HStack {
                    Button("Run a whole dictation") { driver.runCycle() }
                        .buttonStyle(.borderedProminent)
                    Button("Reset position") { driver.controller.resetPosition() }
                }
            }
            Section("Mic") {
                Toggle("Simulate speech", isOn: $driver.simulateSpeech)
                Slider(value: $driver.level, in: 0...1) { Text("Level") }
                    .disabled(driver.simulateSpeech)
            }
            Section("Recording meters") {
                Text("Raw RMS into setRecordingLevels — only visible in the recording/saving phases.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Simulate a live recording", isOn: $driver.simulateRecordingLevels)
                Slider(value: $driver.micRms, in: 0...0.5) { Text("Mic RMS") }
                    .disabled(driver.simulateRecordingLevels)
                Slider(value: $driver.systemRms, in: 0...0.5) { Text("System RMS") }
                    .disabled(driver.simulateRecordingLevels)
            }
            Section("Film (for the agent)") {
                Text("Renders the current edge's rise → work → sink to PNG frames + a contact sheet in ~/Desktop.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Film a whole dictation") {
                    let dir = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Desktop/kleoth-pill-film-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
                    var args = Arguments()
                    args.filmDirectory = dir
                    args.edge = driver.edge
                    args.fraction = driver.fraction
                    args.backdrop = driver.backdropRecording ? .recording(since: SandboxClock.filmStart) : .idle
                    args.levels = driver.simulateRecordingLevels ? .speech : .off
                    driver.lastFilm = "Filming…"
                    Task { @MainActor in
                        let summary = await film(args, controller: driver.controller, exitWhenDone: false)
                        driver.lastFilm = summary
                    }
                }
                if !driver.lastFilm.isEmpty {
                    Text(driver.lastFilm).font(.caption).textSelection(.enabled)
                }
            }
            Section {
                Text(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                     ? "Reduce Motion is ON — the pill jumps instead of animating."
                     : "Reduce Motion is off.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Hover the resting pill to make it peek out. Drag it along its edge; drag toward another edge to re-dock.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 760)
    }
}

// MARK: - Film

struct CapturedFrame {
    let time: TimeInterval
    let frame: DictationPillController.Frame
}

/// Runs the sequence, captures, writes frames + sheet. Returns a one-line summary.
@MainActor
func film(_ args: Arguments, controller: DictationPillController, exitWhenDone: Bool) async -> String {
    guard let dir = args.filmDirectory else { return "no --film directory" }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    controller.dock(edge: args.edge, fraction: args.fraction)
    controller.setDock(PillDockMetrics(scale: args.dockScale, style: args.dockStyle))
    controller.ignoresRealPointer = true
    // The stage is opened lazily, once the pill's panel exists (the first
    // phase creates it) — its frame is what the stage is centred on.
    var stagePanel: StagePanel?
    var grabs = 0
    var grabRegion: CGRect?
    // The backdrop IS the starting state: `setBackdrop` takes over a down
    // panel on the spot, so `.idle` reproduces the old `setResting(true)` +
    // `show(.idle)` exactly and `.recording` starts the film with a recording
    // already in flight.
    controller.setBackdrop(args.backdrop)
    try? await Task.sleep(for: .seconds(1.0))

    var captured: [CapturedFrame] = []
    let interval = 1.0 / max(args.fps, 1)
    let start = Date()
    var speechClock = 0.0
    for name in args.sequence {
        // "peek" / "unpeek" simulate the pointer entering / leaving the pill.
        // "hover:mic|rec|menu|center" put the pointer on one glyph of the peek
        // dock (or the capsule's centre); "menu" opens the pill menu, films
        // the screen around it and closes it after the hold.
        var holdFor = args.hold
        if name == "peek" || name == "unpeek" {
            controller.setHovered(name == "peek")
        } else if name.hasPrefix("wait:") {
            // "wait:<seconds>" changes nothing and holds for that long — for
            // timed grabs after a transition (e.g. how a glass surface settles).
            holdFor = Double(name.dropFirst(5)) ?? args.hold
        } else if name.hasPrefix("hover:") {
            controller.setPointer(filmPointer(String(name.dropFirst(6)), edge: args.edge, controller: controller))
        } else if name.hasPrefix("click:") {
            // "click:mic|rec|menu|center" — a REAL click on the pill: a
            // synthesized mouse down + up delivered to the pill's own window,
            // so the SwiftUI button under that spot fires from inside its own
            // hosting view's event handling (what `perform:` skips — and what
            // the 2026-09-10 crash needed). No Accessibility involved: an app
            // may send events to its own windows.
            filmClick(String(name.dropFirst(6)), edge: args.edge, controller: controller)
        } else if name.hasPrefix("perform:") {
            // "perform:startScreenRecording|stopScreenRecording|startHandsFreeDictation|…"
            // — fires a pill action through the controller, so the SANDBOX
            // DRIVER's own simulation runs (its stop chains backdrop → saving →
            // saved in one go — a hand-written sequence cannot).
            if let action = pillAction(named: String(name.dropFirst(8))) { controller.perform(action) }
        } else if name.hasPrefix("backdrop:") {
            // "backdrop:hidden|idle|recording" — the host's entry point (what
            // the sandbox's Record / Stop do), so a film can run the demo's
            // own record cycle: dock → recording bar → stop → saving → saved.
            if let backdrop = backdrop(named: String(name.dropFirst(9))) { controller.setBackdrop(backdrop) }
        } else if name == "grab" {
            // A REAL screen grab around the pill (`captureFrame` sees only our
            // window's own pixels — a Liquid Glass surface, which refracts what
            // is behind it, only shows in a screen grab). No hold.
            grabs += 1
            if let frame = controller.panelFrame, let png = screenGrab(around: frame) {
                try? png.write(to: dir.appendingPathComponent("grab-\(grabs).png"))
                print("grab-\(grabs).png written")
            }
            continue
        } else if name == "menu" {
            // Opens the pill's own menu panel (non-blocking); a screen grab of
            // the area around the pill at +0.5 s catches it (`captureFrame`
            // only sees the pill's window), and it closes after the hold.
            let holdSeconds = args.hold
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                if let frame = controller.panelFrame, let png = screenGrab(around: frame) {
                    try? png.write(to: dir.appendingPathComponent("menu.png"))
                    print("menu.png written")
                }
                try? await Task.sleep(for: .seconds(max(0.1, holdSeconds - 0.5)))
                controller.closeMenu()
            }
            controller.openMenu()
        } else if let state = pillState(named: name) {
            controller.show(state)
        } else {
            continue
        }
        if stagePanel == nil, args.stage != .none, let frame = controller.panelFrame {
            let stage = StagePanel(tone: args.stage, around: frame)
            stage.orderFrontRegardless()
            print("stage: \(args.stage.rawValue) at \(stage.frame)")
            stagePanel = stage
        }
        let state = pillState(named: name) ?? .idle
        let phaseStart = Date()
        while Date().timeIntervalSince(phaseStart) < holdFor {
            speechClock += interval
            if case .listening = state {
                let syllable = max(0, sin(speechClock * 9.0)) * (0.5 + 0.5 * sin(speechClock * 1.3))
                controller.setLevel(min(1, 0.15 + 0.85 * syllable))
            }
            // The recording toolbar's meters, through the real entry point.
            if args.levels != .off {
                controller.setRecordingLevels(syntheticLevels(args.levels, at: speechClock))
            }
            if let frame = controller.captureFrame() {
                captured.append(CapturedFrame(time: Date().timeIntervalSince(start), frame: frame))
                if args.grabFrames {
                    // One fixed region for the whole film (a strip needs a
                    // steady camera): around the first frame's anchor, wide
                    // and tall enough for the peek dock and the menu.
                    if grabRegion == nil {
                        let f = frame.panelFrame
                        grabRegion = CGRect(x: f.midX - 220, y: frame.screenFrame.minY - 10, width: 440, height: 170)
                    }
                    if let region = grabRegion, let png = screenGrab(cocoaRegion: region) {
                        try? png.write(to: dir.appendingPathComponent(String(format: "shot-%04d.png", captured.count - 1)))
                    }
                }
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }
    controller.setLevel(0)

    guard !captured.isEmpty else { return "captured nothing (panel never visible)" }
    let rows = captured.enumerated().map { index, c in
        let f = c.frame.panelFrame
        return String(format: "%04d\t%.3f\t%@\t%.1f,%.1f %.0fx%.0f\t%dx%d", index, c.time, phaseName(c.frame.phase) as NSString, f.minX, f.minY, f.width, f.height, c.frame.image.width, c.frame.image.height)
    }
    try? rows.joined(separator: "\n").write(to: dir.appendingPathComponent("frames.tsv"), atomically: true, encoding: .utf8)
    var sheetName = "-"
    do {
        sheetName = try writeFilm(captured, to: dir, edge: args.edge).lastPathComponent
    } catch {
        FileHandle.standardError.write(Data("sheet failed: \(error)\n".utf8))
    }
    let summary = "\(captured.count) frames → \(dir.path)  sheet: \(sheetName)"
    print(summary)
    fflush(stdout)
    if exitWhenDone { exit(0) }
    return summary
}

/// Composes every frame onto one fixed canvas (the union of all panel rects,
/// padded), with the off-screen strip shaded and the screen edge drawn, so
/// motion reads relative to the edge. Writes PNGs and a contact sheet.
func writeFilm(_ frames: [CapturedFrame], to dir: URL, edge: PillGeometry.Edge) throws -> URL {
    let scale: CGFloat = 2
    var region = frames.map(\.frame.panelFrame).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -12, dy: -12)
    region = region.integral
    let screen = frames[0].frame.screenFrame
    let canvasSize = CGSize(width: region.width * scale, height: region.height * scale)

    var pngs: [CGImage?] = Array(repeating: nil, count: frames.count)
    for (index, captured) in frames.enumerated() {
        guard let ctx = CGContext(
            data: nil, width: Int(canvasSize.width), height: Int(canvasSize.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { continue }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -region.minX, y: -region.minY)
        // Off-screen = dark gray, on-screen = a light document-like ground.
        ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
        ctx.fill(region)
        ctx.setFillColor(CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        ctx.fill(region.intersection(screen))
        // The edge the pill docks on.
        ctx.setStrokeColor(CGColor(red: 1, green: 0.3, blue: 0.3, alpha: 1))
        ctx.setLineWidth(1)
        switch edge {
        case .bottom: ctx.move(to: CGPoint(x: region.minX, y: screen.minY)); ctx.addLine(to: CGPoint(x: region.maxX, y: screen.minY))
        case .top: ctx.move(to: CGPoint(x: region.minX, y: screen.maxY)); ctx.addLine(to: CGPoint(x: region.maxX, y: screen.maxY))
        case .left: ctx.move(to: CGPoint(x: screen.minX, y: region.minY)); ctx.addLine(to: CGPoint(x: screen.minX, y: region.maxY))
        case .right: ctx.move(to: CGPoint(x: screen.maxX, y: region.minY)); ctx.addLine(to: CGPoint(x: screen.maxX, y: region.maxY))
        }
        ctx.strokePath()
        // Panel outline (faint) so the stage/settle frame changes are visible too.
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.5))
        ctx.stroke(captured.frame.panelFrame.insetBy(dx: 0.5, dy: 0.5))
        // A capture taken in the same turn as a panel resize can predate the
        // new frame; draw it at its own size so it is never stretched.
        let image = captured.frame.image
        let imageSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        var imageRect = captured.frame.panelFrame
        if abs(imageSize.width - imageRect.width) > 0.5 || abs(imageSize.height - imageRect.height) > 0.5 {
            imageRect = CGRect(origin: imageRect.origin, size: imageSize)
        }
        ctx.draw(image, in: imageRect)
        guard let image = ctx.makeImage() else { continue }
        pngs[index] = image
        try writePNG(image, to: dir.appendingPathComponent(String(format: "frame-%04d.png", index)))
    }

    // Contact sheet: up to 40 tiles, 8 per row, each labelled with time + phase.
    let picks = stride(from: 0, to: frames.count, by: max(1, frames.count / 40)).prefix(40).map { $0 }
    let tileWidth: CGFloat = 220
    let tileScale = tileWidth / canvasSize.width
    let tileHeight = ceil(canvasSize.height * tileScale)
    let labelHeight: CGFloat = 18
    let columns = 8
    let rows = Int(ceil(Double(picks.count) / Double(columns)))
    let sheetWidth = Int(tileWidth) * columns
    let sheetHeight = Int(tileHeight + labelHeight) * rows
    guard let sheet = CGContext(
        data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    sheet.setFillColor(CGColor(gray: 0.12, alpha: 1))
    sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
    for (slot, index) in picks.enumerated() {
        let col = slot % columns, row = slot / columns
        let x = CGFloat(col) * tileWidth
        // Rows go top-down; CG is bottom-up.
        let y = CGFloat(sheetHeight) - CGFloat(row + 1) * (tileHeight + labelHeight)
        if let tile = pngs[index] {
            sheet.draw(tile, in: CGRect(x: x, y: y + labelHeight, width: tileWidth, height: tileHeight))
        }
        let label = String(format: "%.2fs  ", frames[index].time) + phaseName(frames[index].frame.phase)
        drawLabel(label, in: sheet, at: CGPoint(x: x + 4, y: y + 4))
    }
    guard let sheetImage = sheet.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let url = dir.appendingPathComponent("sheet.png")
    try writePNG(sheetImage, to: url)
    return url
}

func drawLabel(_ text: String, in ctx: CGContext, at point: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.white,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    ctx.saveGState()
    ctx.textPosition = point
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

/// Root-space pointer for a named spot on the pill. The peek dock's fields
/// sit one `PillDockMetrics.pitch` apart along the capsule; on a side edge
/// the capsule stands up (rotated +90° on the right, −90° on the left), so
/// "along" is the panel's y there — the same mapping the view undoes in
/// `dockPointer`.
@MainActor
func filmPointer(_ spot: String, edge: PillGeometry.Edge, controller: DictationPillController) -> CGPoint? {
    guard let frame = controller.panelFrame else { return nil }
    let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
    let pitch = controller.dockMetrics.pitch
    let along: CGFloat
    switch spot {
    case "mic": along = -pitch
    case "menu": along = pitch
    case "rec", "center": along = 0
    case "off", "none": return nil
    default: along = 0
    }
    switch edge {
    case .bottom, .top: return CGPoint(x: center.x + along, y: center.y)
    case .right: return CGPoint(x: center.x, y: center.y + along)
    case .left: return CGPoint(x: center.x, y: center.y - along)
    }
}

/// A real click at a named spot on the pill (see `filmPointer`): mouse down
/// and up synthesized in the pill window's coordinates and sent straight to
/// that window. SwiftUI's `Button` fires on the up, inside the hosting view's
/// own event handling — the one thing the timer-driven `perform:` cannot do.
@MainActor
func filmClick(_ spot: String, edge: PillGeometry.Edge, controller: DictationPillController) {
    guard let point = filmPointer(spot, edge: edge, controller: controller),
          let frame = controller.panelFrame,
          let window = NSApp.windows.first(where: { String(describing: type(of: $0)) == "DictationPanel" })
    else { print("click:\(spot): no pill window"); return }
    // Root space is y-down from the top-left; NSEvent wants y-up from the bottom-left.
    let location = CGPoint(x: point.x, y: frame.height - point.y)
    let now = ProcessInfo.processInfo.systemUptime
    for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: now,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure
        ) else { continue }
        window.sendEvent(event)
    }
    print("click:\(spot) at \(location) in window \(window.windowNumber)")
}

/// The film's stage: a plain light or dark window behind the pill, for grabs
/// of a Liquid Glass surface that do not depend on the user's windows.
enum StageTone: String { case none, light, dark }

@MainActor
final class StagePanel: NSPanel {
    init(tone: StageTone, around pill: CGRect) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(pill) }) ?? NSScreen.main
        let bottom = screen?.frame.minY ?? 0
        super.init(
            contentRect: NSRect(x: pill.midX - 450, y: bottom, width: 900, height: 520),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        level = .normal
        isOpaque = true
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: StageView(tone: tone))
    }
}

struct StageView: View {
    let tone: StageTone
    var body: some View {
        ZStack {
            LinearGradient(
                colors: tone == .light
                    ? [Color(white: 0.98), Color(red: 0.85, green: 0.92, blue: 0.80)]
                    : [Color(white: 0.13), Color(white: 0.05)],
                startPoint: .top, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 16) {
                ForEach(0..<10, id: \.self) { row in
                    Text("Stage row \(row) — the quick brown fox jumps over the lazy dog 0123456789")
                        .font(.system(size: 20))
                }
            }
            .foregroundStyle(tone == .light ? Color.black.opacity(0.7) : Color.white.opacity(0.7))
            .padding(40)
        }
    }
}

/// A screen grab of the area above/around the panel (the menu lives in its own
/// window, so `captureFrame` cannot see it). Needs Screen Recording for the
/// process — the shell's grant applies to a shell-launched sandbox.
func screenGrab(around panel: CGRect) -> Data? {
    screenGrab(cocoaRegion: CGRect(x: panel.minX - 80, y: panel.minY, width: panel.width + 300, height: panel.height + 380))
}

/// A screen grab of `region` (Cocoa coordinates, bottom-left origin), clipped
/// to the screen it lies on.
func screenGrab(cocoaRegion: CGRect) -> Data? {
    guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(cocoaRegion) }) ?? NSScreen.main else { return nil }
    // Cocoa (bottom-left) → CG (top-left of the main display).
    let mainHeight = NSScreen.screens[0].frame.height
    let region = CGRect(x: cocoaRegion.minX, y: mainHeight - cocoaRegion.maxY, width: cocoaRegion.width, height: cocoaRegion.height)
        .intersection(CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height))
    guard let image = CGWindowListCreateImage(region, [.optionOnScreenOnly], kCGNullWindowID, [.bestResolution]) else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Input devices (CoreAudio, read-only — no microphone permission needed)

enum InputDevices {
    static func list() -> [PillMicrophone] {
        allDeviceIds()
            .filter { inputChannelCount($0) > 0 }
            .compactMap { id -> PillMicrophone? in
                guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                      let name = string(id, kAudioObjectPropertyName) else { return nil }
                return PillMicrophone(id: uid, name: name)
            }
    }

    static func defaultInputName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    private static func allDeviceIds() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

// MARK: - Entry

let arguments = Arguments.parse(Array(CommandLine.arguments.dropFirst()))
let app = NSApplication.shared

final class SandboxDelegate: NSObject, NSApplicationDelegate {
    var driver: SandboxDriver?
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let driver = SandboxDriver()
            self.driver = driver
            if arguments.filmDirectory != nil {
                Task { @MainActor in _ = await film(arguments, controller: driver.controller, exitWhenDone: true) }
                return
            }
            // `backdropRecording` mirrors the toggle in the control window and
            // its `didSet` applies the backdrop; `--backdrop hidden` has no
            // toggle state, so it goes straight to the controller (routing it
            // through the toggle would show the resting pill and hide it again).
            if case .recording = arguments.backdrop {
                driver.backdropRecording = true
            } else {
                driver.controller.setBackdrop(arguments.backdrop)
            }
            driver.controller.dock(edge: arguments.edge, fraction: arguments.fraction)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "Kleoth pill sandbox"
            window.contentViewController = NSHostingController(rootView: ControlPanel(driver: driver))
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.window = window
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The control window closing ends the sandbox. Never in film mode: a
    /// closing MENU window (the panel does not count as a window here) would
    /// otherwise quit the process mid-film with exit 0 and no frames.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { arguments.filmDirectory == nil }
}

let delegate = SandboxDelegate()
app.delegate = delegate
app.setActivationPolicy(arguments.filmDirectory == nil ? .regular : .accessory)
app.run()
