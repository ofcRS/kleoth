import AppKit
import SwiftUI
import KleothCore

/// Owns the dictation pill's panel: when it is on screen, where it sits, how it
/// moves between phases, and when it hides itself (design §3.19, §5.6).
///
/// Placement model (reworked 2026-09-03 after the reference bar): the pill has
/// ONE anchor — the saved placement, else bottom-center of the screen under the
/// mouse, just above its bottom edge. Every active phase sits on that anchor
/// (centered on it, so phase-to-phase size changes grow in place). The resting
/// `.idle` capsule is the same anchor slid into the nearest screen edge until
/// half of it is off-screen (`PillGeometry.restingOrigin`), and a chord makes
/// it rise back out to the anchor. Dragging moves the anchor. A pill whose
/// nearest edge is a side stands up — vertical in every phase.
///
/// Motion model: the panel's frame is NEVER animated. Every move is a
/// `transition(to:phase:)`: the panel is set — instantly — to a *stage* that
/// covers both the current and the destination rect, the capsule is placed on
/// the stage where it already is (no visible change), and one SwiftUI spring
/// then carries its `offset`, size, rotation, and content to the destination.
/// When the spring is logically complete the panel shrinks to the destination
/// rect and the offset returns to zero, again instantly and invisibly. Between
/// transitions the panel is exactly the capsule plus its shadow margin.
///
/// It is the `DictationPillPresenting` the controller talks to; all it exposes
/// upward is `show/setLevel/dismiss/setResting/resetPosition` plus the two
/// callbacks. All pure math lives in `PillGeometry` (KleothCore) so it can be
/// unit-tested — the app package has no test target.
@MainActor
final class DictationPillController: DictationPillPresenting {
    /// Transparent margin around the capsule. The SwiftUI content draws its
    /// shadow inside this, which is why the panel itself has `hasShadow = false`.
    static let shadowPadding: CGFloat = 18
    /// `UserDefaults` key holding the JSON `PillPlacement`. Deliberately *not*
    /// the Keychain: the Keychain blob is a once-per-launch credential read and
    /// this is rewritten on every drag.
    static let placementDefaultsKey = "dev.kleoth.dictation.pillPlacement"
    /// Motion is choreographed in two beats on two springs (duration/bounce
    /// form, macOS 14): the capsule MOVES on `moveSpring` and changes SHAPE on
    /// `shapeSpring`, one of them starting `stagger` after the other. Rising
    /// out of the edge: move first, then bloom into the bar. Sinking back:
    /// shrink first, then slide into the edge. The view adds a short
    /// squash-and-stretch on every phase change (`DictationPillView`), which
    /// lands during the stagger as anticipation.
    static let moveSpring: Animation = .spring(duration: 0.55, bounce: 0.3)
    static let shapeSpring: Animation = .spring(duration: 0.5, bounce: 0.25)
    static let stagger: TimeInterval = 0.09

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
    /// The rect the panel settles to when the in-flight transition completes;
    /// nil when the panel is settled (frame == capsule rect, offset == zero).
    private var pendingFrame: CGRect?
    /// Bumped by every transition, settle, and hide so a stale spring
    /// completion can never shrink the panel to a rect that is no longer the
    /// destination.
    private var transitionGeneration = 0

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
        let edge = restingEdge(on: screen)
        let layout = Self.layout(for: state, edge: edge, on: screen)
        let target = CGRect(origin: origin(for: state, panelSize: layout.panelSize, edge: edge, on: screen), size: layout.panelSize)

        // Not animated: the edge and label width describe the destination and
        // must be in place before the phase springs.
        model.apply(edge: edge)
        model.apply(labelWidth: layout.labelWidth)

