import SwiftUI
import AppKit
import KleothCore

/// The dictation pill: a small dark capsule that lives at the bottom of the
/// screen while dictation is armed and shows what dictation is doing with
/// motion, not words (design §5.6, reworked 2026-09-03 after the user asked for
/// a Wispr-Flow-style bar).
///
/// Phases:
/// - `.idle` — a small resting capsule parked half off the nearest screen edge
///   (the controller places it; `PillGeometry.restingOrigin`), breathing a
///   soft sheen. No content: with half of it off-screen anything centered in
///   the capsule would be cut in two, so the shape itself is the indicator.
/// - `.listening` — expands into a live 14-bar waveform driven by the mic level
///   (an accent dot marks hands-free mode).
/// - `.transcribing` / `.polishing` — the bars carry a travelling wave
///   (polishing is accent-tinted) so "still working" is visible without text.
/// - `.done` — a green check for a second, then back to resting.
/// - `.warning` / `.failed` — the only phases with text: the user needs to
///   know *why* something degraded or failed, and `.failed` carries an action.
///
/// Since the screen-recording pass the pill is also the recorder's control
/// surface (screen-recording design §6):
/// - `.recording(since:)` — the BACKDROP while a screen recording runs: a live
///   TOOLBAR (`RecordingToolbar`) — a pulsing red dot, monospaced `mm:ss` off
///   the session's own `since`, a mic and a system level meter, and a Stop
///   button. ONLY the Stop button stops; the rest of the bar is the drag
///   handle. It stays horizontal on every edge (`DictationPillModel.flat`).
/// - `.saving` — the same capsule with a full-width travelling wave while the
///   movie is finalized.
/// - `.saved("2:14 · 48 MB")` — a green check and the text for 4 s; a click
///   reveals the file in Finder.
/// A peeked `.idle` pill grows a red record glyph next to the mic: that (or a
/// tap on the capsule) is where a recording starts.
///
/// Every phase still exposes its sentence through `.help` (hover) and VoiceOver.
///
/// Motion: this view animates NOTHING on its own. The controller changes
/// `phase`, `offset`, and `edge` inside one `withAnimation(spring)`, so the
/// capsule's size, position, rotation, and content transitions all ride the
/// same spring (`DictationPillController.transitionSpring`). The panel's own
/// frame is never animated — AppKit's timer-driven window animator fighting a
/// SwiftUI spring was the jerky transition the user rejected.
struct DictationPillView: View {
    /// Not owned — the controller owns the hosting view that owns this view.
    private unowned let controller: DictationPillController

    @EnvironmentObject private var model: DictationPillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True between the first `onChanged` and `onEnded` of a drag.
    @State private var dragging = false

    init(controller: DictationPillController) {
        self.controller = controller
    }

