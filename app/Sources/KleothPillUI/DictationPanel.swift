import AppKit
import SwiftUI

/// The floating window the dictation pill lives in (design §5.6).
///
/// Everything here is load-bearing; the flags are the difference between a
/// heads-up display and a window that steals focus, disappears when another app
/// is frontmost, or shows up in ⌘-Tab:
///
/// - `.borderless` + `.nonactivatingPanel`: no chrome, and clicking it never
///   activates Kleoth. It is also why the panel is invisible to
///   `AppActivation.windowClosed()`, which only counts `.titled` windows —
///   showing the pill must never flip the app to `.regular` (Dock icon +
///   ⌘-Tab entry). Load-bearing: don't add `.titled`.
/// - `canBecomeKey/Main == false`: the app the user is typing in keeps its
///   caret and key focus while the pill is up.
/// - `hidesOnDeactivate = false`: `NSPanel` defaults this to **true**, which
///   would hide the pill the instant focus is anywhere else — i.e. always.
///   The classic invisible-HUD bug.
/// - `isReleasedWhenClosed = false`: the controller reuses one panel for the
///   life of the app and only ever `orderOut(nil)`s it.
final class DictationPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // ORDER MATTERS: `isFloatingPanel = true` assigns `level = .floating`
        // (3) as a side effect, so `.statusBar` (25) has to be written after it
        // or the pill sits below menu-bar-level windows.
        isFloatingPanel = true
        level = .statusBar

        // `.canJoinAllSpaces` + `.stationary` are what put the pill over another
        // app's full-screen Space; `.fullScreenAuxiliary` only matters for a
        // panel auxiliary to a full-screen window of *our own* app (kept for
        // that case); `.ignoresCycle` keeps it out of ⌘-` window cycling.
        collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]

        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        // The SwiftUI capsule draws its own shadow inside the panel's
        // transparent margin (`DictationPillController.shadowPadding`), so the
        // window must not add a second, rectangular one.
        hasShadow = false
        // The SwiftUI `DragGesture` is the only thing that moves this window;
        // background dragging would fight it and swallow button clicks.
        isMovableByWindowBackground = false
        isMovable = false
        acceptsMouseMovedEvents = true
        // No AppKit fade — show/hide animation is SwiftUI's (and is skipped
        // under Reduce Motion).
        animationBehavior = .none
        // Not restored across launches: placement is persisted ourselves as a
        // `PillPlacement` in UserDefaults.
        isRestorable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The resting pill is parked HALF OUTSIDE the screen (its center on the
    /// edge — `PillGeometry.restingOrigin`). AppKit's default nudges frames back
    /// on screen; the controller is the only thing that decides where this
    /// panel goes, so the frame passes through untouched.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Hosting view for the pill's SwiftUI content.
///
/// `acceptsFirstMouse` is the reason this subclass exists: without it the first
/// click on an inactive app's window is swallowed just to activate it, so the
/// pill's ✕ / "Open Settings" button would need two clicks — and Kleoth is
/// never the active app while dictating.
final class DictationPillHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Dragging is handled by the SwiftUI `DragGesture` (which tracks
    /// `NSEvent.mouseLocation`), not by AppKit window dragging.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Pointer entered / left the panel. An `.activeAlways` tracking area —
    /// SwiftUI's `.onHover` only fires while the app is active, and Kleoth is
    /// almost never the active app while its pill is on screen.
    var onHoverChange: ((Bool) -> Void)?
    /// Where the pointer is inside this view, in SwiftUI's root coordinate
    /// space (origin top-left, y down), or nil once it leaves. The pill's Stop
    /// button needs a hover state of its own and `.onHover` cannot give it one
    /// for the same reason `onHoverChange` exists.
    var onPointerMove: ((CGPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
        onPointerMove?(pillPoint(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointerMove?(pillPoint(for: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
        onPointerMove?(nil)
    }

    /// AppKit event location → SwiftUI root-space point. `NSHostingView` is
    /// normally flipped, but reading `isFlipped` rather than assuming it keeps
    /// this correct if that ever changes.
    private func pillPoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
