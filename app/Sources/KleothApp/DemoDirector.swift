import AppKit
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// Films the README's meeting and recordings-viewer demos from a `-KleothDemo`
/// launch (design: `docs/plans/2026-09-24-demo-mode.md` §2).
///
/// The History window, the meeting view and the viewer are internal to this
/// executable, so the film comes from the app itself: the director builds its
/// own History window (the SwiftUI `Window` scenes open only from the menu-bar
/// label, which a demo launch doesn't have), orders it behind every other
/// window without activating, drives it through the hooks History already
/// has, and captures that one window 20 times a second — capturing your own
/// window needs no permission. Each frame is set on the part-1 stage with a
/// caption (`pillsandbox/Demo.swift`), written as a PNG with an ffmpeg concat
/// list, and the app quits. `app/branding-src/demo/make-app-demos.sh` runs it.
@MainActor
final class DemoDirector {
    enum Script: String {
        /// A meeting: summary → action items → per-speaker highlights → the next meeting.
        case meeting
        /// A screen recording playing, its words highlighting as they're said.
        case viewer
        /// One large still of a meeting (`docs/assets/screenshot-detail.png`).
        case still
        /// The covers hero: the newest meeting with a cover at three scroll
        /// offsets, light then dark, then a meeting without one. Verification
        /// frames, not a README film.
        case cover
    }

    /// The file `make-demo-data.ts` leaves in every folder it makes, and that
    /// hand-made fictional fixtures (the covers-hero ones) carry too. A folder
    /// without it — the real `~/Kleoth`, or wherever Settings points — is never
    /// filmed: its meetings would end up in a public README.
    static let folderMarker = ".kleoth-demo"

    private static var current: DemoDirector?
    private static var appDelegate: DemoAppDelegate?

    /// `KleothMain` in demo mode: a plain AppKit app — no scenes, no
    /// `AppDelegate` — whose only job is `start()`.
    static func launch() {
        let app = NSApplication.shared
        let delegate = DemoAppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    static func start() {
        // The copy make-app-demos.sh assembles, with its own defaults, saved
        // state and privacy grants — never the installed app, never a bare binary.
        guard Bundle.main.bundleIdentifier == "dev.kleoth.demo" else {
            return quit("-KleothDemo runs only as dev.kleoth.demo — use app/branding-src/demo/make-app-demos.sh")
        }
        guard let folder = DemoMode.folder,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(folderMarker).path) else {
            return quit("-KleothDemo needs a folder made by make-demo-data.ts (with \(folderMarker))")
        }
        guard let film = DemoMode.filmDirectory else {
            return quit("-KleothDemoFilm needs an absolute folder")
        }
        guard let script = DemoMode.script.flatMap(Script.init(rawValue:)) else {
            return quit("-KleothDemoScript must be meeting, viewer, still or cover")
        }
        // The controllers History reads, built here (each sets its `shared`):
        // in demo mode no `KleothApp` exists to own them. Covers stay Off
        // (`AppConfig.settings()` forces it), so nothing is drawn;
        // `showsCovers` shows the folder's own pictures, which the `cover`
        // script films.
        let recording = RecordingController()
        let dictation = DictationController()
        let screen = ScreenRecordingController()
        let director = DemoDirector(script: script, film: film)
        director.controllers = (recording, dictation, screen)
        director.covers = CoverController()
        current = director
        director.begin(recording: recording, dictation: dictation, screen: screen)
    }

    private static func quit(_ message: String) {
        report(message)
        NSApp.terminate(nil)
    }

    nonisolated static func report(_ message: String) {
        FileHandle.standardError.write(Data("demo: \(message)\n".utf8))
    }

    // MARK: - State

    private let script: Script
    private let writer: DemoFilmWriter
    private var controllers: (RecordingController, DictationController, ScreenRecordingController)?
    private var covers: CoverController?
    private var window: NSWindow?
    private var captureTimer: Timer?
    private var started = Date()
    private var caption = ""
    /// Keeps App Nap from throttling the capture timer: this app has no
    /// visible front window and is never active.
    private var activity: NSObjectProtocol?