    var body: some View {
        // LOAD-BEARING: the ROOT is a clear, fully flexible base and the
        // capsule is only an overlay on it. `NSHostingView` grows its window
        // (`setContentSize`, top-left anchored — regardless of `sizingOptions`)
        // whenever the panel is smaller than the root view's MINIMUM size, and
        // the capsule is laid out un-rotated (`.fixedSize()`, then
        // `rotationEffect`), so on a side edge its ideal width (68–131 pt +
        // shadow) exceeds the thin vertical panel (58–68 pt). With the capsule
        // as the root, every `settle()` was followed by the window widening
        // to the right and the capsule re-centering 23–31 pt off its anchor —
        // the "forced shift" the user saw on the right edge. An overlay does
        // not contribute to its base's size, so the root's minimum is zero
        // and the controller stays the only thing that sizes the panel.
        // The `GeometryReader` is as flexible (and as size-less) as the clear
        // colour; it only reports the root's size so the pointer can be
        // re-expressed relative to the capsule's centre (`dockPointer`).
        GeometryReader { proxy in
            Color.clear
                .overlay { pill(rootSize: proxy.size) }
        }
            // The pointer is reported in THIS space (see `PillSpace`), so the
            // Stop button can work out whether it is under the cursor without
            // SwiftUI's `.onHover`, which never fires for an inactive app.
            .coordinateSpace(name: PillSpace.root)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(model.phase.pillText))
    }

    /// The pointer relative to the capsule's centre, in the capsule's OWN
    /// (un-rotated) space, or nil when it is off the panel. The capsule is
    /// centred on the root, displaced by `offset` and turned by
    /// `edgeRotation`; undoing those here is what lets the peek dock's glyphs
    /// light up correctly on a side edge too, without trusting what
    /// `GeometryReader` reports through a `rotationEffect`.
    private func dockPointer(rootSize: CGSize) -> CGPoint? {
        guard let pointer = model.pointer else { return nil }
        let center = CGPoint(
            x: rootSize.width / 2 + model.offset.width,
            y: rootSize.height / 2 + model.offset.height
        )
        let dx = pointer.x - center.x
        let dy = pointer.y - center.y
        let angle = -edgeRotation.radians
        return CGPoint(x: dx * cos(angle) - dy * sin(angle), y: dx * sin(angle) + dy * cos(angle))
    }

    private func pill(rootSize: CGSize) -> some View {
        // The hit shape is the CAPSULE, not the panel rect: the transparent
        // shadow margin around it must stay non-interactive, or a `.statusBar`-
        // level panel would swallow clicks aimed at the app underneath.
        capsule(dockPointer: dockPointer(rootSize: rootSize))
            // The capsule sizes itself to its content whatever the panel's
            // size: while a transition is in flight the panel is a stage
            // larger than the capsule, and on a side edge it is narrower than
            // the capsule's un-rotated length. Text still cannot run away —
            // the label carries an explicit, screen-capped width.
            .fixedSize()
            .contentShape(Capsule(style: .continuous))
            .gesture(dragGesture)
            // Click routing (screen-recording design §6.4). The capsule IS the
            // control in the recording phases, so a tap on it is the action —
            // never a dismissal.
            .onTapGesture {
                switch model.phase {
                case .failed:
                    controller.dismissFromUser()
                case .idle where model.peeking:
                    // The body of the peek dock opens the menu; the glyphs on
                    // it are the direct actions. Nothing starts from a stray
                    // click on the capsule any more.
                    controller.openMenu()
                case .listening(handsFree: true):
                    controller.perform(.stopHandsFreeDictation)
                case .saved:
                    controller.perform(.revealLastRecording)
                default:
                    // `.recording` deliberately does NOT stop here: the bar is
                    // a toolbar with its own Stop button, and everything else
                    // on it is the drag handle. A whole-capsule stop was one
                    // slipped click away from ending a recording the user was
                    // only trying to move.
                    break
                }
            }
            .help(model.phase.pillText)
            // A pill on a side edge stands up in every phase. Applied AFTER
            // the hit shape and gestures so they rotate with it — a horizontal
            // hit capsule under a vertical bar would leave only its middle
            // clickable.
            .rotationEffect(edgeRotation)
            .offset(model.offset)
            .scaleEffect(model.isPresented ? 1 : 0.9, anchor: .center)
            .opacity(model.isPresented ? 1 : 0)
            .padding(DictationPillController.shadowPadding)
    }

    private func capsule(dockPointer: CGPoint?) -> some View {
        HStack(spacing: PillStyle.spacingS) {
            content(dockPointer: dockPointer)
        }
        // The content is revealed by the motion beat (`Choreography.content`)
        // so a rising pill is a plain blob until it has left the edge.
        .modifier(ContentReveal(beat: model.beat, reduceMotion: reduceMotion))
        // Explicit, animatable size — see `DictationPillModel.capsuleSize`.
        .frame(width: model.capsuleSize.width, height: model.capsuleSize.height)
        .clipShape(Capsule(style: .continuous))
        .background { surface }
        .overlay { rim }
        .overlay {
            if model.phase == .idle, !dockOut {
                RestingSheen(brightEndAtTop: model.edge == .bottom, reduceMotion: reduceMotion)
                    // Quick in/out: riding the 0.5 s shape spring left a pale,
                    // sheen-lit blob climbing out of the edge.
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        // Resting is quieter than active: lower opacity so it reads as an
        // indicator, not a window.
        .opacity(model.phase == .idle && !dockOut ? PillStyle.restingOpacity : 1)
        .shadow(
            color: .black.opacity(softShadow ? 0.14 : (model.phase == .idle ? 0.18 : 0.28)),
            radius: softShadow ? 14 : 10,
            y: softShadow ? 5 : 3
        )
        // Breathes with the voice: a touch of scale on the mic level so the
        // whole pill feels alive, not just the bars inside it.
        .scaleEffect(1 + (reduceMotion ? 0 : 0.045 * model.level))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: model.level)
        // Keyframed squash-and-stretch along the travel axis, retriggered by
        // every motion beat. In the capsule's own (un-rotated) space travel is
        // always along its THICKNESS (y): a bottom pill rises vertically, a
        // side pill is rotated 90° so its screen-horizontal slide is its own y.
        .keyframeAnimator(
            initialValue: Choreography(kind: model.beat.kind),
            trigger: model.beat
        ) { content, pose in
            content.scaleEffect(
                x: reduceMotion ? 1 : pose.across,
                y: reduceMotion ? 1 : pose.along
            )
        } keyframes: { pose in
            KeyframeTrack(\.along) {
                switch pose.kind {
                case .rise:
                    CubicKeyframe(0.82, duration: 0.05)   // anticipation: squat in the edge
                    SpringKeyframe(1.32, duration: 0.12, spring: .snappy)   // stretch on the way up
                    SpringKeyframe(0.9, duration: 0.1, spring: .snappy)   // land: squash
                    SpringKeyframe(1.0, duration: 0.25, spring: .bouncy)
                case .sink:
                    CubicKeyframe(1.18, duration: 0.06)   // lift before the dive
                    SpringKeyframe(0.8, duration: 0.16, spring: .snappy)   // flatten into the edge
                    SpringKeyframe(1.0, duration: 0.22, spring: .smooth)
                case .peek:
                    CubicKeyframe(0.9, duration: 0.04)
                    SpringKeyframe(1.16, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.22, spring: .bouncy)
                case .morph:
                    CubicKeyframe(0.94, duration: 0.06)
                    SpringKeyframe(1.0, duration: 0.22, spring: .bouncy)
                }
            }
            KeyframeTrack(\.across) {
                switch pose.kind {
                case .rise:
                    CubicKeyframe(1.14, duration: 0.05)
                    SpringKeyframe(0.9, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1.07, duration: 0.1, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.25, spring: .bouncy)
                case .sink:
                    CubicKeyframe(0.94, duration: 0.06)
                    SpringKeyframe(1.12, duration: 0.16, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.22, spring: .smooth)
                case .peek:
                    CubicKeyframe(1.06, duration: 0.04)
                    SpringKeyframe(0.94, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.22, spring: .bouncy)
                case .morph:
                    CubicKeyframe(1.05, duration: 0.06)
                    SpringKeyframe(1.0, duration: 0.22, spring: .bouncy)
                }
            }
        }
    }

    /// One pose of the squash-and-stretch: scale along the travel axis and
    /// across it, in the capsule's own space. `kind` rides along so the
    /// keyframes can pick their shape from the initial value.
    private struct Choreography {
        var kind: MotionBeat.Kind
        var along: CGFloat = 1
        var across: CGFloat = 1
    }

    /// Horizontal on the bottom and top edges; on a side edge the pill stands
    /// up in every phase, turned so text reads the way a spine label does —
    /// bottom-to-top on the left, top-to-bottom on the right.
    /// The peek dock is out (or held out by its menu).
    private var dockOut: Bool { model.phase == .idle && (model.peeking || model.menuOpen) }

    /// Which dock surface is on the capsule: one of the two dock looks
    /// (`PillDockStyle`; Liquid Glass needs macOS 26 and falls back to ink)
    /// for as long as the dock is HELD — out, or collapsing back into the
    /// sliver (`DictationPillModel.dockHeld`) — else none (`.pill`).
    private var dockSurface: DockSurface {
        guard model.dockHeld else { return .pill }
        return model.dock.resolvedStyle == .glass ? .glass : .ink
    }

    /// The dock's soft, wide shadow — only while the glass dock is out.
    private var softShadow: Bool { dockOut && dockSurface == .glass }

    private enum DockSurface: Equatable { case pill, glass, ink }

    /// Two LAYERS, never a swap (filmed 2026-09-09, the "oversized boxes" on
    /// the collapse): SwiftUI keeps a removed view on screen for its
    /// transition at the size it had when removed, top-left anchored, so
    /// swapping the dock's surface for the pill's at the start of the
    /// collapse left a full-size ghost of the dock fading behind the
    /// shrinking sliver. Now the pill's own fill is ALWAYS mounted and only
    /// fades, and the dock's surface stays mounted from the moment the dock
    /// comes out until the collapse has settled (`dockSurface`): it shrinks
    /// with the capsule under the fading-in pill fill and leaves at settle,
    /// sliver-sized and covered.
    @ViewBuilder
    private var surface: some View {
        ZStack {
            dockFill
            Capsule(style: .continuous)
                .fill(PillStyle.surface)
                .opacity(dockOut ? 0 : 1)
        }
        // The dark sliver cross-fades into the dock's surface as it comes out,
        // and back as it collapses.
        .animation(.easeOut(duration: 0.2), value: dockOut)
        .animation(.easeOut(duration: 0.2), value: dockSurface)
    }

    @ViewBuilder
    private var dockFill: some View {
        switch dockSurface {
        case .glass:
            if #available(macOS 26, *) {
                // Real Liquid Glass — the CLEAR variant over a dimming layer,
                // Apple's own recipe for glass that must stay dark. Found the
                // hard way (timed screen grabs, 2026-09-09): `.regular` glass
                // ADAPTS its tone to the backdrop's brightness about half a
                // second after it appears, so over a light page it started
                // dark and turned near-white with white ink on it (the
                // "white background" the user saw); a black `.tint` did not
                // help (glass tints are faint accents), nor did pinning the
                // window's appearance alone. `.clear` does not adapt, and the
                // dark capsule UNDER it (same window, so the glass refracts
                // it) is what the glass sees. The fields inside are NOT glass
                // (never stack glass on glass) — they light with a quiet plate.
                ZStack {
                    Capsule(style: .continuous).fill(Color.black.opacity(PillDockStyle.dim))
                    Color.clear.glassEffect(.clear, in: Capsule(style: .continuous))
                }
            }
        case .ink:
            Capsule(style: .continuous).fill(PillDockStyle.inkSurface)
        case .pill:
            EmptyView()
        }
    }

    /// Same two-layer rule as `surface`: the pill's rim only fades; the ink
    /// rim (a stroke — its full-size removal ghost read as an outline) is held
    /// with the dock's surface and fades with the fields. Glass has no rim.
    @ViewBuilder
    private var rim: some View {
        ZStack {
            if dockSurface == .ink {
                // Lit from above: a bright top edge fading out down the sides.
                Capsule(style: .continuous)
                    .strokeBorder(PillDockStyle.inkRim, lineWidth: 1)
                    .opacity(dockOut ? 1 : 0)
            }
            // Resting gets a visible white rim so the half-hidden tab reads as
            // an edge of something, not a smudge; active phases keep the hairline.
            Capsule(style: .continuous)
                .strokeBorder(
                    (model.phase == .idle || model.phase == .armed)
                        ? PillStyle.restingRim
                        : (model.hovered ? PillStyle.hoverRim : PillStyle.rim),
                    lineWidth: (model.phase == .idle || model.phase == .armed) ? 1 : PillStyle.hairline
                )
                .animation(.easeOut(duration: 0.15), value: model.hovered)
                .opacity(dockOut ? 0 : 1)
        }
        .animation(.easeOut(duration: 0.2), value: dockOut)
    }

    private var edgeRotation: Angle {
        // A flat phase (the recording toolbar, and every dictation phase over a
        // live recording) never stands up — see `DictationPillModel.flat`.
        guard !model.flat else { return .zero }
        switch model.edge {
        case .bottom, .top: return .zero
        case .left: return .degrees(-90)
        case .right: return .degrees(90)
        }
    }

    @ViewBuilder
    private func content(dockPointer: CGPoint?) -> some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .idle, .armed:
            // Nothing when tucked (anything centered would be cut in half).
            // Under the pointer the resting sliver becomes the PEEK DOCK —
            // three glyphs (dictate · record · menu), each with its own hover
            // lift; on the chord's first frame (`.armed`) only the mic glyph.
            ZStack {
                Color.clear
                    .frame(width: PillStyle.restingWidth - 2 * PillStyle.compactPadding, height: 1)
                if model.phase == .armed {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PillStyle.ink)
                        .rotationEffect(-edgeRotation)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                        .accessibilityHidden(true)
                }
                if model.dockHeld {
                    // Mounted for as long as the dock's SURFACE is (see
                    // `surface`) and only FADED out — fast, before the capsule
                    // has shrunk around the fields — never removed while the
                    // capsule is being resized: a removed view's ghost keeps
                    // its old size and drifted off-centre for its 0.1 s fade
                    // (filmed). It leaves at settle, already invisible.
                    PeekDock(
                        metrics: model.dock,
                        pointer: dockPointer,
                        rotation: edgeRotation,
                        menuOpen: model.menuOpen,
                        onDictate: { controller.perform(.startHandsFreeDictation) },
                        onRecord: { controller.perform(.startScreenRecording) },
                        onMenu: { controller.openMenu() }
                    )
                    .opacity(dockOut ? 1 : 0)
                    .allowsHitTesting(dockOut)
                    .animation(.easeOut(duration: 0.1), value: dockOut)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.6)).animation(.easeOut(duration: 0.2)),
                        removal: .identity
                    ))
                }
            }
            .transition(.opacity)
        case .listening(let handsFree):
            if handsFree {
                // Hands-free: the accent dot says "no key is held"; under the
                // pointer it becomes a stop glyph, because a click on this
                // capsule ends the dictation.
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .opacity(model.hovered ? 0 : 1)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(Color.accentColor)
                        .rotationEffect(-edgeRotation)
                        .opacity(model.hovered ? 1 : 0)
                        .scaleEffect(model.hovered ? 1 : 0.5)
                }
                .frame(width: 10, height: 10)
                .animation(.spring(duration: 0.18, bounce: 0.35), value: model.hovered)
                .onChange(of: model.hovered) { _, on in
                    (on ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
                .transition(.opacity)
                .accessibilityHidden(true)
            }
            Waveform(mode: .live(level: model.level), reduceMotion: reduceMotion)
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
        case .transcribing:
            Waveform(mode: .wave(tint: PillStyle.ink, speed: 1.0), reduceMotion: reduceMotion)
                .transition(.opacity)
        case .polishing:
            Waveform(mode: .wave(tint: Color.accentColor, speed: 1.6), reduceMotion: reduceMotion)
                .transition(.opacity)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(PillStyle.successTint)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .accessibilityHidden(true)
        case .warning(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.callout)
                .foregroundStyle(PillStyle.pendingTint)
                .accessibilityHidden(true)
            label(message)
        case .failed(let fault):
            Image(systemName: "xmark.octagon.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.callout)
                .foregroundStyle(PillStyle.failureTint)
                .accessibilityHidden(true)
            label(fault.text)
            if let action = fault.action {
                Button(action.title) { controller.perform(action) }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Button {
                controller.dismissFromUser()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PillStyle.ink.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        case .recording(let since):
            RecordingToolbar(
                since: since,
                levels: model.recordingLevels,
                barHovered: model.hovered,
                pointer: model.pointer,
                reduceMotion: reduceMotion,
                onStop: { controller.perform(.stopScreenRecording) }
            )
            .transition(.opacity)
        case .saving:
            // Same capsule as `.recording` (the controller keeps the size), the
            // toolbar replaced by a travelling wave the full width of the bar:
            // "still working". A 14-bar wave would float in 75 pt of empty dark
            // at either end now that the bar is a toolbar.
            Waveform(
                mode: .wave(tint: PillStyle.ink, speed: 1.0),
                reduceMotion: reduceMotion,
                barCount: PillStyle.savingBarCount
            )
            .transition(.opacity)
        case .saved(let text):
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(PillStyle.successTint)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .accessibilityHidden(true)
            label(text)
        }
    }

    /// No `.fixedSize()`: the panel width is capped to the screen
    /// (`PillGeometry.maxPanelWidth`), so an over-long message truncates here
    /// instead of forcing the HStack — and the ✕ — off-screen.
    private func label(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(PillStyle.ink)
            .lineLimit(1)
            .truncationMode(.tail)
            // Measured + capped by the controller (`DictationPillModel.labelWidth`);
            // with `.fixedSize()` on the capsule this is what makes a
            // screen-wide message truncate instead of overflow.
            .frame(width: model.labelWidth, alignment: .leading)
    }

    /// The pill slides along its edge (and re-docks when dragged clearly
    /// toward another one); the controller reads `NSEvent.mouseLocation`
    /// itself — `value.translation` is measured against a coordinate space
    /// that moves with the window, so it double-counts and the pill runs away
    /// from the cursor. `minimumDistance: 6` leaves the buttons clickable and
    /// is forgiving of a jittery click: raised from 3 once the capsule became a
    /// start/stop CONTROL (§6.4) — a hand that drifts two points while pressing
    /// "stop" must stop the recording, not re-dock the pill.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { _ in
                if !dragging {
                    dragging = true
                    controller.beginDrag()
                }
                controller.dragMoved()
            }
            .onEnded { _ in
                guard dragging else { return }
                controller.dragMoved()
                dragging = false
                controller.commitDraggedPlacement()
            }
    }
}