        if alreadyUp {
            transition(to: target, phase: state)
        } else {
            // A fresh show starts from the tucked spot and emerges, so even the
            // first pill of the day comes in from the edge rather than popping.
            settle()
            let tucked = CGRect(
                origin: restingOrigin(activeOrigin: target.origin, panelSize: layout.panelSize, edge: edge, on: screen),
                size: layout.panelSize
            )
            panel.setFrame(tucked, display: false)
            model.apply(phase: state)
            panel.orderFrontRegardless()
            present()
            if target != tucked {
                transition(to: target, phase: state)
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

    /// Phase → `.idle` on the visible panel (sinks back into the edge), or a
    /// fresh spring-in if the panel is down.
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
        let layout = Self.layout(for: model.phase, edge: edge, on: screen)
        let origin = origin(for: model.phase, panelSize: layout.panelSize, edge: edge, on: screen)
        model.apply(edge: edge)
        model.apply(labelWidth: layout.labelWidth)
        transition(to: CGRect(origin: origin, size: layout.panelSize), phase: model.phase)
    }

    // MARK: View-facing API (DictationPillView)

    /// Called once at drag start: finishes any in-flight transition (so the
    /// panel is exactly the capsule and the drag moves what the user sees) and
    /// returns the panel origin the drag deltas are applied to.
    func beginDrag() -> CGPoint {
        settle()
        return panel?.frame.origin ?? .zero
    }

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
    /// landed on (see `PillPlacement`). The drop spot is the new *anchor*; the
    /// pill then re-lays out for the edge it is now nearest to (a side edge
    /// stands it up) and, if resting, slides back into that edge.
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
        let edge = restingEdge(on: screen)
        let layout = Self.layout(for: model.phase, edge: edge, on: screen)
        let origin = origin(for: model.phase, panelSize: layout.panelSize, edge: edge, on: screen)
        model.apply(edge: edge)
        model.apply(labelWidth: layout.labelWidth)
        transition(to: CGRect(origin: origin, size: layout.panelSize), phase: model.phase)
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
        let size = Self.layout(for: .idle, edge: .bottom, on: nil).panelSize
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
        // A hidden panel is settled by definition; forget any in-flight move.
        transitionGeneration += 1
        pendingFrame = nil
        model.apply(offset: .zero)
    }

