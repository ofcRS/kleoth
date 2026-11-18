import Testing
import Foundation
import CoreGraphics
@testable import KleothCore

/// Dragging the pill and settling its motion (2026-11-18, the user: the drag
/// was "very glitchy", the dock "collapsed and jumped" when dragged, and an
/// active pill sometimes rendered empty). Cocoa screen coordinates, y up.
@Suite struct PillDragTests {
    private let shadowPadding: CGFloat = 18
    private let bounds = CGRect(x: 0, y: 0, width: 1600, height: 975)
    /// The anchor's reference panel on the bottom edge: the longest shapes'
    /// length and the thickest text phase's height (`referenceSize`).
    private let reference = CGSize(width: 331, height: 74)
    /// The peek dock: THICKER than the reference (its 60 pt capsule + margin).
    private let dock = CGSize(width: 331, height: 96)
    /// The meeting bar: thinner than the reference.
    private let bar = CGSize(width: 296, height: 66)

    // MARK: No jump at drag start

    /// The drag places the panel with the SAME function the settled pill uses,
    /// so a press that has not moved yet leaves the panel exactly where it
    /// was — the dock used to drop 11 pt on the first drag frame, because the
    /// drag skipped the clamp that lifts a panel thicker than the reference.
    @Test func dragAtTheSettledSpotMovesNothing() {
        for edge in [PillGeometry.Edge.bottom, .top, .left, .right] {
            let ref = edge.isVertical ? CGSize(width: reference.height, height: reference.width) : reference
            for size in [dock, bar, reference] {
                let panel = edge.isVertical ? CGSize(width: size.height, height: size.width) : size
                let along: CGFloat = edge.isVertical ? 400 : 700
                let settled = PillGeometry.dockedOrigin(
                    edge: edge, along: along, panelSize: panel, referenceSize: ref,
                    shadowPadding: shadowPadding, in: bounds
                )
                let frame = CGRect(origin: settled, size: panel)
                // The press: anywhere on the panel; the grab is measured
                // against its centre, along the edge.
                let pointer = CGPoint(x: frame.midX + 23, y: frame.midY - 9)
                let grab = PillGeometry.grabOffset(pointer: pointer, panelCenter: CGPoint(x: frame.midX, y: frame.midY), edge: edge)
                let dragged = PillGeometry.dockedOrigin(
                    edge: edge, along: PillGeometry.dragAlong(pointer: pointer, grabOffset: grab, edge: edge),
                    panelSize: panel, referenceSize: ref, shadowPadding: shadowPadding, in: bounds
                )
                #expect(dragged == settled, "edge \(edge) panel \(panel)")
            }
        }
    }

    /// The dock is lifted off the edge by the clamp exactly as when it peeks:
    /// its near side `edgeMargin` in, never cut by the screen edge.
    @Test func aPanelThickerThanTheReferenceIsClampedInward() {
        let origin = PillGeometry.dockedOrigin(
            edge: .bottom, along: 800, panelSize: dock, referenceSize: reference,
            shadowPadding: shadowPadding, in: bounds
        )
        #expect(origin.y == bounds.minY + PillGeometry.edgeMargin)
        #expect(origin.x == 800 - dock.width / 2)
        // A thinner bar is centred on the anchor, not clamped.
        let barOrigin = PillGeometry.dockedOrigin(
            edge: .bottom, along: 800, panelSize: bar, referenceSize: reference,
            shadowPadding: shadowPadding, in: bounds
        )
        let anchor = PillGeometry.dockedCenter(edge: .bottom, along: 800, panelSize: reference, shadowPadding: shadowPadding, in: bounds)
        #expect(barOrigin.y + bar.height / 2 == anchor.y)
    }