// MARK: - Peek dock

/// The resting pill under the pointer (interaction demo, 2026-09-08; scaled up
/// and split into fields 2026-09-09 — the user on the first cut: "so small…
/// too dense… three independent fields"; restyled the same day — "ugly gray…
/// cheap highlighting… regular liquid glass controls, or beautiful"):
///
///     ╭──────────┬──────────┬──────────╮
///     │    🎙    │    ●     │    ⋯     │
///     │ Dictate  │  Record  │   More   │
///     ╰──────────┴──────────┴──────────╯
///
/// Three fields on ONE surface (the capsule — Liquid Glass or the ink look,
/// see `PillDockStyle`), separated by hairlines rather than plates. The field
/// under the pointer gets a QUIET lift: a faint white plate, brighter ink, a
/// 3 % scale, and the hairlines beside it fade — nothing changes colour (the
/// user on the first, tinted version: "less provocative, less nudgy… nothing
/// turning blue"). Every point of the capsule
/// belongs to a field (the gaps and insets are folded into the hit areas), so
/// hovering anywhere lights something. Hover is computed from the panel-wide
/// pointer (relative to the capsule's centre, un-rotated —
/// `DictationPillView.dockPointer`), never from `.onHover`, which is dead
/// while another app is active. Geometry comes from `PillDockMetrics`, which
/// the sandbox scales and restyles live.
private struct PeekDock: View {
    let metrics: PillDockMetrics
    let pointer: CGPoint?
    let rotation: Angle
    let menuOpen: Bool
    let onDictate: () -> Void
    let onRecord: () -> Void
    let onMenu: () -> Void

