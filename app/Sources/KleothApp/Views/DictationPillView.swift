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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(model.phase.pillText))
    }

    private var capsule: some View {
        HStack(spacing: KleothMetrics.spacingS) {
            content
        }
        .padding(.horizontal, model.phase.showsText ? KleothMetrics.spacingM : PillStyle.compactPadding)
        .frame(height: DictationPillController.capsuleHeight(for: model.phase))
        .background(PillStyle.surface, in: Capsule(style: .continuous))
        .overlay(
            // Resting gets a visible white rim so the half-hidden tab reads as
            // an edge of something, not a smudge; active phases keep the hairline.
            Capsule(style: .continuous)
                .strokeBorder(
                    model.phase == .idle ? PillStyle.restingRim : PillStyle.rim,
                    lineWidth: model.phase == .idle ? 1 : KleothMetrics.hairline
                )
        )
        .overlay {
            if model.phase == .idle {
                RestingSheen(brightEndAtTop: model.edge == .bottom, reduceMotion: reduceMotion)
                    .transition(.opacity)
            }
        }

        // Resting is quieter than active: lower opacity so it reads as an
        // indicator, not a window.
        .opacity(model.phase == .idle ? PillStyle.restingOpacity : 1)
        .shadow(color: .black.opacity(model.phase == .idle ? 0.18 : 0.28), radius: 10, y: 3)
        // Squash-and-stretch on every phase change: a quick stretch along the
        // pill's length that springs back, timed to land during the
        // controller's stagger before the shape beat — the anticipation that
        // makes the bloom read as elastic rather than a resize. Applied in the
        // capsule's own (un-rotated) space so a vertical pill stretches
        // vertically. No-op under Reduce Motion.
        .phaseAnimator([Squash.rest, .stretch], trigger: model.phase) { content, squash in
            content.scaleEffect(
                x: !reduceMotion && squash == .stretch ? 1.06 : 1,
                y: !reduceMotion && squash == .stretch ? 0.88 : 1
            )
        } animation: { squash in
            switch squash {
            case .stretch: .spring(duration: 0.2, bounce: 0.3)
            case .rest: .spring(duration: 0.45, bounce: 0.4)
            }
        }
    }

    private enum Squash { case rest, stretch }

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
        case .idle:
            Color.clear
                .frame(width: PillStyle.restingWidth - 2 * PillStyle.compactPadding, height: 1)
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
                .foregroundStyle(KleothPalette.successTint)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .accessibilityHidden(true)
        case .warning(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.callout)
                .foregroundStyle(KleothPalette.pendingTint)
                .accessibilityHidden(true)
            label(message)
        case .failed(let fault):
            Image(systemName: "xmark.octagon.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.callout)
                .foregroundStyle(KleothPalette.failureTint)
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