    private init(script: Script, film: URL) {
        self.script = script
        // The cover frames are stills too (Retina); their captions name each one.
        writer = DemoFilmWriter(directory: film, stage: script == .still || script == .cover ? .still : .film)
    }

    private var windowSize: CGSize {
        switch script {
        case .meeting: return CGSize(width: 920, height: 600)
        // Wide enough for the viewer's side-by-side layout (video left,
        // transcript right), which starts at a 760 pt detail pane.
        case .viewer: return CGSize(width: 1140, height: 620)
        case .still: return CGSize(width: 1180, height: 800)
        // A detail pane of about 700 pt, so the band is about 350 pt: inside
        // the 200…400 rule, not at either end (`CoverHeroGeometryTests` pins those).
        case .cover: return CGSize(width: 1000, height: 680)
        }
    }

    // MARK: - Run

    private func begin(recording: RecordingController, dictation: DictationController, screen: ScreenRecordingController) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Filming a README demo")
        // The whole run is a couple of minutes at most; never leave a demo
        // instance behind.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(150))
            Self.quit("timed out")
        }
        Task { @MainActor in
            if script == .viewer {
                // The list and its selection exist before the window does: an
                // empty Recordings detail ("Select a recording") inflates the
                // split view's first layout (its message is measured at zero
                // width, ~900 pt tall), and the detail's title-bar backdrop
                // stays where that layout put it.
                screen.reloadRecordings()
                for _ in 0..<100 where screen.recordings.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
                guard let first = screen.recordings.first else { return Self.quit("no screen recordings in the demo folder") }
                screen.selectedRecordingID = first.id
                HistoryRouting.requestedScope = .recordings
            }
            window = makeWindow(recording: recording, dictation: dictation, screen: screen)
            // Let the lists load and the first layout settle before rolling.
            try? await Task.sleep(for: .seconds(2.5))
            switch script {
            case .meeting: await meetingScript(recording)
            case .viewer: await viewerScript()
            case .still: await stillScript(recording)
            case .cover: await coverScript(recording)
            }
            captureTimer?.invalidate()
            writer.finish(hold: 2.2)
            Self.report("wrote \(writer.frameCount) frames")
            NSApp.terminate(nil)
        }
    }

    private func makeWindow(recording: RecordingController, dictation: DictationController, screen: ScreenRecordingController) -> NSWindow {
        // A fixed-size root, in a window that keeps its frame (`DemoWindow`):
        // left alone, the hosting view grows the window toward the split view's
        // minimum height, which an empty detail pane can push past the screen.
        let root = HistoryView()
            .environmentObject(recording)
            .environmentObject(dictation)
            .environmentObject(screen)
            .environmentObject(covers ?? CoverController())   // set in `start()`; History's views crash without one
            .frame(width: windowSize.width, height: windowSize.height)
        let window = DemoWindow(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // A hosting view straight in `contentView` of a window whose frame is
        // set from outside is the pattern CLAUDE.md warns about for the pill's
        // panel; here it holds because the root's fixed frame IS the window's
        // size, so SwiftUI never asks for another one.
        let host = NSHostingView(rootView: root)
        // The sidebar toggle, the detail toolbar and the title, as in the
        // app's own History window.
        host.sceneBridgingOptions = .all
        window.contentView = host
        if let visible = NSScreen.main?.visibleFrame {
            window.pinnedFrame = CGRect(
                x: visible.midX - windowSize.width / 2, y: visible.midY - windowSize.height / 2,
                width: windowSize.width, height: windowSize.height)
        }
        window.title = "Meeting History"
        window.toolbarStyle = .unified
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        // Light, like the part-1 stage around it — whatever the Mac is set to.
        window.appearance = NSAppearance(named: .aqua)
        // Behind every window of every app, and never key: the user keeps
        // working while it films.
        window.orderBack(nil)
        return window
    }

    // MARK: - Scripts

    private func meetingScript(_ recording: RecordingController) async {
        guard recording.recentMeetings.count >= 2 else { return Self.report("need at least two meetings") }
        recording.selectedMeetingID = recording.recentMeetings[0].id
        await hold(1.0)
        await measureSections(["Action Items", "Per-Speaker Highlights"])
        roll()
        caption = "A call, transcribed on your Mac and summarized"
        await hold(3.4)
        caption = "Action items, with who owns them"
        await scroll(toSection: "Action Items", over: 1.0)
        await hold(2.4)
        caption = "Who said what, person by person"
        await scroll(toSection: "Per-Speaker Highlights", over: 1.0)
        await hold(2.6)
        caption = "Every meeting is Markdown and JSON in ~/Kleoth"
        recording.selectedMeetingID = recording.recentMeetings[1].id
        await hold(3.0)
    }

    private func viewerScript() async {
        await hold(1.0)
        roll()
        caption = "Screen recordings are transcribed on device"
        await hold(2.0)
        caption = "Playback highlights each word as it's said"
        NotificationCenter.default.post(name: DemoMode.playNotification, object: nil)
        await hold(9.0)
        caption = "An MP4 and its transcript, in ~/Kleoth"
        await hold(1.5)
    }

    private func stillScript(_ recording: RecordingController) async {
        guard let first = recording.recentMeetings.first else { return Self.report("no meetings") }
        recording.selectedMeetingID = first.id
        await hold(2.0)
        caption = ""
        capture()
    }

    /// Plan 2026-09-25 `## Design` 8: the page with a cover at rest, scrolled
    /// 140 pt and scrolled 320 pt, in light then dark, then a meeting without a
    /// picture in light. Seven stills; the captions name each one, so no two
    /// are the same frame to the writer (which drops a repeat). An offset past
    /// the end of a short page clamps to it, so 140 and 320 can land on the
    /// same scroll: the caption then names the offset asked for as well, and
    /// the two stay apart. The next selection rebuilds the page
    /// (`.id(meeting.id)`), so the last still is at rest without a scroll of
    /// its own.
    private func coverScript(_ recording: RecordingController) async {
        guard let withCover = recording.recentMeetings.first(where: { $0.coverImageURL != nil }) else {
            return Self.report("no meeting with a cover in the demo folder")
        }
        recording.selectedMeetingID = withCover.id
        await hold(1.5)
        let appearances: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
        for (appearance, name) in appearances {
            window?.appearance = NSAppearance(named: appearance)
            await hold(0.8)
            for offset in [CGFloat(0), 140, 320] {
                guard let window, let scrollView = detailScrollView(in: window), let document = scrollView.documentView else {
                    return Self.report("no detail scroll view")
                }
                let clamped = min(offset, maxScrollOffset(of: scrollView, document: document))
                setOffsetFromTop(clamped, clip: scrollView.contentView, document: document, in: scrollView)
                await hold(0.5)
                caption = clamped < offset
                    ? "\(name) · scrolled \(Int(clamped)) pt, the page's end (asked \(Int(offset)))"
                    : "\(name) · scrolled \(Int(clamped)) pt"
                capture()
            }
        }
        window?.appearance = NSAppearance(named: .aqua)
        guard let without = recording.recentMeetings.first(where: { $0.coverImageURL == nil }) else {
            return Self.report("no meeting without a cover in the demo folder")
        }
        recording.selectedMeetingID = without.id
        await hold(1.5)
        caption = "light · no cover"
        capture()
    }

    // MARK: - Camera

    /// Starts the 20 fps capture.
    private func roll() {
        started = Date()
        capture()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { _ in
            MainActor.assumeIsolated { DemoDirector.current?.capture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
    }

    private func capture() {
        guard let window else { return }
        // Obsoleted in the macOS 15 SDK's Swift overlay when the deployment
        // target is 15+; at the app's 14.4 floor it builds. ScreenCaptureKit's
        // `SCScreenshotManager` is the replacement if the floor moves.
        // What the window server has for THIS window, obscured or not.
        guard let image = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]
        ), image.width > 1 else { return }
        writer.add(image, pointSize: window.frame.size, caption: caption, time: Date().timeIntervalSince(started))
    }

    private func hold(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - Scrolling the meeting

    // Every offset below is measured from the page AT REST: 0 is the page as
    // it first appears, whatever the clip's raw origin. The meeting page's
    // scroll view runs under the toolbar with a top content inset (52 pt on
    // macOS 26), so at rest its clip bounds start at y = -inset, and a raw
    // y = 0 would already be scrolled by the inset. What the page shows
    // (`visibleHeight`) is the clip less its insets.

    /// How far down the meeting each section header sits, in points from the
    /// top of the page at rest — measured before the camera rolls.
    private var sectionOffsets: [String: CGFloat] = [:]

    /// Pages through the meeting and reads the headers off its own window
    /// with on-device text recognition. SwiftUI builds no accessibility tree
    /// while no assistive app is attached, and nothing in the view hierarchy
    /// knows where a section starts; the pixels do.
    private func measureSections(_ titles: [String]) async {
        guard let window, let scrollView = detailScrollView(in: window), let document = scrollView.documentView else {
            return Self.report("no detail scroll view")
        }
        let clip = scrollView.contentView
        let visible = visibleHeight(of: scrollView)
        guard visible > 0 else { return Self.report("the detail scroll view has no height") }
        let maxOffset = maxScrollOffset(of: scrollView, document: document)
        var offset: CGFloat = 0
        while true {
            setOffsetFromTop(offset, clip: clip, document: document, in: scrollView)
            try? await Task.sleep(for: .milliseconds(300))
            if let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]
            ) {
                let visibleRect = clip.convert(clip.bounds, to: nil)
                // The page's own top edge, below the part of the clip that
                // runs under the toolbar: text above it is the toolbar's.
                let pageTop = visibleRect.maxY - insets(of: scrollView).top
                for (text, box) in Self.recognizeLines(in: image) {
                    // Vision's box is normalized, bottom-left origin — the
                    // window's own orientation.
                    let top = box.maxY * window.frame.height
                    let fromTop = pageTop - top
                    guard fromTop >= 0, fromTop < visible, box.minX * window.frame.width > visibleRect.minX else { continue }
                    for title in titles where sectionOffsets[title] == nil
                        && text.localizedCaseInsensitiveContains(title) {
                        sectionOffsets[title] = offset + fromTop
                    }
                }
            }
            if titles.allSatisfy({ sectionOffsets[$0] != nil }) || offset >= maxOffset { break }
            offset = min(maxOffset, offset + visible * 0.6)
        }
        setOffsetFromTop(0, clip: clip, document: document, in: scrollView)
        try? await Task.sleep(for: .milliseconds(300))
        for title in titles where sectionOffsets[title] == nil { Self.report("did not find the \(title) header") }
    }

    private nonisolated static func recognizeLines(in image: CGImage) -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
        }
    }

    /// Eases the meeting's scroll view until the section titled `title` sits
    /// just below the top; without a measured header, a fixed step.
    private func scroll(toSection title: String, over seconds: Double) async {
        guard let window, let scrollView = detailScrollView(in: window), let document = scrollView.documentView else {
            return Self.report("no detail scroll view")
        }
        let clip = scrollView.contentView
        let visible = visibleHeight(of: scrollView)
        let maxOffset = maxScrollOffset(of: scrollView, document: document)
        let current = offsetFromTop(clip: clip, document: document, in: scrollView)
        let target = min(maxOffset, max(0, sectionOffsets[title].map { $0 - 14 } ?? current + visible * 0.8))
        let steps = max(1, Int(seconds * 60))
        for step in 1...steps {
            let p = Double(step) / Double(steps)
            let eased = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
            setOffsetFromTop(current + (target - current) * eased, clip: clip, document: document, in: scrollView)
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// The scroll view's top and bottom insets as they take effect. On macOS 26
    /// they are the scroll view's own `contentInsets` (probed); on 14.4–15 the
    /// effective one may live on the clip view instead (not probed), so this
    /// takes the larger of the two.
    private func insets(of scrollView: NSScrollView) -> (top: CGFloat, bottom: CGFloat) {
        let outer = scrollView.contentInsets
        let clip = scrollView.contentView.contentInsets
        return (max(outer.top, clip.top), max(outer.bottom, clip.bottom))
    }

    /// How much of the page the scroll view shows: the clip less the part
    /// under the toolbar (and any bottom inset).
    private func visibleHeight(of scrollView: NSScrollView) -> CGFloat {
        let edges = insets(of: scrollView)
        return scrollView.contentView.bounds.height - edges.top - edges.bottom
    }

    /// The furthest the page scrolls from rest: its last line at the bottom edge.
    private func maxScrollOffset(of scrollView: NSScrollView, document: NSView) -> CGFloat {
        max(0, document.frame.height - visibleHeight(of: scrollView))
    }

    private func offsetFromTop(clip: NSClipView, document: NSView, in scrollView: NSScrollView) -> CGFloat {
        let inset = insets(of: scrollView).top
        return document.isFlipped ? clip.bounds.minY + inset : document.frame.height - clip.bounds.maxY + inset
    }

    private func setOffsetFromTop(_ offset: CGFloat, clip: NSClipView, document: NSView, in scrollView: NSScrollView) {
        let inset = insets(of: scrollView).top
        let y = document.isFlipped ? offset - inset : document.frame.height - clip.bounds.height - offset + inset
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The tallest scroll view right of the sidebar: the meeting detail.
    private func detailScrollView(in window: NSWindow) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found
            .filter { $0.convert($0.bounds, to: nil).minX > 200 }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
}

// MARK: - Window

/// The demo launch's application delegate: `DemoDirector.start()` and nothing else.
private final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { DemoDirector.start() }
    }
}