    /// Which field the pointer is over. The capsule is divided into three
    /// fields along its length, so a pointer anywhere on it picks the nearest.
    private var hotIndex: Int? {
        guard let pointer else { return nil }
        let size = metrics.size
        guard abs(pointer.x) <= size.width / 2, abs(pointer.y) <= size.height / 2 else { return nil }
        let index = Int((pointer.x / metrics.pitch).rounded()) + 1
        return min(max(index, 0), 2)
    }

    var body: some View {
        let hot = hotIndex
        let look = metrics.resolvedStyle
        HStack(spacing: 0) {
            PillDockTile(
                metrics: metrics, look: look, symbol: "mic.fill", caption: "Dictate", label: "Start a dictation",
                glyph: nil,
                hot: hot == 0, lit: false, divider: !(hot == 0 || hot == 1), rotation: rotation, action: onDictate
            )
            PillDockTile(
                metrics: metrics, look: look, symbol: "record.circle.fill", caption: "Record", label: "Record the screen",
                glyph: PillStyle.recordTint,
                hot: hot == 1, lit: false, divider: !(hot == 1 || hot == 2), rotation: rotation, action: onRecord
            )
            PillDockTile(
                metrics: metrics, look: look, symbol: "ellipsis", caption: "More", label: "More",
                glyph: nil,
                hot: hot == 2, lit: menuOpen, divider: false, rotation: rotation, action: onMenu
            )
        }
        .onChange(of: hot) { _, index in
            (index == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        }
        .accessibilityElement(children: .contain)
    }
}

/// One field on the peek dock. The visible plate (only while lit) is
/// `metrics.tile`; the hit area extends half a gap sideways and the vertical
/// inset up and down, so the three fields tile the capsule with no dead zone
/// between them.
private struct PillDockTile: View {
    let metrics: PillDockMetrics
    let look: PillDockStyle
    let symbol: String
    let caption: String
    let label: String
    /// The glyph's own colour; nil = the surface's ink.
    let glyph: Color?
    let hot: Bool
    let lit: Bool
    /// A hairline on the trailing edge, separating this field from the next.
    let divider: Bool
    let rotation: Angle
    let action: () -> Void

