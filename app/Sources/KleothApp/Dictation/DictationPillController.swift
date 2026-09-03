import AppKit
import SwiftUI
import KleothCore

/// Owns the dictation pill's panel: when it is on screen, where it sits, how it
/// resizes between phases, and when it hides itself (design §3.19, §5.6).
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Re-clamp when a display is added, removed, or resized so the pill can
        // never be stranded off-screen while it is up.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clampToCurrentScreen() }
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
        // Width is capped to the screen the pill will sit on, so an unbounded
        // message truncates inside the capsule instead of pushing the ✕ off
        // the right edge (`PillGeometry.maxPanelWidth`).
        let screen = (alreadyUp ? self.screen(containing: panel.frame) : nil) ?? anchorScreen()
        let size = Self.panelSize(for: state, in: screen?.visibleFrame)

        model.apply(phase: state)

        if alreadyUp {
            // Phase swap on a visible pill: grow/shrink around the current
            // center. `animator().setFrame` (not `setFrame(animate:)`, which
            // blocks the main thread with a synchronous run loop).
            setFrame(size: size, animated: !Self.reduceMotion)
        } else {
            panel.setFrame(CGRect(origin: anchorOrigin(panelSize: size), size: size), display: false)
            panel.orderFrontRegardless()
            present()
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
    /// default bottom-center spot. Settings → "Reset pill position".
    func resetPosition() {
        defaults.removeObject(forKey: Self.placementDefaultsKey)
        guard let panel, panel.isVisible, let screen = defaultScreen() else { return }
        let origin = PillGeometry.defaultOrigin(
            panelSize: panel.frame.size,
            shadowPadding: Self.shadowPadding,
            in: screen.visibleFrame
        )
        move(panel, to: origin, animated: !Self.reduceMotion)
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
        panel.setFrameOrigin(
            PillGeometry.clamp(origin, panelSize: panel.frame.size, in: screen.visibleFrame)
        )
    }

    /// Persists where the user dropped the pill, as fractions of the screen it
    /// landed on (see `PillPlacement`).
    func commitDraggedPlacement() {
        guard let panel else { return }
        let frame = panel.frame
        guard let screen = screen(containing: frame) ?? defaultScreen() else { return }
        let placement = PillGeometry.placement(
            origin: frame.origin,
            panelSize: frame.size,
            in: screen.visibleFrame,
            displayId: screen.kleothDisplayId ?? 0,
            displayName: screen.localizedName
        )
        guard let data = try? JSONEncoder().encode(placement) else { return }
        defaults.set(data, forKey: Self.placementDefaultsKey)
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
        let size = Self.panelSize(for: .listening(handsFree: false))
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

    private func setFrame(size: CGSize, animated: Bool) {
        guard let panel else { return }
        let current = panel.frame
        let center = CGPoint(x: current.midX, y: current.midY)
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        if let screen = screen(containing: current) ?? defaultScreen() {
            origin = PillGeometry.clamp(origin, panelSize: size, in: screen.visibleFrame)
        }
        let target = CGRect(origin: origin, size: size)
        guard target != current else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func move(_ panel: DictationPanel, to origin: CGPoint, animated: Bool) {
        let target = CGRect(origin: origin, size: panel.frame.size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func clampToCurrentScreen() {
        guard let panel, panel.isVisible else { return }
        guard let screen = screen(containing: panel.frame) ?? defaultScreen() else { return }
        let clamped = PillGeometry.clamp(
            panel.frame.origin, panelSize: panel.frame.size, in: screen.visibleFrame
        )
        if clamped != panel.frame.origin {
            panel.setFrameOrigin(clamped)
        }
    }

    // MARK: Placement

    /// Where a freshly shown pill goes: the saved placement if its display is
    /// still around, else bottom-center of the screen **under the mouse**. For
    /// an `.accessory` app with no key window `NSScreen.main` is whatever screen
    /// last had one — unreliable — while the mouse is where the user is looking.
    private func anchorOrigin(panelSize size: CGSize) -> CGPoint {
        if let placement = savedPlacement(), let screen = screen(for: placement) {
            return PillGeometry.origin(for: placement, panelSize: size, in: screen.visibleFrame)
        }
        guard let screen = defaultScreen() else { return .zero }
        return PillGeometry.defaultOrigin(
            panelSize: size, shadowPadding: Self.shadowPadding, in: screen.visibleFrame
        )
    }

    /// The screen `anchorOrigin` will pick — the saved placement's display if
    /// it is still around, else the one under the mouse.
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
    /// matching `visibleFrame` size (ids change on replug).
    private func screen(for placement: PillPlacement) -> NSScreen? {
        if let byId = NSScreen.screens.first(where: { $0.kleothDisplayId == placement.displayId }) {
            return byId
        }
        return NSScreen.screens.first {
            $0.localizedName == placement.displayName
                && abs($0.visibleFrame.width - CGFloat(placement.visibleWidth)) < 1
                && abs($0.visibleFrame.height - CGFloat(placement.visibleHeight)) < 1
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
    /// Capsule height; the panel adds `shadowPadding` above and below.
    private static let capsuleHeight: CGFloat = 38
    /// Leading element (the 5-bar meter or a phase glyph).
    private static let leadingWidth: CGFloat = 26
    /// Slack so a font or locale wider than measured never clips: the capsule
    /// sizes itself to its content, the panel just has to be big enough to hold
    /// it (extra width is transparent margin).
    private static let widthSlack: CGFloat = 20

    /// Panel size for a phase, measured from the label text. Computed rather
    /// than read from `fittingSize` so the frame is known synchronously, before
    /// SwiftUI has laid the new phase out. When `visibleFrame` is known the
    /// width is capped to it (the label then truncates — `DictationPillView`).
    static func panelSize(for state: DictationPillState, in visibleFrame: CGRect? = nil) -> CGSize {
        var width = leadingWidth + KleothMetrics.spacingS + textWidth(state.pillText, style: .callout, weight: .medium)
        if let action = state.fault?.action {
            width += KleothMetrics.spacingM + textWidth(action.title, style: .caption1, weight: .semibold) + 22
        }
        if state.isSticky {
            width += KleothMetrics.spacingS + 18
        }
        width += 2 * KleothMetrics.spacingM + 2 * shadowPadding + widthSlack
        width = ceil(width)
        if let visibleFrame {
            width = PillGeometry.cappedPanelWidth(width, in: visibleFrame)
        }
        return CGSize(width: width, height: capsuleHeight + 2 * shadowPadding)
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
        case .hidden, .listening: return nil
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