/// Draws as the active window — accent-coloured selection, coloured traffic
/// lights — while it is never key and the app is never active: a real key
/// window would take the user's keystrokes. AppKit asks these appearance
/// selectors (private, hence the ObjC names) rather than `isKeyWindow`. Demo
/// launches only; the script drives the window through the controllers.
private final class DemoWindow: NSWindow {
    /// The film's frame, kept whatever else asks for another one: the hosting
    /// view resizes its window toward the content's minimum size.
    var pinnedFrame: CGRect? {
        didSet { if let pinnedFrame { super.setFrame(pinnedFrame, display: true) } }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(pinnedFrame ?? frameRect, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(pinnedFrame ?? frameRect, display: displayFlag, animate: false)
    }

    @objc(hasKeyAppearance) var demoHasKeyAppearance: Bool { true }
    @objc(hasMainAppearance) var demoHasMainAppearance: Bool { true }
    @objc(_hasKeyAppearance) func demoPrivateHasKeyAppearance() -> Bool { true }
    @objc(_hasMainAppearance) func demoPrivateHasMainAppearance() -> Bool { true }
    @objc(_hasActiveAppearance) func demoHasActiveAppearance() -> Bool { true }
    @objc(_hasActiveAppearanceIgnoringKeyFocus) func demoHasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
    @objc(_hasActiveAppearanceForStandardWindowButton:) func demoHasActiveButton(_ button: Int) -> Bool { true }
}

// MARK: - Film writer

/// Composes each captured window onto the stage and writes it, off the main
/// thread. Everything it owns is touched only on `queue`.
private final class DemoFilmWriter: @unchecked Sendable {
    struct Stage {
        /// Stage size in points and the pixel scale it is written at.
        var scale: CGFloat
        var margin: CGFloat
        var captionBand: CGFloat

