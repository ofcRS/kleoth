import AppKit
import CoreGraphics
import Foundation
import KleothCore
import KleothPillUI

/// "What do you want to record?" — one transparent overlay window per display;
/// click a display to take all of it, drag to take a region, Esc / ⌘. to cancel
/// (design §3.4, §2.1 step 4).
///
/// The overlays are plain AppKit: a borderless, transparent `NSWindow` per
/// `NSScreen` at `.screenSaver` level whose content view dims its display 30 %,
/// shows the crosshair, and draws the live drag rect with its size in points and
/// the resulting output size in pixels (`CaptureGeometry`, so the label can
/// never disagree with what the recorder actually produces).
///
/// Every overlay is closed **before** the continuation resumes, so the caller's
/// next step — the shareable-content snapshot — cannot see them. They are
/// Kleoth windows and excluded from the capture filter anyway (§5.2); this is
/// belt and braces.
@MainActor
final class RegionPicker {
    struct Choice: Equatable {
        var displayID: CGDirectDisplayID
        /// The display's AppKit global frame (bottom-left origin).
        var displayFrame: CGRect
        /// The dragged rect in AppKit global points, or nil for the whole
        /// display. `CaptureGeometry.sourceRect(fromGlobal:displayFrame:)`
        /// turns it into the stream's display-local rect.
        var globalRect: CGRect?
    }

    private var overlays: [RegionPickerWindow] = []
    private var continuation: CheckedContinuation<Choice?, Never>?
    private var keyObserver: NSObjectProtocol?
    private var pushedCursor = false
    /// Whoever was frontmost before the picker activated Kleoth. An
    /// `.accessory` app whose last window closes STAYS the active app, so
    /// without handing activation back the recording would open on the user
    /// clicking their way back into their editor — and a dictation finishing
    /// right after the pick would paste into Kleoth.
    private var previousApp: NSRunningApplication?

    /// nil = cancelled (Esc / ⌘. / the overlay lost key status).
    func pick() async -> Choice? {
        // Re-entry would strand the first continuation; there is exactly one
        // picker per session and `ScreenRecordingController` serializes them,
        // but a stray second call must not hang.
        guard continuation == nil, overlays.isEmpty else { return nil }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Choice?, Never>) in
            MainActor.assumeIsolated {
                self.begin(screens: screens, continuation: continuation)
            }
        }
    }

    // MARK: - Presentation

    private func begin(screens: [NSScreen], continuation: CheckedContinuation<Choice?, Never>) {
        self.continuation = continuation

        for screen in screens {
            let window = RegionPickerWindow(screen: screen)
            window.onPick = { [weak self] choice in self?.finish(choice) }
            window.onCancel = { [weak self] in self?.finish(nil) }
            window.onWholeDisplay = { [weak self] in self?.finishWithDisplayUnderPointer() }
            overlays.append(window)
        }

        // An `.accessory` app still has to be active for a borderless window to
        // take key status, and the picker is modal by nature. Remember who we
        // are stealing it from so `teardown()` can hand it straight back (when
        // Kleoth was already frontmost there is nothing to restore).
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil
            : frontmost
        NSApp.activate(ignoringOtherApps: true)
        for window in overlays {
            window.orderFrontRegardless()
        }
        overlays.first { $0.frame.contains(NSEvent.mouseLocation) }
            .map { $0.makeKeyAndOrderFront(nil) }
            ?? overlays.first?.makeKeyAndOrderFront(nil)

        NSCursor.crosshair.push()
        pushedCursor = true

        // Another app activating (or Mission Control) takes key away from every
        // overlay — that reads as "cancel". Moving the pointer to a second
        // display hands key from one overlay to another, which does NOT: the
        // check runs on the next runloop turn, by which time the sibling is key.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? RegionPickerWindow else { return }
            MainActor.assumeIsolated {
                guard let self, self.overlays.contains(where: { $0 === window }) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.continuation != nil else { return }
                        guard !self.overlays.contains(where: { $0.isKeyWindow }) else { return }
                        self.finish(nil)
                    }
                }
            }
        }
    }

    /// Return, or a click that never became a qualifying drag: the whole display
    /// under the pointer (falling back to the key overlay, then the main screen
    /// — `NSEvent.mouseLocation` can sit in the gap between two displays).
    private func finishWithDisplayUnderPointer() {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(location) }
            ?? overlays.first { $0.isKeyWindow }?.pickerScreen
            ?? NSScreen.main
        guard let screen, let displayID = screen.kleothDisplayId else {
            finish(nil)
            return
        }
        finish(Choice(displayID: CGDirectDisplayID(displayID), displayFrame: screen.frame, globalRect: nil))
    }

    private func finish(_ choice: Choice?) {
        guard let continuation else { return }
        self.continuation = nil
        teardown()
        continuation.resume(returning: choice)
    }

    /// Closes every overlay BEFORE the continuation resumes (see the type doc).
    private func teardown() {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
        for window in overlays {
            window.onPick = nil
            window.onCancel = nil
            window.onWholeDisplay = nil
            window.orderOut(nil)
            window.close()
        }
        overlays.removeAll()

        // Give the user's app its focus back before the recording starts (or
        // after an Esc). Closing our last window does NOT do this on its own.
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
        previousApp = nil
    }
}