    private func scheduleAutoHide(for state: DictationPillState) {
        guard let delay = state.autoHideAfter else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    // MARK: Motion

    /// Moves the capsule to `target` (a panel rect: capsule + shadow margin)
    /// and switches it to `phase`, on one spring. See the type comment for the
    /// stage technique. Under Reduce Motion the panel simply jumps.
    private func transition(to target: CGRect, phase: DictationPillState) {
        guard let panel else { return }
        transitionGeneration += 1
        let generation = transitionGeneration

        guard !Self.reduceMotion else {
            pendingFrame = nil
            model.apply(offset: .zero)
            model.apply(phase: phase)
            panel.setFrame(target, display: true)
            return
        }

        // Where the capsule logically is right now, in screen coordinates: the
        // panel's center displaced by the current offset (zero when settled,
        // the in-flight destination's when not — the spring re-targets from
        // wherever it actually is, keeping its velocity).
        let stageBefore = panel.frame
        let currentCenter = CGPoint(
            x: stageBefore.midX + model.offset.width,
            y: stageBefore.midY - model.offset.height
        )
        // The new stage covers the current stage (which contains the capsule
        // wherever the spring has it) and the destination.
        let stage = stageBefore.union(target)
        pendingFrame = target

        if stage != stageBefore {
            // Re-express the current position on the new stage and grow the
            // panel — in one turn, without animation, so nothing on screen
            // moves. `display: true` lays the hosting view out synchronously
            // with the new offset already applied.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                model.apply(offset: Self.offset(ofCenter: currentCenter, in: stage))
            }
            panel.setFrame(stage, display: true)
        }

        let destination = Self.offset(ofCenter: CGPoint(x: target.midX, y: target.midY), in: stage)
        // The animated changes go out on the NEXT main-queue callout so
        // SwiftUI has committed the re-expressed start position first; a
        // change in the same turn would spring from the previous graph value,
        // which is a different point on the new stage.
        Task { @MainActor [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            let moves = self.model.offset != destination
            let reshapes = self.model.phase != phase
            guard moves || reshapes else {
                self.settle()
                return
            }
            // Sinking to rest: shape first, then move. Everything else: move
            // first, then shape. The completion rides whichever beat ends
            // last — and only a beat that actually changes state, since a
            // no-op body completes immediately and would settle mid-flight.
            let shapeFirst = phase == .idle
            let moveAnimation = shapeFirst ? Self.moveSpring.delay(Self.stagger) : Self.moveSpring
            let shapeAnimation = shapeFirst ? Self.shapeSpring : Self.shapeSpring.delay(Self.stagger)
            let completeOnMove = moves && (shapeFirst || !reshapes)
            let settleWhenDone: () -> Void = { [weak self] in
                guard let self, self.transitionGeneration == generation else { return }
                self.settle()
            }
            if moves {
                if completeOnMove {
                    withAnimation(moveAnimation, completionCriteria: .logicallyComplete) {
                        self.model.apply(offset: destination)
                    } completion: { settleWhenDone() }
                } else {
                    withAnimation(moveAnimation) { self.model.apply(offset: destination) }
                }
            }
            if reshapes {
                if completeOnMove {
                    withAnimation(shapeAnimation) { self.model.apply(phase: phase) }
                } else {
                    withAnimation(shapeAnimation, completionCriteria: .logicallyComplete) {
                        self.model.apply(phase: phase)
                    } completion: { settleWhenDone() }
                }
            }
        }
    }

    /// Ends any in-flight transition NOW: panel = destination rect, offset =
    /// zero, both without animation and in the same turn, so the screen does
    /// not change. Safe to call when already settled.
    private func settle() {
        transitionGeneration += 1
        var still = Transaction()
        still.disablesAnimations = true
        guard let panel, let target = pendingFrame else {
            if model.offset != .zero {
                withTransaction(still) { model.apply(offset: .zero) }
            }
            return
        }
        pendingFrame = nil
        withTransaction(still) { model.apply(offset: .zero) }
        panel.setFrame(target, display: true)
    }

    /// A screen-space center → the capsule `offset` that puts it there on a
    /// panel whose frame is `stage` (SwiftUI's y grows downward).
    private static func offset(ofCenter center: CGPoint, in stage: CGRect) -> CGSize {
        CGSize(width: center.x - stage.midX, height: -(center.y - stage.midY))
    }

    /// Displays changed: put the pill back on its anchor (tucked if resting)
    /// on whatever screen still exists, without animation.
    private func reanchorAfterScreenChange() {
        guard let panel, panel.isVisible else { return }
        guard let screen = panelScreen() ?? anchorScreen() else { return }
        settle()
        currentDisplayId = screen.kleothDisplayId
        let edge = restingEdge(on: screen)
        let layout = Self.layout(for: model.phase, edge: edge, on: screen)
        model.apply(edge: edge)
        model.apply(labelWidth: layout.labelWidth)
        let target = CGRect(origin: origin(for: model.phase, panelSize: layout.panelSize, edge: edge, on: screen), size: layout.panelSize)
        panel.setFrame(target, display: true)
    }

    // MARK: Placement

    /// The panel size the anchor is resolved against: as long as the longest
    /// motion phase and as thick as a text phase. Resolving (and clamping)
    /// the anchor ONCE with this size, then centering every phase on it, is
    /// what keeps a pill parked near a corner from creeping: clamping each
    /// phase's own size shifted the center by the size difference, so a pill
    /// on the right edge near the bottom rose while growing and sank while
    /// shrinking — the "levitating" the user saw.
    private static func referenceSize(edge: PillGeometry.Edge, on screen: NSScreen?) -> CGSize {
        let long = layout(for: .listening(handsFree: true), edge: edge, on: screen).panelSize
        let thick = layout(for: .warning(""), edge: edge, on: screen).panelSize
        return (edge == .left || edge == .right)
            ? CGSize(width: thick.width, height: long.height)
            : CGSize(width: long.width, height: thick.height)
    }

    /// The anchor's center: the saved placement if its display is still
    /// around, else bottom-center of the screen **under the mouse**. For an
    /// `.accessory` app with no key window `NSScreen.main` is whatever screen
    /// last had one — unreliable — while the mouse is where the user is looking.
    private func anchorCenter(edge: PillGeometry.Edge, on screen: NSScreen) -> CGPoint {
        let bounds = Self.bounds(of: screen)
        let reference = Self.referenceSize(edge: edge, on: screen)
        let origin: CGPoint
        if let placement = savedPlacement(), self.screen(for: placement)?.kleothDisplayId == screen.kleothDisplayId {
            origin = PillGeometry.origin(for: placement, panelSize: reference, in: bounds)
        } else {
            origin = PillGeometry.defaultOrigin(panelSize: reference, shadowPadding: Self.shadowPadding, in: bounds)
        }
        return CGPoint(x: origin.x + reference.width / 2, y: origin.y + reference.height / 2)
    }

    /// A phase's active origin: its panel centered on the anchor. Clamping is
    /// a no-op for anything no larger than the reference size; only an
    /// over-long text pill can still be nudged.
    private func activeOrigin(panelSize size: CGSize, edge: PillGeometry.Edge, on screen: NSScreen?) -> CGPoint {
        guard let screen else { return .zero }
        let center = anchorCenter(edge: edge, on: screen)
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        return PillGeometry.clamp(origin, panelSize: size, in: Self.bounds(of: screen))
    }

    /// The edge the pill lives on for `screen`: the one nearest the anchor
    /// center (resolved with the horizontal reference so that standing the
    /// pill up for a side edge cannot flip the answer).
    private func restingEdge(on screen: NSScreen?) -> PillGeometry.Edge {
        guard let screen else { return .bottom }
        let center = anchorCenter(edge: .bottom, on: screen)
        return PillGeometry.nearestEdge(ofPanelAt: center, panelSize: .zero, in: screen.frame)
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
        let active = activeOrigin(panelSize: size, edge: edge, on: screen)
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
    /// Capsule heights per phase (its thickness — on a side edge this becomes
    /// the width); the panel adds `shadowPadding` on every side. Resting is a
    /// sliver (and only half of it is on screen), motion phases a short bar,
    /// text phases the old label height.
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

    /// Everything the panel and the view need to agree on for one phase on one
    /// edge: the panel's size (rotated for a side edge) and the explicit label
    /// width for text phases.
    struct Layout {
        var panelSize: CGSize
        var labelWidth: CGFloat?
    }

    /// The most a text label may take: a share of the screen along the pill's
    /// axis (its height on a side edge). Bounded below so a tiny or unknown
    /// screen still shows something.
    static func labelCap(edge: PillGeometry.Edge, on screen: NSScreen?) -> CGFloat {
        guard let screen else { return 600 }
        let bounds = bounds(of: screen)
        let axis = (edge == .left || edge == .right) ? bounds.height : bounds.width
        guard axis.isFinite, axis > 0 else { return 600 }
        return max(PillGeometry.minPanelWidth, floor(axis * 0.6))
    }

    /// Panel size for a phase. Motion phases have fixed content widths that
    /// mirror `PillStyle`; text phases are measured from the label and capped
    /// (`labelCap`). Computed rather than read from `fittingSize` so the frame
    /// is known synchronously, before SwiftUI has laid the new phase out. On a
    /// side edge the capsule is rotated 90°, so the panel swaps its dimensions.
    static func layout(for state: DictationPillState, edge: PillGeometry.Edge, on screen: NSScreen?) -> Layout {
        var length: CGFloat
        var labelWidth: CGFloat?
        switch state {
        case .hidden, .idle:
            length = PillStyle.restingWidth
        case .listening(let handsFree):
            length = PillStyle.waveformWidth + 2 * PillStyle.compactPadding
                + (handsFree ? 6 + KleothMetrics.spacingS : 0)
        case .transcribing, .polishing, .done:
            // `.done` keeps the bar's width so the check appears in place of the wave.
            length = PillStyle.waveformWidth + 2 * PillStyle.compactPadding
        case .warning, .failed:
            // +1: SwiftUI's ideal text width can round up a hair past AppKit's
            // measurement; a frame narrower than the ideal would truncate.
            let measured = textWidth(state.pillText, style: .callout, weight: .medium) + 1
            let label = min(measured, labelCap(edge: edge, on: screen))
            labelWidth = label
            length = 20 + KleothMetrics.spacingS + label
            if let action = state.fault?.action {
                length += KleothMetrics.spacingS + textWidth(action.title, style: .caption1, weight: .semibold) + 22
            }
            if state.isSticky {
                length += KleothMetrics.spacingS + 18
            }
            length += 2 * KleothMetrics.spacingM
        }
        length = ceil(length + 2 * shadowPadding + widthSlack)
        let thickness = capsuleHeight(for: state) + 2 * shadowPadding
        let size = (edge == .left || edge == .right)
            ? CGSize(width: thickness, height: length)
            : CGSize(width: length, height: thickness)
        return Layout(panelSize: size, labelWidth: labelWidth)
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