    private var active: Bool { hot || lit }

    /// Hover only BRIGHTENS: the glyph keeps its own colour (the red record
    /// dot stays red), the ink goes from soft white to full white.
    private var iconStyle: AnyShapeStyle {
        if let glyph { return AnyShapeStyle(glyph) }
        return AnyShapeStyle(active ? Color.white : PillDockStyle.ink(look))
    }

    private var captionStyle: AnyShapeStyle {
        AnyShapeStyle(active ? Color.white.opacity(0.9) : PillDockStyle.captionInk(look))
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if active {
                    RoundedRectangle(cornerRadius: metrics.tileRadius, style: .continuous)
                        .fill(Color.white.opacity(PillDockStyle.hoverPlate(look)))
                        .transition(.opacity)
                }
                VStack(spacing: metrics.captionGap) {
                    Image(systemName: symbol)
                        .font(.system(size: metrics.iconSize, weight: .semibold))
                        .foregroundStyle(iconStyle)
                        // A fixed slot: the glyphs differ in height (the ⋯ is
                        // a quarter of the mic's), so without it the More
                        // caption sat higher than its neighbours and the dots
                        // lower than the other glyphs' centres (user, 2026-09-09).
                        .frame(height: metrics.iconSlotHeight)
                    if metrics.showsCaptions {
                        Text(caption)
                            .font(.system(size: metrics.captionSize, weight: .medium))
                            .foregroundStyle(captionStyle)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                // Upright on every edge (the capsule itself is rotated there).
                .rotationEffect(-rotation)
            }
            .frame(width: metrics.tile.width, height: metrics.tile.height)
            .scaleEffect(hot ? 1.03 : 1)
            .padding(.horizontal, metrics.gap / 2)
            .padding(.vertical, metrics.verticalInset)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                if divider {
                    Rectangle()
                        .fill(PillDockStyle.divider(look))
                        .frame(width: 1, height: metrics.tile.height * 0.5)
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(PillDockTileStyle())
        .animation(.spring(duration: 0.22, bounce: 0.25), value: active)
        .animation(.easeOut(duration: 0.15), value: divider)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Pressed = a quick squash; works for an inactive app (`isPressed` comes
/// from the button's own gesture, not from hover tracking).
private struct PillDockTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.14, bounce: 0.3), value: configuration.isPressed)
    }
}

// MARK: - Recording toolbar

/// The pill's coordinate spaces. `root` is the whole panel — the space
/// `DictationPillHostingView` reports the pointer in, so any control inside can
/// ask "am I under the cursor?" without `.onHover` (dead for an inactive app).
enum PillSpace {
    static let root = "kleoth.pill.root"
}

/// The live screen-recording bar (2026-09-07 — the user on the old capsule:
/// "ugly, small, non-responsive, not animated").
///
///     [● pulsing red dot] [02:14] [mic meter] [sys meter] [■ Stop]
///
/// Every width here mirrors `PillStyle.recordingContentWidth`, which is what
/// `DictationPillController.layout` sizes the capsule from — change one and
/// change the other, or the bar clips.
///
/// Only the Stop button stops the recording. The rest of the bar is the drag
/// handle, so nudging the pill along its edge can never end a recording.
private struct RecordingToolbar: View {
    let since: Date
    /// Already normalized + smoothed by the controller.
    let levels: AudioLevels
    /// The pointer is somewhere on the bar (from the panel-wide tracking area).
    let barHovered: Bool
    /// Where exactly, in `PillSpace.root`, so Stop can light up on its own.
    let pointer: CGPoint?
    let reduceMotion: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            RecordingDot(reduceMotion: reduceMotion)
            gap(PillStyle.spacingS)
            elapsed
            gap(PillStyle.spacingM)
            LevelMeter(symbol: "mic.fill", level: levels.mic, reduceMotion: reduceMotion)
            gap(PillStyle.spacingS)
            LevelMeter(symbol: "speaker.wave.2.fill", level: levels.system, reduceMotion: reduceMotion)
            gap(PillStyle.spacingM)
            StopButton(barHovered: barHovered, pointer: pointer, action: onStop)
        }
        .padding(.horizontal, PillStyle.compactPadding)
        .accessibilityElement(children: .contain)
    }

    private func gap(_ width: CGFloat) -> some View {
        Color.clear.frame(width: width, height: 1)
    }

    /// `TimelineView(.periodic(from: since, by: 1))` ticks on the session's own
    /// second boundary, so the digits change exactly when the recording's
    /// seconds do; the fixed box (wide enough for `1:02:34` in caption
    /// monospaced) keeps the bar from re-measuring when an hour field appears.
    private var elapsed: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let text = ElapsedFormatter.string(seconds: Int(context.date.timeIntervalSince(since)))
            Text(text)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(PillStyle.ink)
                .lineLimit(1)
                .accessibilityLabel(Text("Recording, \(text) elapsed"))
        }
        .frame(width: PillStyle.elapsedWidth)
    }
}

