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
struct DictationPillView: View {
    /// Not owned — the controller owns the hosting view that owns this view.
    private unowned let controller: DictationPillController

    @EnvironmentObject private var model: DictationPillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Drag anchors, captured from `NSEvent.mouseLocation` at drag start.
    @State private var dragStartMouse: CGPoint?
    @State private var dragStartOrigin: CGPoint = .zero

    init(controller: DictationPillController) {
        self.controller = controller
    }

    var body: some View {
        // The hit shape is the CAPSULE, not the panel rect: the transparent
        // shadow margin around it must stay non-interactive, or a `.statusBar`-
        // level panel would swallow clicks aimed at the app underneath.
        capsule
            .contentShape(Capsule(style: .continuous))
            .gesture(dragGesture)
            .onTapGesture {
                if model.phase.isSticky { controller.dismissFromUser() }
            }
            .help(model.phase.pillText)
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
            Capsule(style: .continuous)
                .strokeBorder(PillStyle.rim, lineWidth: KleothMetrics.hairline)
        )
        .overlay {
            if model.phase == .idle {
                RestingSheen(reduceMotion: reduceMotion)
                    .transition(.opacity)
            }
        }
        // Resting is quieter than active: lower opacity so it reads as an
        // indicator, not a window.
        .opacity(model.phase == .idle ? PillStyle.restingOpacity : 1)
        .shadow(color: .black.opacity(model.phase == .idle ? 0.18 : 0.28), radius: 10, y: 3)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: model.phase)
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
    }

    /// Moving the panel from a `DragGesture` has one trap: `value.translation`
    /// is measured against a coordinate space that moves with the window, so it
    /// double-counts and the pill runs away from the cursor. Screen-absolute
    /// `NSEvent.mouseLocation` deltas against the origin captured at drag start
    /// track 1:1. `minimumDistance: 3` leaves the buttons clickable.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { _ in
                let mouse = NSEvent.mouseLocation
                if dragStartMouse == nil {
                    dragStartMouse = mouse
                    dragStartOrigin = controller.panelOrigin
                }
                guard let start = dragStartMouse else { return }
                controller.moveDuringDrag(
                    to: CGPoint(
                        x: dragStartOrigin.x + (mouse.x - start.x),
                        y: dragStartOrigin.y + (mouse.y - start.y)
                    )
                )
            }
            .onEnded { _ in
                if let start = dragStartMouse {
                    let mouse = NSEvent.mouseLocation
                    controller.moveDuringDrag(
                        to: CGPoint(
                            x: dragStartOrigin.x + (mouse.x - start.x),
                            y: dragStartOrigin.y + (mouse.y - start.y)
                        )
                    )
                }
                dragStartMouse = nil
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
/// breath of a pill that is mostly off-screen. Static under Reduce Motion.
private struct RestingSheen: View {
    let reduceMotion: Bool
    @State private var breathing = false

    var body: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
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
