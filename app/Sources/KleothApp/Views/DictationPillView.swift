import SwiftUI
import AppKit
import KleothCore

/// The dictation pill: a small capsule that says what dictation is doing, shows
/// a live mic meter while listening, and can be dragged anywhere on any screen
/// (design §5.6).
///
/// It renders `DictationPillModel` and calls back into `DictationPillController`
/// for the two things a view cannot do: move the `NSPanel`, and run the pill's
/// actions.
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
        capsule
            .scaleEffect(model.isPresented ? 1 : 0.92, anchor: .center)
            .opacity(model.isPresented ? 1 : 0)
            .padding(DictationPillController.shadowPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onTapGesture {
                // A click anywhere on a failed pill dismisses it (the ✕ is the
                // discoverable affordance; the whole capsule is the target).
                if model.phase.isSticky { controller.dismissFromUser() }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(model.phase.pillText))
    }

    private var capsule: some View {
        HStack(spacing: KleothMetrics.spacingS) {
            leading

            Text(model.phase.pillText)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .fixedSize()

            if let action = model.phase.fault?.action {
                Button(action.title) { controller.perform(action) }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            if model.phase.isSticky {
                Button {
                    controller.dismissFromUser()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, KleothMetrics.spacingM)
        .padding(.vertical, KleothMetrics.spacingS)
        .kleothPillSurface()
        // The panel has `hasShadow = false`; this is the pill's only shadow and
        // it lives inside the transparent `shadowPadding` margin.
        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
    }

    @ViewBuilder
    private var leading: some View {
        if case .listening = model.phase {
            LevelMeter(level: model.level, reduceMotion: reduceMotion)
        } else if let symbol = model.phase.symbolName {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.callout)
                .foregroundStyle(tint)
        }
    }

    /// Semantic tints from the shared palette — `KleothPalette.*` are statics on
    /// an `enum`, not `Color` members, so `.successTint` shorthand would not
    /// compile here.
    private var tint: Color {
        switch model.phase {
        case .done: return KleothPalette.successTint
        case .warning: return KleothPalette.pendingTint
        case .failed: return KleothPalette.failureTint
        case .hidden, .listening, .transcribing, .polishing: return Color.accentColor
        }
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

// MARK: - Level meter

/// Five bars driven by the smoothed mic level. Under Reduce Motion the bars
/// hold a static mid-height — the pill still reads as "listening" without
/// anything moving.
private struct LevelMeter: View {
    let level: Double
    let reduceMotion: Bool

    private static let weights: [Double] = [0.55, 0.82, 1.0, 0.82, 0.55]
    private static let minHeight: CGFloat = 4
    private static let maxHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.weights.count, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: height(at: index))
            }
        }
        .frame(width: 23, height: Self.maxHeight, alignment: .center)
        .animation(reduceMotion ? nil : Animation.easeOut(duration: 0.09), value: level)
        .accessibilityHidden(true)
    }

    private func height(at index: Int) -> CGFloat {
        let span = Self.maxHeight - Self.minHeight
        guard !reduceMotion else { return Self.minHeight + span * 0.5 }
        let clamped = level.isFinite ? min(max(level, 0), 1) : 0
        let weighted = clamped * Self.weights[index]
        return Self.minHeight + span * CGFloat(weighted)
    }
}

// MARK: - Surface

private extension View {
    /// The pill's background: the same `.regularMaterial` + hairline vocabulary
    /// as the rest of the app, in a capsule.
    ///
    /// Liquid Glass is deliberately NOT used here — `KleothTheme` reserves glass
    /// for the single hero element (the record button). Making the pill glass is
    /// a one-line change in this helper if that ever changes.
    @ViewBuilder
    func kleothPillSurface() -> some View {
        self
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(KleothPalette.hairlineStroke, lineWidth: KleothMetrics.hairline)
            )
    }
}