/// The red "we are rolling" dot: a circle breathing on a ~1.2 s cycle in the
/// universal record colour — scale AND opacity, so it reads at 9 pt. A
/// `TimelineView` is mounted only while this view is, so the pill costs nothing
/// when it is not recording. Static under Reduce Motion.
private struct RecordingDot: View {
    let reduceMotion: Bool

    private static let period: Double = 1.2

    var body: some View {
        if reduceMotion {
            dot(scale: 1, opacity: 1)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let phase = cos(context.date.timeIntervalSinceReferenceDate * 2 * .pi / Self.period)
                dot(scale: 0.86 + 0.14 * phase, opacity: 0.72 + 0.28 * phase)
            }
        }
    }

    private func dot(scale: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(PillStyle.recordTint)
            .frame(width: PillStyle.recordDotSize, height: PillStyle.recordDotSize)
            .scaleEffect(scale)
            .opacity(opacity)
            .accessibilityHidden(true)
    }
}

/// A four-segment level meter behind a glyph: the mic and the system feed each
/// get one, driven by `DictationPillController.setRecordingLevels` at 20 Hz.
/// Segments light cumulatively (bar *i* fills as the level crosses `i/4`), so a
/// glance says "both sides are live" without a number.
private struct LevelMeter: View {
    let symbol: String
    /// 0…1, normalized + smoothed.
    let level: Double
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: PillStyle.spacingXS) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(PillStyle.ink.opacity(0.55))
                .frame(width: PillStyle.meterGlyphWidth)
            HStack(alignment: .center, spacing: PillStyle.meterBarSpacing) {
                ForEach(0..<PillStyle.meterBarCount, id: \.self) { index in
                    let fill = segment(index)
                    Capsule(style: .continuous)
                        .fill(PillStyle.ink.opacity(0.26 + 0.74 * fill))
                        .frame(
                            width: PillStyle.meterBarWidth,
                            height: PillStyle.meterBarMinHeight
                                + (PillStyle.meterBarMaxHeight - PillStyle.meterBarMinHeight) * fill
                        )
                }
            }
            .frame(height: PillStyle.meterBarMaxHeight)
        }
        // The levels already arrive smoothed at 20 Hz; this only takes the
        // stair-step off the 50 ms grid.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: level)
        .accessibilityHidden(true)
    }

    private func segment(_ index: Int) -> CGFloat {
        let count = Double(PillStyle.meterBarCount)
        let value = level.isFinite ? min(max(level, 0), 1) : 0
        return CGFloat(min(max((value - Double(index) / count) * count, 0), 1))
    }
}

/// The one control that stops a recording. Red, always visible, and lit when
/// the pointer is actually over it.
///
/// Its own hover state cannot come from `.onHover` (SwiftUI's tracking area is
/// key-window-only and this panel is never key), so it reads the pointer the
/// panel's `.activeAlways` tracking area reports and compares it with its own
/// frame in `PillSpace.root`. `GeometryProxy.frame(in:)` is LAYOUT geometry —
/// which is exactly right here, because a flat recording bar carries no
/// `rotationEffect`, and `offset`/`scaleEffect` are both zero once a transition
/// has settled.
private struct StopButton: View {
    let barHovered: Bool
    let pointer: CGPoint?
    let action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let hot = pointer.map {
                proxy.frame(in: .named(PillSpace.root)).insetBy(dx: -4, dy: -4).contains($0)
            } ?? false
            button(hot: hot)
        }
        .frame(width: PillStyle.stopButtonSize, height: PillStyle.stopButtonSize)
    }

    private func button(hot: Bool) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(PillStyle.recordTint.opacity(hot ? 1.0 : (barHovered ? 0.32 : 0.18)))
                Circle().strokeBorder(
                    PillStyle.recordTint.opacity(hot ? 0 : (barHovered ? 0.85 : 0.5)),
                    lineWidth: 1
                )
                Image(systemName: "stop.fill")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(hot ? Color.white : PillStyle.recordTint)
            }
            .frame(width: PillStyle.stopButtonSize, height: PillStyle.stopButtonSize)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.12), value: hot)
        .animation(.easeOut(duration: 0.12), value: barHovered)
        .help("Stop recording")
        .accessibilityLabel("Stop recording")
    }
}

// MARK: - Content reveal

/// Fades the capsule's content with the motion: hidden for the first stretch
/// of a rise (the pill leaves the edge as a plain blob, then the bars bloom
/// in), gone early on a sink, untouched for in-place morphs and peeks.
private struct ContentReveal: ViewModifier {
    let beat: MotionBeat
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(initialValue: Reveal(kind: beat.kind), trigger: beat) { content, reveal in
                content
                    .opacity(reduceMotion ? 1 : reveal.opacity)
                    .scaleEffect(reduceMotion ? 1 : reveal.scale)
            } keyframes: { reveal in
                KeyframeTrack(\.opacity) {
                    switch reveal.kind {
                    case .rise:
                        CubicKeyframe(0.0, duration: 0.08)
                        CubicKeyframe(1.0, duration: 0.16)
                    case .sink:
                        CubicKeyframe(0.0, duration: 0.1)
                    case .morph, .peek:
                        CubicKeyframe(1.0, duration: 0.01)
                    }
                }
                KeyframeTrack(\.scale) {
                    switch reveal.kind {
                    case .rise:
                        CubicKeyframe(0.6, duration: 0.08)
                        SpringKeyframe(1.0, duration: 0.22, spring: .bouncy)
                    case .sink:
                        CubicKeyframe(0.7, duration: 0.1)
                    case .morph, .peek:
                        CubicKeyframe(1.0, duration: 0.01)
                    }
                }
            }
    }

    private struct Reveal {
        var kind: MotionBeat.Kind
        var opacity: Double = 1
        var scale: CGFloat = 1
        init(kind: MotionBeat.Kind) {
            self.kind = kind
            // A rise starts hidden; everything else starts visible.
            opacity = kind == .rise ? 0 : 1
            scale = kind == .rise ? 0.6 : 1
        }
    }
}

// MARK: - Style

