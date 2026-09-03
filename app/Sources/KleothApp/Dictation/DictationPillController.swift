import AppKit
import SwiftUI
import KleothCore

/// Owns the dictation pill's panel: when it is on screen, where it sits, how it
/// resizes between phases, and when it hides itself (design §3.19, §5.6).
///
/// Placement model (reworked 2026-09-03 after the reference bar): the pill has
/// ONE anchor — the saved placement, else bottom-center of the screen under the
/// mouse, just above its bottom edge. Every active phase sits on that anchor
/// (centered on it, so phase-to-phase size changes grow in place). The resting
/// `.idle` capsule is the same anchor slid into the nearest screen edge until
/// half of it is off-screen (`PillGeometry.restingOrigin`), and a chord makes
/// it rise back out to the anchor. Dragging moves the anchor.
///
/// It is the `DictationPillPresenting` the controller talks to; all it exposes
/// upward is `show/setLevel/dismiss/resetPosition` plus the two callbacks. All
/// pure math lives in `PillGeometry` (KleothCore) so it can be unit-tested — the
/// app package has no test target.
@MainActor
final class DictationPillController: DictationPillPresenting {
    /// Transparent margin around the capsule. The SwiftUI content draws its
    /// shadow inside this, which is why the panel itself has `hasShadow = false`.
    static let shadowPadding: CGFloat = 18
    /// `UserDefaults` key holding the JSON `PillPlacement`. Deliberately *not*
    /// the Keychain: the Keychain blob is a once-per-launch credential read and
    /// this is rewritten on every drag.
    static let placementDefaultsKey = "dev.kleoth.dictation.pillPlacement"

    /// What the SwiftUI content renders.
    let model = DictationPillModel()

    var onAction: ((DictationPillAction) -> Void)?
    var onDismiss: (() -> Void)?