        /// README GIF frames: 1 px per point, so the GIF needs no scaling.
        static let film = Stage(scale: 1, margin: 40, captionBand: 58)
        /// Retina stills: the screenshot (no caption: `stillScript` clears it)
        /// and the `cover` frames (each captioned).
        static let still = Stage(scale: 2, margin: 56, captionBand: 56)
    }

    private let directory: URL
    private let stage: Stage
    private let queue = DispatchQueue(label: "dev.kleoth.demo.film", qos: .userInitiated)
    private var entries: [(name: String, time: TimeInterval)] = []
    private var lastHash: Int?

    init(directory: URL, stage: Stage) {
        self.directory = directory
        self.stage = stage
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var frameCount: Int { queue.sync { entries.count } }

    /// Frames waiting on `queue`; each holds a Retina capture (~9 MB). Past
    /// `maxBacklog` a frame is dropped rather than letting memory grow — the
    /// concat list's real timings keep the film's pace either way.
    private let backlogLock = NSLock()
    private var backlog = 0
    private let maxBacklog = 40

    func add(_ window: CGImage, pointSize: CGSize, caption: String, time: TimeInterval) {
        backlogLock.lock()
        guard backlog < maxBacklog else { backlogLock.unlock(); return }
        backlog += 1
        backlogLock.unlock()
        queue.async { [self] in
            defer { backlogLock.lock(); backlog -= 1; backlogLock.unlock() }
            // A frame identical to the last one only lengthens it.
            var hasher = Hasher()
            hasher.combine(caption)
            if let data = window.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
                hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: CFDataGetLength(data)))
            }
            let hash = hasher.finalize()
            guard hash != lastHash else { return }
            lastHash = hash
            guard let frame = compose(window, pointSize: pointSize, caption: caption) else { return }
            let name = String(format: "frame-%04d.png", entries.count)
            guard write(frame, to: directory.appendingPathComponent(name)) else { return }
            entries.append((name, time))
        }
    }

    /// Writes `frames.txt`: every frame lasts until the next one, and the last
    /// is held `hold` seconds so a looping GIF rests before it restarts.
    func finish(hold: TimeInterval) {
        queue.sync {
            guard let last = entries.last else { return }
            var list = ""
            for (index, entry) in entries.enumerated() {
                let next = index + 1 < entries.count ? entries[index + 1].time : entry.time + hold
                list += "file '\(entry.name)'\nduration \(String(format: "%.4f", max(0.01, next - entry.time)))\n"
            }
            // The concat demuxer ignores the last duration unless the file repeats.
            list += "file '\(last.name)'\n"
            try? list.write(to: directory.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Stage

    /// The part-1 stage: a light desktop with a teal glow, the window with a
    /// soft shadow, and the caption in a dark capsule above it.
    private func compose(_ window: CGImage, pointSize: CGSize, caption: String) -> CGImage? {
        let size = CGSize(
            width: pointSize.width + stage.margin * 2,
            height: pointSize.height + stage.margin + stage.captionBand)
        guard let ctx = CGContext(
            data: nil, width: Int(size.width * stage.scale), height: Int(size.height * stage.scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: stage.scale, y: stage.scale)
        ctx.interpolationQuality = .high
        let bounds = CGRect(origin: .zero, size: size)

        // Desktop.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let gradient = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.84, green: 0.89, blue: 0.95, alpha: 1),
            CGColor(srgbRed: 0.93, green: 0.91, blue: 0.95, alpha: 1),
        ] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        }
        if let glow = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.05, green: 0.58, blue: 0.53, alpha: 0.16),
            CGColor(srgbRed: 0.05, green: 0.58, blue: 0.53, alpha: 0),
        ] as CFArray, locations: [0, 1]) {
            let center = CGPoint(x: 140, y: size.height - 70)
            ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 520, options: [])
        }

        // Window, shadow following its rounded corners.
        let rect = CGRect(x: stage.margin, y: stage.margin, width: pointSize.width, height: pointSize.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.28))
        ctx.draw(window, in: rect)
        ctx.restoreGState()

        if !caption.isEmpty { drawCaption(caption, in: ctx, bounds: bounds, above: rect) }
        return ctx.makeImage()
    }

    private func drawCaption(_ text: String, in ctx: CGContext, bounds: CGRect, above window: CGRect) {
        let font = CTFontCreateUIFontForLanguage(.system, 15, nil)
            .map { CTFontCreateCopyWithSymbolicTraits($0, 15, nil, .boldTrait, .boldTrait) ?? $0 }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font as Any,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ascent + descent
        let box = CGRect(
            x: bounds.midX - width / 2 - 16, y: (window.maxY + bounds.maxY) / 2 - (height + 12) / 2,
            width: width + 32, height: height + 12)
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 0.82))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: box.height / 2, cornerHeight: box.height / 2, transform: nil))
        ctx.fillPath()
        ctx.textPosition = CGPoint(x: box.minX + 16, y: box.minY + 6 + descent)
        CTLineDraw(line, ctx)
    }

    private func write(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