/// The pill's own look. Deliberately NOT the app's `.regularMaterial`: a
/// waveform needs a dark, quiet ground to read on top of any document, light or
/// dark, and Wispr-style bars are what the user asked for. Ink is white-on-dark
/// regardless of appearance.
enum PillStyle {
    static let surface = Color(white: 0.09).opacity(0.86)
    static let rim = Color.white.opacity(0.12)
    static let restingRim = Color.white.opacity(0.42)
    static let ink = Color.white.opacity(0.92)
    static let restingOpacity: Double = 0.9
    static let compactPadding: CGFloat = 14

    // Spacing / tints mirrored from the app's `KleothMetrics` / `KleothPalette`
    // (this library must not depend on the app target).
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let hairline: CGFloat = 1
    static let pendingTint: Color = .orange
    static let successTint: Color = .green
    static let failureTint: Color = .red
    /// The recording dot and the peek's record glyph. Deliberately a fixed red
    /// rather than the accent colour: "we are rolling" is a convention the user
    /// should not have to learn, and it must read the same on every theme.
    static let recordTint = Color(red: 1.0, green: 0.27, blue: 0.23)

    // Waveform geometry — `DictationPillController.contentWidth` mirrors these.
    static let barCount = 14
    static let barWidth: CGFloat = 2.5
    static let barSpacing: CGFloat = 2.5
    static let barMinHeight: CGFloat = 3
    static let barMaxHeight: CGFloat = 18
    static var waveformWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    // Resting capsule. Only half of it is on screen (`PillGeometry.restingOrigin`),
    // so these are the full shape's dimensions, not what the user sees.
    static let restingWidth: CGFloat = 68
    static let restingHeight: CGFloat = 22
    // The peek dock's geometry lives in `PillDockMetrics` (one scale factor,
    // turned live by the sandbox).
    /// An active capsule's rim under the pointer (the dock's rims live in
    /// `PillDockStyle`).
    static let hoverRim = Color.white.opacity(0.3)

    // MARK: Recording toolbar
    //
    // `RecordingToolbar` lays these out left→right and
    // `DictationPillController.layout(for: .recording…)` sizes the capsule from
    // `recordingContentWidth` + two `compactPadding`s. THE TWO MUST AGREE.

    static let recordDotSize: CGFloat = 9
    /// Fixed digit box — wide enough for `1:02:34`, so the bar never
    /// re-measures when a recording passes an hour.
    static let elapsedWidth: CGFloat = 56
    static let meterGlyphWidth: CGFloat = 12
    static let meterBarCount = 4
    static let meterBarWidth: CGFloat = 2.5
    static let meterBarSpacing: CGFloat = 2.5
    static let meterBarMinHeight: CGFloat = 4
    static let meterBarMaxHeight: CGFloat = 14
    static var meterWidth: CGFloat {
        meterGlyphWidth + spacingXS
            + CGFloat(meterBarCount) * meterBarWidth
            + CGFloat(meterBarCount - 1) * meterBarSpacing
    }
    static let stopButtonSize: CGFloat = 22
    /// ≈194 pt → a 222 pt capsule with the compact paddings.
    static var recordingContentWidth: CGFloat {
        recordDotSize + spacingS + elapsedWidth + spacingM
            + meterWidth + spacingS + meterWidth + spacingM + stopButtonSize
    }
    /// `.saving` keeps the recording capsule's width, so its travelling wave
    /// runs the whole bar rather than floating in the middle of it. Chosen so
    /// `barCount * (barWidth + barSpacing) - barSpacing` ≈ `recordingContentWidth`.
    static let savingBarCount = 39
}

// MARK: - Resting sheen

/// A slow, soft light that washes over the resting capsule — the "I'm here"
/// breath of a pill that is mostly off-screen. Its bright end is the one that
/// faces into the screen (the half the user can see). Static under Reduce Motion.
private struct RestingSheen: View {
    let brightEndAtTop: Bool
    let reduceMotion: Bool
    @State private var breathing = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                    startPoint: brightEndAtTop ? .top : .bottom,
                    endPoint: brightEndAtTop ? .bottom : .top
                )
            )
            .opacity(reduceMotion ? 0.5 : (breathing ? 1.0 : 0.15))
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.9).repeatForever(autoreverses: true),
                value: breathing
            )
            .onAppear { breathing = true }
            .onDisappear { breathing = false }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Waveform

/// Fourteen bars. Live mode follows the mic level with a bell-shaped weight
/// across the bars plus a slow organic drift so silence still looks alive;
/// wave mode runs a travelling sine — the "working" animation — with no mic
/// input. A `TimelineView` is mounted only while this view is, so the resting
/// pill costs nothing.
private struct Waveform: View {
    enum Mode: Equatable {
        case live(level: Double)
        case wave(tint: Color, speed: Double)
    }

    let mode: Mode
    let reduceMotion: Bool
    /// `.saving` runs the wave the whole width of the recording toolbar
    /// (`PillStyle.savingBarCount`); everything else uses the dictation bar.
    var barCount: Int = PillStyle.barCount

    /// Bell-shaped weight across the bars, computed for whatever count this
    /// instance has (cheap: at most a few dozen `exp`s per render).
    private var weights: [Double] {
        (0..<barCount).map { index in
            let x = (Double(index) - Double(barCount - 1) / 2) / (Double(barCount) / 2)
            return 0.35 + 0.65 * exp(-2.2 * x * x)
        }
    }

    private var width: CGFloat {
        CGFloat(barCount) * PillStyle.barWidth + CGFloat(barCount - 1) * PillStyle.barSpacing
    }