    private let defaults: UserDefaults
    private var panel: DictationPanel?
    /// Auto-hide (`.done` 1 s / `.warning` 3 s) and the deferred order-out after
    /// the fade. Cancel-and-restart: one slot, cancelled by every `show`.
    private var hideTask: Task<Void, Never>?
    private var screenObserver: (any NSObjectProtocol)?
    /// `setResting(true)`: the compact capsule stays up between sessions and
    /// `dismiss()` collapses to it instead of hiding the panel.
    private var restingVisible = false
    /// `NSScreenNumber` of the display the panel was last anchored on. A tucked
    /// panel's frame straddles a screen edge, so deriving its screen from the
    /// frame is unreliable; this is the source of truth while it is up.
    private var currentDisplayId: UInt32?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Re-anchor when a display is added, removed, or resized so the pill can
        // never be stranded off-screen while it is up.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reanchorAfterScreenChange() }
        }
    }

    // MARK: DictationPillPresenting

    func show(_ state: DictationPillState) {
        hideTask?.cancel()
        hideTask = nil

        guard state != .hidden else {
            dismiss()
            return
        }

        let panel = ensurePanel()
        // "Already up" means visible AND presented — a panel caught mid fade-out
        // is re-anchored and springs in again.
        let alreadyUp = panel.isVisible && model.isPresented
        let screen = (alreadyUp ? panelScreen() : nil) ?? anchorScreen()
        currentDisplayId = screen?.kleothDisplayId
        // Width is capped to the screen the pill will sit on, so an unbounded
        // message truncates inside the capsule instead of pushing the ✕ off
        // the right edge (`PillGeometry.maxPanelWidth`).
        let edge = restingEdge(on: screen)
        let size = Self.panelSize(for: state, edge: edge, in: screen.map(Self.bounds))
        let target = CGRect(origin: origin(for: state, panelSize: size, edge: edge, on: screen), size: size)

        model.apply(restingEdge: edge)
        model.apply(phase: state)

        if alreadyUp {
            // Resting → active rises out of the edge; active → resting sinks
            // back; phase swaps grow in place. One animated frame change.
            setFrame(target, animated: !Self.reduceMotion)
        } else {
            // A fresh show starts from the tucked spot and emerges, so even the
            // first pill of the day comes in from the edge rather than popping.
            let tucked = CGRect(origin: restingOrigin(activeOrigin: target.origin, panelSize: size, edge: edge, on: screen), size: size)
            panel.setFrame(tucked, display: false)
            panel.orderFrontRegardless()
            present()
            if target != tucked {
                setFrame(target, animated: !Self.reduceMotion)
            }
        }

        announce(state)
        scheduleAutoHide(for: state)
    }

    func setLevel(_ level: Double) {
        guard panel?.isVisible == true else { return }
        model.apply(level: level)
    }

    func dismiss() {
        hideTask?.cancel()
        hideTask = nil

        if restingVisible {
            collapseToResting()
            return
        }
        hideCompletely()
    }

    func setResting(_ visible: Bool) {
        guard restingVisible != visible else { return }
        restingVisible = visible
        if visible {
            // Only take over an empty or already-resting panel — never
            // interrupt a live phase; `dismiss()` lands on `.idle` later.
            if model.phase == .hidden || model.phase == .idle { show(.idle) }
        } else if model.phase == .idle {
            hideCompletely()
        }
    }

    /// Phase → `.idle` on the visible panel (shrinks around the current
    /// center), or a fresh spring-in if the panel is down.
    private func collapseToResting() {
        if model.phase == .idle, panel?.isVisible == true, model.isPresented { return }
        show(.idle)
    }

    private func hideCompletely() {
        guard let panel, panel.isVisible else {
            model.isPresented = false
            model.apply(phase: .hidden)
            return
        }

        guard !Self.reduceMotion else {
            finishHide(panel)
            return
        }

        withAnimation(.easeOut(duration: Self.fadeOutDuration)) {
            model.isPresented = false
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.fadeOutDuration * 1000)))
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            self.finishHide(panel)
        }
    }

    /// Forgets the saved placement and, if the pill is up, walks it back to the
    /// default bottom-center spot (tucked, if it is resting). Settings →
    /// "Reset pill position".
    func resetPosition() {
        defaults.removeObject(forKey: Self.placementDefaultsKey)
        guard let panel, panel.isVisible, let screen = defaultScreen() else { return }
        currentDisplayId = screen.kleothDisplayId
        let edge = restingEdge(on: screen)
        model.apply(restingEdge: edge)
        let size = Self.panelSize(for: model.phase, edge: edge, in: Self.bounds(of: screen))
        let origin = origin(for: model.phase, panelSize: size, edge: edge, on: screen)
        setFrame(CGRect(origin: origin, size: size), animated: !Self.reduceMotion)
    }

    // MARK: View-facing API (DictationPillView)

    /// Current panel origin, captured once at drag start.
    var panelOrigin: CGPoint { panel?.frame.origin ?? .zero }

    /// Live drag. The caller computes `origin` from `NSEvent.mouseLocation`
    /// deltas — never `DragGesture.Value.translation`, which double-counts as
    /// the window moves under the cursor.
    func moveDuringDrag(to origin: CGPoint) {
        guard let panel else { return }
        let screen = screen(containing: CGRect(origin: origin, size: panel.frame.size)) ?? defaultScreen()
        guard let screen else {
            panel.setFrameOrigin(origin)
            return
        }
        // A resting pill pops fully on screen while it is being dragged (the
        // clamp keeps the whole capsule visible) and tucks back on release.
        panel.setFrameOrigin(
            PillGeometry.clamp(origin, panelSize: panel.frame.size, in: Self.bounds(of: screen))
        )
    }

    /// Persists where the user dropped the pill, as fractions of the screen it
    /// landed on (see `PillPlacement`). The drop spot is the new *anchor*; a
    /// resting pill then slides back into the nearest edge from there.
    func commitDraggedPlacement() {
        guard let panel else { return }
        let frame = panel.frame
        guard let screen = screen(containing: frame) ?? defaultScreen() else { return }
        currentDisplayId = screen.kleothDisplayId
        let placement = PillGeometry.placement(
            origin: frame.origin,
            panelSize: frame.size,
            in: Self.bounds(of: screen),
            displayId: screen.kleothDisplayId ?? 0,
            displayName: screen.localizedName
        )
        if let data = try? JSONEncoder().encode(placement) {
            defaults.set(data, forKey: Self.placementDefaultsKey)
        }
        guard model.phase == .idle else { return }
        // The dragged tab may have crossed to another edge: re-size (a side
        // edge stands the tab up) and tuck into the new nearest edge.
        let edge = restingEdge(on: screen)
        model.apply(restingEdge: edge)
        let size = Self.panelSize(for: .idle, edge: edge, in: Self.bounds(of: screen))
        let active = activeOrigin(panelSize: size, on: screen)
        let tucked = restingOrigin(activeOrigin: active, panelSize: size, edge: edge, on: screen)
        setFrame(CGRect(origin: tucked, size: size), animated: !Self.reduceMotion)
    }

    /// The pill's action button. The handler lives in `DictationController`;
    /// note for whoever writes it: the rest of the app opens Settings through
    /// SwiftUI's `@Environment(\.openSettings)` (MenuView.swift), but the pill is
    /// an AppKit panel driven from a controller with no SwiftUI environment, so
    /// `.openSettings` is handled with the responder-chain selector
    /// (`NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`
    /// after an explicit `NSApp.activate` — the one place on this path where
    /// stealing focus is intended). Don't "fix" it back to the environment value.
    func perform(_ action: DictationPillAction) {
        onAction?(action)
    }

    /// ✕, or a click anywhere on a `.failed` pill.
    func dismissFromUser() {
        dismiss()
        onDismiss?()
    }

    // MARK: Panel

    private func ensurePanel() -> DictationPanel {
        if let panel { return panel }
        let size = Self.panelSize(for: .idle)
        let panel = DictationPanel(contentRect: CGRect(origin: .zero, size: size))
        let hosting = DictationPillHostingView(
            rootView: AnyView(DictationPillView(controller: self).environmentObject(model))
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func present() {
        guard !Self.reduceMotion else {
            model.isPresented = true
            return
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            model.isPresented = true
        }
    }

    private func finishHide(_ panel: DictationPanel) {
        // `orderOut`, never `close()`: the panel is reused for the app's
        // lifetime (`isReleasedWhenClosed = false` guards the mistake anyway).
        panel.orderOut(nil)
        model.isPresented = false
        model.apply(phase: .hidden)
    }

    private func scheduleAutoHide(for state: DictationPillState) {
        guard let delay = state.autoHideAfter else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// One animated frame change for every move the pill makes — rising out of
    /// the edge, sinking back, growing between phases, walking home after a
    /// reset. `animator().setFrame` (not `setFrame(animate:)`, which blocks the
    /// main thread with a synchronous run loop). The curve overshoots a touch
    /// so the rise reads as a spring, not a slide.
    private func setFrame(_ target: CGRect, animated: Bool) {
        guard let panel, target != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.1, 0.3, 1.0)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// Displays changed: put the pill back on its anchor (tucked if resting)
    /// on whatever screen still exists, without animation.
    private func reanchorAfterScreenChange() {
        guard let panel, panel.isVisible else { return }
        guard let screen = panelScreen() ?? anchorScreen() else { return }
        currentDisplayId = screen.kleothDisplayId
        let edge = restingEdge(on: screen)
        model.apply(restingEdge: edge)
        let size = Self.panelSize(for: model.phase, edge: edge, in: Self.bounds(of: screen))
        let target = CGRect(origin: origin(for: model.phase, panelSize: size, edge: edge, on: screen), size: size)
        setFrame(target, animated: false)
    }

    // MARK: Placement

    /// The anchor: the saved placement if its display is still around, else
    /// bottom-center of the screen **under the mouse**. For an `.accessory` app
    /// with no key window `NSScreen.main` is whatever screen last had one —
    /// unreliable — while the mouse is where the user is looking.
    private func activeOrigin(panelSize size: CGSize, on screen: NSScreen?) -> CGPoint {
        guard let screen else { return .zero }
        let bounds = Self.bounds(of: screen)
        if let placement = savedPlacement(), self.screen(for: placement)?.kleothDisplayId == screen.kleothDisplayId {
            return PillGeometry.origin(for: placement, panelSize: size, in: bounds)
        }
        return PillGeometry.defaultOrigin(panelSize: size, shadowPadding: Self.shadowPadding, in: bounds)
    }

    /// The edge the resting tab tucks into on `screen`: the one nearest the
    /// anchor. Decided from the horizontal resting size so that standing the
    /// tab up for a side edge cannot flip the answer.
    private func restingEdge(on screen: NSScreen?) -> PillGeometry.Edge {
        guard let screen else { return .bottom }
        let size = Self.panelSize(for: .idle, edge: .bottom, in: Self.bounds(of: screen))
        let active = activeOrigin(panelSize: size, on: screen)
        return PillGeometry.nearestEdge(ofPanelAt: active, panelSize: size, in: screen.frame)
    }

    /// The anchor slid into `edge` of `screen` until half the panel is
    /// off-screen — where `.idle` lives.
    private func restingOrigin(
        activeOrigin: CGPoint, panelSize size: CGSize, edge: PillGeometry.Edge, on screen: NSScreen?
    ) -> CGPoint {
        guard let screen else { return activeOrigin }
        return PillGeometry.restingOrigin(activeOrigin: activeOrigin, panelSize: size, edge: edge, in: screen.frame)
    }

    /// Where a phase sits: active phases on the anchor, `.idle` tucked.
    private func origin(
        for state: DictationPillState, panelSize size: CGSize, edge: PillGeometry.Edge, on screen: NSScreen?
    ) -> CGPoint {
        let active = activeOrigin(panelSize: size, on: screen)
        guard state == .idle else { return active }
        return restingOrigin(activeOrigin: active, panelSize: size, edge: edge, on: screen)
    }

    /// The area an active pill may occupy on `screen` — the full display minus
    /// the menu bar (`PillGeometry.bounds`), so it can sit over the Dock.
    private static func bounds(of screen: NSScreen) -> CGRect {
        PillGeometry.bounds(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    /// The screen the visible panel belongs to: the one it was anchored on if
    /// it still exists, else whichever screen holds most of its frame.
    private func panelScreen() -> NSScreen? {
        if let id = currentDisplayId, let screen = NSScreen.screens.first(where: { $0.kleothDisplayId == id }) {
            return screen
        }
        guard let panel else { return nil }
        return screen(containing: panel.frame)
    }

    /// The screen `activeOrigin` will anchor on — the saved placement's display
    /// if it is still around, else the one under the mouse.
    private func anchorScreen() -> NSScreen? {
        if let placement = savedPlacement(), let screen = screen(for: placement) {
            return screen
        }
        return defaultScreen()
    }

    private func savedPlacement() -> PillPlacement? {
        guard let data = defaults.data(forKey: Self.placementDefaultsKey) else { return nil }
        // A stale or hand-edited blob simply means "no saved position".
        return try? JSONDecoder().decode(PillPlacement.self, from: data)
    }

    /// Resolve the saved display: by `NSScreenNumber` first, then by name plus a
    /// matching bounds size (ids change on replug).
    private func screen(for placement: PillPlacement) -> NSScreen? {
        if let byId = NSScreen.screens.first(where: { $0.kleothDisplayId == placement.displayId }) {
            return byId
        }
        return NSScreen.screens.first {
            let bounds = Self.bounds(of: $0)
            return $0.localizedName == placement.displayName
                && abs(bounds.width - CGFloat(placement.visibleWidth)) < 1
                && abs(bounds.height - CGFloat(placement.visibleHeight)) < 1
        }
    }

    private func defaultScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func screen(containing frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max(by: {
                $0.frame.intersection(frame).area < $1.frame.intersection(frame).area
            })
    }

    // MARK: Sizing

    private static let fadeOutDuration: Double = 0.18
    /// Capsule heights per phase; the panel adds `shadowPadding` above and
    /// below. Resting is a sliver (and only half of it is on screen), motion
    /// phases a short bar, text phases the old label height.
    static func capsuleHeight(for state: DictationPillState) -> CGFloat {
        switch state {
        case .idle: return PillStyle.restingHeight
        case .hidden, .listening, .transcribing, .polishing, .done: return 32
        case .warning, .failed: return 38
        }
    }
    /// Slack so a font or locale wider than measured never clips: the capsule
    /// sizes itself to its content, the panel just has to be big enough to hold
    /// it (extra width is transparent margin).
    private static let widthSlack: CGFloat = 20

    /// Panel size for a phase. Motion phases have fixed content widths that
    /// mirror `PillStyle`; text phases are measured from the label. Computed
    /// rather than read from `fittingSize` so the frame is known synchronously,
    /// before SwiftUI has laid the new phase out. When `visibleFrame` is known
    /// the width is capped to it (the label then truncates — `DictationPillView`).
    static func panelSize(
        for state: DictationPillState, edge: PillGeometry.Edge = .bottom, in visibleFrame: CGRect? = nil
    ) -> CGSize {
        // A resting tab on a side edge stands up: the view rotates the capsule
        // 90°, so the panel swaps its dimensions to hold it.
        if state == .idle, edge == .left || edge == .right {
            return CGSize(
                width: PillStyle.restingHeight + 2 * shadowPadding,
                height: PillStyle.restingWidth + 2 * shadowPadding
            )
        }
        var width: CGFloat
        switch state {
        case .hidden, .idle:
            width = PillStyle.restingWidth
        case .listening(let handsFree):
            width = PillStyle.waveformWidth + 2 * PillStyle.compactPadding
                + (handsFree ? 6 + KleothMetrics.spacingS : 0)
        case .transcribing, .polishing:
            width = PillStyle.waveformWidth + 2 * PillStyle.compactPadding
        case .done:
            // Keep the bar's width so the check appears in place of the wave.
            width = PillStyle.waveformWidth + 2 * PillStyle.compactPadding
        case .warning, .failed:
            width = 20 + KleothMetrics.spacingS + textWidth(state.pillText, style: .callout, weight: .medium)
            if let action = state.fault?.action {
                width += KleothMetrics.spacingS + textWidth(action.title, style: .caption1, weight: .semibold) + 22
            }
            if state.isSticky {
                width += KleothMetrics.spacingS + 18
            }
            width += 2 * KleothMetrics.spacingM
        }
        width += 2 * shadowPadding + widthSlack
        width = ceil(width)
        if let visibleFrame {
            width = PillGeometry.cappedPanelWidth(width, in: visibleFrame)
        }
        return CGSize(width: width, height: capsuleHeight(for: state) + 2 * shadowPadding)
    }

    private static func textWidth(_ text: String, style: NSFont.TextStyle, weight: NSFont.Weight) -> CGFloat {
        let base = NSFont.preferredFont(forTextStyle: style)
        let font = NSFont.systemFont(ofSize: base.pointSize, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    // MARK: Environment

    /// System-wide "Reduce motion". Read at call time — the user can flip it
    /// while the app runs.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The pill is not a key window, so VoiceOver never focuses it: each phase
    /// has to be spoken explicitly.
    private func announce(_ state: DictationPillState) {
        guard state != .idle else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: state.pillText,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

// MARK: - Phase copy

extension DictationPillState {
    /// The one line the pill shows (and VoiceOver announces).
    var pillText: String {
        switch self {
        case .hidden: return ""
        case .idle: return "Dictation ready — hold \(DictationDefaults.hotkeyDescription) to speak"
        case .listening(let handsFree):
            return handsFree ? "Listening — tap \(DictationDefaults.hotkeyDescription) to stop" : "Listening…"
        case .transcribing: return "Transcribing…"
        case .polishing: return "Polishing…"
        case .done: return "Pasted"
        case .warning(let message): return message
        case .failed(let fault): return fault.text
        }
    }

    /// Leading SF Symbol, or `nil` for `.listening` (which shows the meter).
    var symbolName: String? {
        switch self {
        case .hidden, .idle, .listening: return nil
        case .transcribing: return "waveform"
        case .polishing: return "sparkles"
        case .done: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    /// `.failed` sticks around until the user dismisses it or a new session
    /// replaces it — it is the only phase with a ✕.
    var isSticky: Bool {
        if case .failed = self { return true }
        return false
    }

    var fault: DictationPillFault? {
        if case .failed(let fault) = self { return fault }
        return nil
    }
}

// MARK: - AppKit helpers

extension NSScreen {
    /// `NSScreenNumber` — the stable-ish id `PillPlacement` records.
    /// Acronym-free name, per the project's stored-key convention.
    var kleothDisplayId: UInt32? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