// MARK: - Overlay window

/// One transparent, click-through-proof overlay per display. `NSWindow` and not
/// `NSPanel`: this one DOES want key status (it owns Esc / Return) and is torn
/// down the moment the pick resolves, so none of `DictationPanel`'s
/// never-activate flags apply.
@MainActor
private final class RegionPickerWindow: NSWindow {
    var onPick: ((RegionPicker.Choice) -> Void)?
    var onCancel: (() -> Void)?
    var onWholeDisplay: (() -> Void)?

    let pickerScreen: NSScreen

    // A borderless window refuses key status unless it says otherwise, and
    // without key status there are no Esc / Return key events.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(screen: NSScreen) {
        pickerScreen = screen
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        // The pill's panel joins every Space for the same reason: the picker
        // must cover a full-screen app's Space too.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        isMovable = false
        isMovableByWindowBackground = false
        // AppKit would otherwise re-centre / clamp a borderless window; the
        // frame IS the display.
        setFrame(screen.frame, display: false)

        let view = RegionPickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.pointPixelScale = screen.backingScaleFactor
        view.onDragFinished = { [weak self] start, end in
            self?.resolve(from: start, to: end)
        }
        contentView = view
        initialFirstResponder = view
    }

    /// View-local drag points → a global rect, via the same pure function the
    /// size label uses.
    private func resolve(from start: CGPoint, to end: CGPoint) {
        let origin = pickerScreen.frame.origin
        let globalStart = CGPoint(x: start.x + origin.x, y: start.y + origin.y)
        let globalEnd = CGPoint(x: end.x + origin.x, y: end.y + origin.y)
        let region = CaptureGeometry.region(
            from: globalStart,
            to: globalEnd,
            in: pickerScreen.frame,
            minimum: ScreenRecordingDefaults.minRegionPoints
        )
        guard let region else {
            // Not a qualifying drag: the user meant this whole display.
            onWholeDisplay?()
            return
        }
        guard let displayID = pickerScreen.kleothDisplayId else {
            onCancel?()
            return
        }
        onPick?(
            RegionPicker.Choice(
                displayID: CGDirectDisplayID(displayID),
                displayFrame: pickerScreen.frame,
                globalRect: region
            )
        )
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 36, 76: // Return, keypad Enter
            onWholeDisplay?()
        default:
            super.keyDown(with: event)
        }
    }

    /// ⌘. — `cancelOperation` covers it on a key window, but only if something
    /// down the responder chain does not eat it first.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "." {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Overlay view

/// Dims its display, tracks the drag, and draws the selection with its size in
/// points and the output size in pixels.
@MainActor
private final class RegionPickerView: NSView {
    var onDragFinished: ((CGPoint, CGPoint) -> Void)?
    var pointPixelScale: CGFloat = 1

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    private static let dimAlpha: CGFloat = 0.3
    private static let hint = "Drag to record an area · Return records this whole screen · Esc cancels"

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
        onDragFinished?(start, end)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        NSColor.black.withAlphaComponent(Self.dimAlpha).setFill()
        dirtyRect.fill()

        guard let selection = currentSelection() else {
            drawHint(in: context)
            return
        }

        // Punch the selection out of the dim so the user sees exactly what the
        // recorder will see.
        context.setBlendMode(.copy)
        NSColor.clear.setFill()
        selection.fill()
        context.setBlendMode(.normal)

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        drawSizeLabel(for: selection)
        drawHint(in: context)
    }

    private func currentSelection() -> NSRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return rect.intersection(bounds)
    }

    /// "800×450 pt → 1600×900 px" — the pixel half comes from
    /// `CaptureGeometry.outputPixelSize`, so it already carries the long-edge
    /// cap and the even-rounding the writer applies.
    private func drawSizeLabel(for selection: NSRect) {
        let pixels = CaptureGeometry.outputPixelSize(
            sourcePoints: selection.size,
            pointPixelScale: pointPixelScale,
            maxLongEdge: ScreenRecordingDefaults.maxLongEdgePixels
        )
        let text = "\(Int(selection.width.rounded()))×\(Int(selection.height.rounded())) pt"
            + " → \(Int(pixels.width))×\(Int(pixels.height)) px"

        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = attributed.size()
        let padding: CGFloat = 6
        let boxSize = NSSize(width: size.width + padding * 2, height: size.height + padding)

        // Above the rect when there is room, otherwise inside its top edge.
        var origin = NSPoint(x: selection.minX, y: selection.maxY + 6)
        if origin.y + boxSize.height > bounds.maxY {
            origin.y = max(bounds.minY, selection.maxY - boxSize.height - 6)
        }
        origin.x = min(max(bounds.minX + 4, origin.x), bounds.maxX - boxSize.width - 4)

        let box = NSRect(origin: origin, size: boxSize)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        attributed.draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2))
    }

    private func drawHint(in context: CGContext) {
        let attributed = NSAttributedString(string: Self.hint, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = attributed.size()
        let padding: CGFloat = 10
        let box = NSRect(
            x: bounds.midX - (size.width + padding * 2) / 2,
            y: bounds.minY + 56,
            width: size.width + padding * 2,
            height: size.height + padding
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        attributed.draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2))
    }
}