    /// The pill follows the pointer 1:1 along its edge with the grab kept: the
    /// point that was grabbed stays under the cursor.
    @Test func theGrabbedPointStaysUnderThePointer() {
        let start = PillGeometry.dockedOrigin(
            edge: .bottom, along: 700, panelSize: bar, referenceSize: reference,
            shadowPadding: shadowPadding, in: bounds
        )
        let frame = CGRect(origin: start, size: bar)
        let press = CGPoint(x: frame.minX + 40, y: frame.midY)
        let grab = PillGeometry.grabOffset(pointer: press, panelCenter: CGPoint(x: frame.midX, y: frame.midY), edge: .bottom)
        #expect(grab == 40 - bar.width / 2)
        for dx: CGFloat in [-200, -13, 0, 9, 250] {
            // Orthogonal motion is ignored: the pill stays docked.
            let pointer = CGPoint(x: press.x + dx, y: press.y + 70)
            let origin = PillGeometry.dockedOrigin(
                edge: .bottom, along: PillGeometry.dragAlong(pointer: pointer, grabOffset: grab, edge: .bottom),
                panelSize: bar, referenceSize: reference, shadowPadding: shadowPadding, in: bounds
            )
            #expect(origin.x == start.x + dx)
            #expect(origin.y == start.y)
        }
        // Side edges slide along y.
        #expect(PillGeometry.grabOffset(pointer: CGPoint(x: 5, y: 130), panelCenter: CGPoint(x: 40, y: 100), edge: .left) == 30)
        #expect(PillGeometry.dragAlong(pointer: CGPoint(x: 900, y: 300), grabOffset: 30, edge: .right) == 270)
    }

    // MARK: Click or drag

    /// A press becomes a drag only past the threshold, in any direction; a
    /// hand that drifts a few points while clicking still clicks.
    @Test func aPressBecomesADragOnlyPastTheThreshold() {
        #expect(!PillGeometry.isDrag(translation: .zero))
        #expect(!PillGeometry.isDrag(translation: CGSize(width: 3, height: -4)))   // 5 pt
        #expect(PillGeometry.isDrag(translation: CGSize(width: 0, height: PillGeometry.dragThreshold)))
        #expect(PillGeometry.isDrag(translation: CGSize(width: -5, height: 5)))      // 7.1 pt
        #expect(!PillGeometry.isDrag(translation: CGSize(width: CGFloat.nan, height: 40)))
    }

    // MARK: Settling

    /// The panel settles once the LAST beat of a transition has ended — from
    /// the durations, never from SwiftUI's completion callback, which did not
    /// fire for a rise or a sink (the panel then stayed a stage for the whole
    /// meeting, and the dock's surface stayed under the bar).
    @Test func settleWaitsForTheLastBeat() {
        let move = PillMotion.moveDuration, shape = PillMotion.shapeDuration
        // Rise: move and shape together.
        #expect(PillMotion.settleDelay(moves: true, reshapes: true, staggeredMove: false, peek: false) == max(move, shape))
        // Sink: shape first, the move a stagger later.
        #expect(PillMotion.settleDelay(moves: true, reshapes: true, staggeredMove: true, peek: false) == PillMotion.stagger + move)
        // Morph in place.
        #expect(PillMotion.settleDelay(moves: false, reshapes: true, staggeredMove: false, peek: false) == shape)
        // A peek: the quick hop, but never before the shape spring is done.
        #expect(PillMotion.settleDelay(moves: true, reshapes: true, staggeredMove: false, peek: true) == max(PillMotion.peekDuration, shape))
        #expect(PillMotion.settleDelay(moves: true, reshapes: false, staggeredMove: false, peek: true) == PillMotion.peekDuration)
        // Nothing to animate: settle now.
        #expect(PillMotion.settleDelay(moves: false, reshapes: false, staggeredMove: false, peek: false) == 0)
        // Every answer covers every beat it runs.
        for moves in [false, true] {
            for reshapes in [false, true] {
                for staggered in [false, true] {
                    for peek in [false, true] {
                        let delay = PillMotion.settleDelay(moves: moves, reshapes: reshapes, staggeredMove: staggered, peek: peek)
                        if reshapes { #expect(delay >= shape) }
                        if moves { #expect(delay >= (peek ? PillMotion.peekDuration : move)) }
                    }
                }
            }
        }
    }
}
