import AppKit
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
///         [--fraction 0.5] [--fps 30] [--hold 1.2] [--sequence idle,listening,transcribing,done,idle]
///         (sequence items: idle listening handsfree transcribing polishing done warning failed hidden,
///          plus peek / unpeek = pointer enters / leaves the resting pill)
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
    var sequence: [String] = ["idle", "listening", "transcribing", "polishing", "done", "idle"]

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
            case "--sequence": out.sequence = value()?.split(separator: ",").map(String.init) ?? out.sequence; i += 1
            default: break
            }
            i += 1
        }
        return out
    }
}

func pillState(named name: String) -> DictationPillState? {
    switch name.lowercased() {
    case "idle": return .idle
    case "listening": return .listening(handsFree: false)
    case "handsfree", "hands-free": return .listening(handsFree: true)
    case "transcribing": return .transcribing
    case "polishing": return .polishing
    case "done": return .done
    case "warning": return .warning("Pasted the raw transcript — the clean-up model timed out.")
    case "failed": return .failed(.missingElevenLabsKey)
    case "hidden": return .hidden
    default: return nil
    }
}

func phaseName(_ state: DictationPillState) -> String {
    switch state {
    case .hidden: return "hidden"
    case .idle: return "idle"
    case .listening(let h): return h ? "hands-free" : "listening"
    case .transcribing: return "transcribing"
    case .polishing: return "polishing"
    case .done: return "done"
    case .warning: return "warning"
    case .failed: return "failed"
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
    @Published var phase: String = "idle"
    @Published var lastFilm: String = ""
    private var speechTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults(suiteName: "dev.kleoth.pillsandbox") ?? .standard
        controller = DictationPillController(defaults: defaults)
        controller.onAction = { [weak self] action in self?.phase = "action: \(action)" }
        controller.onDismiss = { [weak self] in self?.phase = "dismissed" }
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
            for (name, seconds) in [("listening", 2.0), ("transcribing", 1.0), ("polishing", 1.0), ("done", 0)] {
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
            Section("Phase — \(driver.phase)") {
                HStack {
                    ForEach(["idle", "listening", "handsfree", "transcribing"], id: \.self) { name in
                        Button(name) { driver.show(pillState(named: name)!) }
                    }
                }
                HStack {
                    ForEach(["polishing", "done", "warning", "failed", "hidden"], id: \.self) { name in
                        Button(name) { driver.show(pillState(named: name)!) }
                    }
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
        .frame(width: 520)
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
    controller.setResting(true)
    controller.show(.idle)
    try? await Task.sleep(for: .seconds(1.0))

    var captured: [CapturedFrame] = []
    let interval = 1.0 / max(args.fps, 1)
    let start = Date()
    var speechClock = 0.0
    for name in args.sequence {
        // "peek" / "unpeek" simulate the pointer entering / leaving the pill.
        if name == "peek" || name == "unpeek" {
            controller.setHovered(name == "peek")
        } else if let state = pillState(named: name) {
            controller.show(state)
        } else {
            continue
        }
        let state = pillState(named: name) ?? .idle
        let phaseStart = Date()
        while Date().timeIntervalSince(phaseStart) < args.hold {
            if case .listening = state {
                speechClock += interval
                let syllable = max(0, sin(speechClock * 9.0)) * (0.5 + 0.5 * sin(speechClock * 1.3))
                controller.setLevel(min(1, 0.15 + 0.85 * syllable))
            }
            if let frame = controller.captureFrame() {
                captured.append(CapturedFrame(time: Date().timeIntervalSince(start), frame: frame))
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
            driver.controller.setResting(true)
            driver.controller.dock(edge: arguments.edge, fraction: arguments.fraction)
            driver.controller.show(.idle)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let delegate = SandboxDelegate()
app.delegate = delegate
app.setActivationPolicy(arguments.filmDirectory == nil ? .regular : .accessory)
app.run()
