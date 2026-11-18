import Testing
import Foundation
import CoreGraphics
@testable import KleothCore

/// The pill's press, drag hold and transition bookkeeping (review of PR #32):
/// the decisions the controller makes about a press and about what a drag
/// holds, pure. Cocoa screen coordinates, y up.
@Suite struct PillPressTests {

    // MARK: Click or drag, in SCREEN space

    /// A press is a click until the pointer has travelled the threshold ON
    /// SCREEN — a capsule growing under a still pointer (the dock opening)
    /// moves nothing, so the release still clicks.
    @Test func aStillPointerStaysAClickWhateverTheCapsuleDoes() {
        var press = PillPress(at: CGPoint(x: 500, y: 40))
        let r1 = press.move(to: CGPoint(x: 501, y: 40))
        #expect(!r1)   // 1 pt of jitter
        let r2 = press.move(to: CGPoint(x: 503, y: 44))
        #expect(!r2)   // 5 pt
        #expect(press.isClick)
        #expect(!press.dragged)
    }

    /// Past the threshold the press becomes a drag exactly once, and a press
    /// that became a drag is never a click again — not even when its drop was
    /// made elsewhere and the release comes back to where it started.
    @Test func aDragIsNeverAClick() {
        var press = PillPress(at: CGPoint(x: 500, y: 40))
        let r3 = press.move(to: CGPoint(x: 507, y: 40))
        #expect(r3)    // becomes a drag: once
        let r4 = press.move(to: CGPoint(x: 700, y: 40))
        #expect(!r4)   // already one
        let r5 = press.move(to: CGPoint(x: 500, y: 40))
        #expect(!r5)   // back home
        #expect(press.dragged)
        #expect(!press.isClick)
    }

    @Test func aBadPointerNeverStartsADrag() {
        var press = PillPress(at: CGPoint(x: 500, y: 40))
        let r6 = press.move(to: CGPoint(x: CGFloat.nan, y: 40))
        #expect(!r6)
        #expect(press.isClick)
    }

    // MARK: Which field: the settled capsule, along its own axis

    /// The pointer's offset along the capsule from its centre, in the
    /// capsule's own (un-rotated) axis — the dock's fields run along it. The
    /// same mapping as the hover lift: on the right edge the capsule is turned
    /// +90° (its start at the top), on the left −90° (its start at the bottom).
    @Test func alongTheCapsuleOnEveryEdge() {
        let center = CGPoint(x: 400, y: 300)
        let pointer = CGPoint(x: 430, y: 250)
        #expect(PillGeometry.alongCapsule(pointer: pointer, capsuleCenter: center, edge: .bottom, flat: false) == 30)
        #expect(PillGeometry.alongCapsule(pointer: pointer, capsuleCenter: center, edge: .top, flat: false) == 30)
        #expect(PillGeometry.alongCapsule(pointer: pointer, capsuleCenter: center, edge: .right, flat: false) == 50)
        #expect(PillGeometry.alongCapsule(pointer: pointer, capsuleCenter: center, edge: .left, flat: false) == -50)
        // A flat bar is never turned.
        #expect(PillGeometry.alongCapsule(pointer: pointer, capsuleCenter: center, edge: .right, flat: true) == 30)
        // Through the dock's mapping: the first field is the one nearest the start.
        let pitch: CGFloat = 65
        let top = CGPoint(x: 400, y: 300 + 1.5 * pitch)   // on the right edge the start is at the top
        #expect(PillGeometry.dockFieldIndex(
            along: PillGeometry.alongCapsule(pointer: top, capsuleCenter: center, edge: .right, flat: false),
            pitch: pitch, count: 4
        ) == 0)
    }

    // MARK: What a drag holds

    /// While the pill is dragged a request is held for the drop and the latest
    /// one wins, as it would have with no drag.
    @Test func theLatestHeldRequestWins() {
        var hold = PillDragHold<String>()
        let r7 = hold.receive(.show("saved"), hot: false)
        #expect(r7 == .hold)
        let r8 = hold.receive(.hide, hot: false)
        #expect(r8 == .hold)
        #expect(hold.heldPhase(hidden: "hidden") == "hidden")
        let r9 = hold.receive(.show("done"), hot: false)
        #expect(r9 == .hold)
        #expect(hold.heldPhase(hidden: "hidden") == "done")
        let r10 = hold.drop()
        #expect(r10 == .show("done"))
        let r11 = hold.drop()
        #expect(r11 == nil)   // once
        #expect(hold.heldPhase(hidden: "hidden") == nil)
    }

    /// A capture going hot is never held (a microphone that is live has its
    /// indicator): it applies at once, and replaces anything older that was
    /// held — the hot request is the newer one.
    @Test func aHotCaptureIsNeverHeld() {
        var hold = PillDragHold<String>()
        let r12 = hold.receive(.show("saved"), hot: false)
        #expect(r12 == .hold)
        let r13 = hold.receive(.show("meeting"), hot: true)
        #expect(r13 == .applyNow)
        let r14 = hold.drop()
        #expect(r14 == nil)
        // A held request after it is held again.
        let r15 = hold.receive(.show("meetingSaved"), hot: false)
        #expect(r15 == .hold)
        let r16 = hold.drop()
        #expect(r16 == .show("meetingSaved"))
    }

    // MARK: Transitions: a pending shape lands, never vanishes

    /// A settle in the turn between a transition and its own callout lands
    /// the transition's shape at once (it used to drop it: the panel was sized
    /// for the new phase around the old one — an empty pill).
    @Test func aSettleLandsThePendingShape() {
        var ledger = PillTransitionLedger<String>()
        let first = ledger.begin("listening")
        #expect(ledger.pending == "listening")
        let r17 = ledger.settle()
        #expect(r17 == "listening")
        #expect(ledger.pending == nil)
        // The transition's own turn then finds it superseded: nothing to apply.
        let r18 = ledger.take(first)
        #expect(!r18)
        // Nothing pending: a settle lands nothing.
        let r19 = ledger.settle()
        #expect(r19 == nil)
    }

    /// A later transition supersedes an earlier one; only the latest lands,
    /// once; a hide forgets the pending shape.
    @Test func onlyTheLatestTransitionLands() {
        var ledger = PillTransitionLedger<String>()
        let first = ledger.begin("prompt")
        let second = ledger.begin("idle")
        #expect(!ledger.isCurrent(first))
        #expect(ledger.isCurrent(second))
        let r20 = ledger.take(first)
        #expect(!r20)
        let r21 = ledger.take(second)
        #expect(r21)
        #expect(ledger.pending == nil)
        let r22 = ledger.take(second)
        #expect(!r22)   // once
        #expect(ledger.isCurrent(second))   // its settle timer still counts
        let third = ledger.begin("meeting")
        ledger.cancel()
        #expect(ledger.pending == nil)
        #expect(!ledger.isCurrent(third))
    }
}