    var body: some View {
        if reduceMotion {
            bars(at: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                bars(at: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func bars(at time: TimeInterval) -> some View {
        let weights = self.weights
        return HStack(alignment: .center, spacing: PillStyle.barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: PillStyle.barWidth, height: height(index: index, time: time, weights: weights))
            }
        }
        .frame(width: width, height: PillStyle.barMaxHeight, alignment: .center)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch mode {
        case .live: return PillStyle.ink
        case .wave(let tint, _): return tint
        }
    }

    private func height(index: Int, time: TimeInterval, weights: [Double]) -> CGFloat {
        let span = PillStyle.barMaxHeight - PillStyle.barMinHeight
        let unit: Double
        switch mode {
        case .live(let level):
            guard !reduceMotion else { unit = 0.45 * weights[index]; break }
            let clamped = level.isFinite ? min(max(level, 0), 1) : 0
            // Organic drift: two slow sines per bar, small enough that silence
            // is a soft shimmer and speech is clearly the mic.
            let drift = 0.5 + 0.5 * sin(time * 2.1 + Double(index) * 0.8) * sin(time * 0.9 + Double(index) * 0.35)
            let floor = 0.06 + 0.10 * drift
            unit = floor + (1 - floor) * clamped * weights[index] * (0.8 + 0.2 * drift)
        case .wave(_, let speed):
            guard !reduceMotion else { unit = 0.45 * weights[index]; break }
            // The travelling wave keeps a constant phase per POINT rather than
            // per bar, so a 39-bar saving wave rolls at the same visible speed
            // as the 14-bar dictation one.
            let phase = time * 2.6 * speed - Double(index) * 0.55 * (Double(PillStyle.barCount) / Double(barCount))
            unit = 0.18 + 0.62 * (0.5 + 0.5 * sin(phase)) * weights[index]
        }
        return PillStyle.barMinHeight + span * CGFloat(min(max(unit, 0), 1))
    }
}

// MARK: - Dock metrics

/// The peek dock's geometry, from ONE scale factor. `scale` 1 is the first
/// cut (20 pt glyph targets in a 26 pt capsule); the default is 2.5× — the
/// user on that cut: "so small… scale it at least twice, maybe two and a
/// half". Everything the view draws and everything the controller sizes
/// derives from here, so the two can never disagree, and the sandbox turns
/// the one knob live (`DictationPillController.setDockScale`).
public struct PillDockMetrics: Equatable, Sendable {
    public var scale: CGFloat
    /// The dock's look (`PillDockStyle`); `resolvedStyle` applies availability.
    public var style: PillDockStyle

    public init(scale: CGFloat = PillDockMetrics.defaultScale, style: PillDockStyle = .glass) {
        self.scale = min(max(scale, 1), 5)
        self.style = style
    }

    public static let defaultScale: CGFloat = 2.5

    /// `style` as it will actually render: Liquid Glass needs macOS 26 and
    /// falls back to the ink look below it.
    public var resolvedStyle: PillDockStyle {
        if #available(macOS 26, *), style == .glass { return .glass }
        return .ink
    }

    /// Captions need room: below this the fields are plain squares.
    public var showsCaptions: Bool { scale >= 1.8 }
    /// One field's visible plate.
    public var tile: CGSize {
        CGSize(width: (showsCaptions ? 24 : 20) * scale, height: 20 * scale)
    }
    /// Round enough that the outer fields clear the capsule's round ends
    /// (a corner circle of this radius sits inside the capsule's end circle
    /// for every scale in range — checked at 1, 2.5 and 4).
    public var tileRadius: CGFloat { tile.height * 0.32 }
    /// Air between two plates.
    public var gap: CGFloat { 2 + 1.2 * scale }
    /// Air between a plate and the capsule's rim, across and along.
    public var verticalInset: CGFloat { 3 + 0.8 * scale }
    public var horizontalInset: CGFloat { 2 * verticalInset }
    /// Centre-to-centre distance between neighbouring fields — what the hit
    /// test and the sandbox's film pointer step by.
    public var pitch: CGFloat { tile.width + gap }
    public var iconSize: CGFloat { 11 + 4 * (scale - 1) }
    /// The glyph's slot in a tile — taller than the tallest glyph, so every
    /// caption sits on the same line whatever its glyph's height.
    public var iconSlotHeight: CGFloat { ceil(iconSize * 1.25) }
    public var captionSize: CGFloat { 9 + 0.8 * (scale - 2) }
    var captionGap: CGFloat { 1 + scale }
    /// The capsule around the three fields.
    public var size: CGSize {
        CGSize(
            width: ceil(3 * tile.width + 2 * gap + 2 * horizontalInset),
            height: ceil(tile.height + 2 * verticalInset)
        )
    }
}

// MARK: - Dock style

/// The two looks of the peek dock (2026-09-09 — the user on the plates: "ugly
/// gray… cheap highlighting… either regular liquid glass controls, or else
/// beautiful, stylish, not generic"). Both are compared live in the sandbox.
/// - `glass`: the capsule is real Liquid Glass (macOS 26) — the clear variant
///   over a dimming layer, so it stays dark and refracts what is behind it.
/// - `ink`: the pill's own dark family — a near-black surface with a touch
///   of blue, lit from above by a bright top rim.
/// In both, the hovered field gets only a faint white plate.
public enum PillDockStyle: String, Equatable, Sendable, CaseIterable {
    case glass
    case ink

    /// The ink dock's surface: near-black, a touch of blue so it is not a
    /// gray box, darker towards the bottom.
    static var inkSurface: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.17, green: 0.18, blue: 0.21).opacity(0.96),
                Color(red: 0.06, green: 0.07, blue: 0.09).opacity(0.96),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Lit from above: a bright top edge fading out down the sides.
    static var inkRim: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom)
    }

    /// Resting ink — soft white on both looks (dark glass is dark too), so
    /// a hovered field can brighten to full white.
    static func ink(_ look: PillDockStyle) -> Color {
        Color.white.opacity(look == .glass ? 0.86 : 0.84)
    }

    static func captionInk(_ look: PillDockStyle) -> Color {
        Color.white.opacity(look == .glass ? 0.62 : 0.58)
    }

    static func divider(_ look: PillDockStyle) -> AnyShapeStyle {
        AnyShapeStyle(Color.white.opacity(look == .glass ? 0.16 : 0.11))
    }

    /// The dimming layer under the clear glass (see `DictationPillView.surface`).
    static let dim: Double = 0.45

    /// The hovered field's plate: a faint white, nothing more.
    static func hoverPlate(_ look: PillDockStyle) -> Double {
        look == .glass ? 0.12 : 0.09
    }

}
