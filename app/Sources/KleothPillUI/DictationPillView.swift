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
        Color.clear
            .overlay { pill }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(model.phase.pillText))
    }

    private var pill: some View {
        // The hit shape is the CAPSULE, not the panel rect: the transparent
        // shadow margin around it must stay non-interactive, or a `.statusBar`-
        // level panel would swallow clicks aimed at the app underneath.
        capsule
            // The capsule sizes itself to its content whatever the panel's
            // size: while a transition is in flight the panel is a stage
            // larger than the capsule, and on a side edge it is narrower than
            // the capsule's un-rotated length. Text still cannot run away —
            // the label carries an explicit, screen-capped width.
            .fixedSize()
            .contentShape(Capsule(style: .continuous))
            .gesture(dragGesture)
            .onTapGesture {
                if model.phase.isSticky { controller.dismissFromUser() }
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

    private var capsule: some View {
        HStack(spacing: PillStyle.spacingS) {
            content
        }
        // The content is revealed by the motion beat (`Choreography.content`)
        // so a rising pill is a plain blob until it has left the edge.
        .modifier(ContentReveal(beat: model.beat, reduceMotion: reduceMotion))
        // Explicit, animatable size — see `DictationPillModel.capsuleSize`.
        .frame(width: model.capsuleSize.width, height: model.capsuleSize.height)
        .clipShape(Capsule(style: .continuous))
        .background(PillStyle.surface, in: Capsule(style: .continuous))
        .overlay(
            // Resting gets a visible white rim so the half-hidden tab reads as
            // an edge of something, not a smudge; active phases keep the hairline.
            Capsule(style: .continuous)
                .strokeBorder(
                    (model.phase == .idle || model.phase == .armed) ? PillStyle.restingRim : PillStyle.rim,
                    lineWidth: (model.phase == .idle || model.phase == .armed) ? 1 : PillStyle.hairline
                )
        )
        .overlay {
            if model.phase == .idle {
                RestingSheen(brightEndAtTop: model.edge == .bottom, reduceMotion: reduceMotion)
                    // Quick in/out: riding the 0.5 s shape spring left a pale,
                    // sheen-lit blob climbing out of the edge.
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }

        // Resting is quieter than active: lower opacity so it reads as an
        // indicator, not a window.
        .opacity(model.phase == .idle ? PillStyle.restingOpacity : 1)
        .shadow(color: .black.opacity(model.phase == .idle ? 0.18 : 0.28), radius: 10, y: 3)
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
    private var edgeRotation: Angle {
        switch model.edge {
        case .bottom, .top: return .zero
        case .left: return .degrees(-90)
        case .right: return .degrees(90)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .idle, .armed:
            // Nothing when tucked (anything centered would be cut in half);
            // a mic glyph fades in while the capsule is fully on screen —
            // under the pointer, or on the chord's first frame (`.armed`).
            ZStack {
                Color.clear
                    .frame(width: PillStyle.restingWidth - 2 * PillStyle.compactPadding, height: 1)
                if model.peeking || model.phase == .armed {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PillStyle.ink)
                        .rotationEffect(-edgeRotation)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                        .accessibilityHidden(true)
                }
            }
            .transition(.opacity)
        case .listening(let handsFree):
            if handsFree {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
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
        // T0 placeholder — T2 draws the recording dot + elapsed digits, the
        // travelling save wave, and the green saved confirmation.
        case .recording, .saving, .saved:
            EmptyView()
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
    /// from the cursor. `minimumDistance: 3` leaves the buttons clickable.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
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

    private static let weights: [Double] = {
        (0..<PillStyle.barCount).map { index in
            let x = (Double(index) - Double(PillStyle.barCount - 1) / 2) / (Double(PillStyle.barCount) / 2)
            return 0.35 + 0.65 * exp(-2.2 * x * x)
        }
    }()

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
        HStack(alignment: .center, spacing: PillStyle.barSpacing) {
            ForEach(0..<PillStyle.barCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: PillStyle.barWidth, height: height(index: index, time: time))
            }
        }
        .frame(width: PillStyle.waveformWidth, height: PillStyle.barMaxHeight, alignment: .center)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch mode {
        case .live: return PillStyle.ink
        case .wave(let tint, _): return tint
        }
    }

    private func height(index: Int, time: TimeInterval) -> CGFloat {
        let span = PillStyle.barMaxHeight - PillStyle.barMinHeight
        let unit: Double
        switch mode {
        case .live(let level):
            guard !reduceMotion else { unit = 0.45 * Self.weights[index]; break }
            let clamped = level.isFinite ? min(max(level, 0), 1) : 0
            // Organic drift: two slow sines per bar, small enough that silence
            // is a soft shimmer and speech is clearly the mic.
            let drift = 0.5 + 0.5 * sin(time * 2.1 + Double(index) * 0.8) * sin(time * 0.9 + Double(index) * 0.35)
            let floor = 0.06 + 0.10 * drift
            unit = floor + (1 - floor) * clamped * Self.weights[index] * (0.8 + 0.2 * drift)
        case .wave(_, let speed):
            guard !reduceMotion else { unit = 0.45 * Self.weights[index]; break }
            let phase = time * 2.6 * speed - Double(index) * 0.55
            unit = 0.18 + 0.62 * (0.5 + 0.5 * sin(phase)) * Self.weights[index]
        }
        return PillStyle.barMinHeight + span * CGFloat(min(max(unit, 0), 1))
    }
}
