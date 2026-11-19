import CoreGraphics
import Foundation

/// Where the user parked the dictation pill, stored as *fractions* of the
/// screen's `visibleFrame` rather than absolute points so the pill lands in the
/// same visual spot when a display's resolution, scaling, or menu-bar/Dock
/// insets change.
///
/// Persisted as JSON in `UserDefaults` under
/// `DictationPillController.placementDefaultsKey`
/// (`dev.kleoth.dictation.pillPlacement`). Restoring resolves the display by
/// `displayId` (`NSScreenNumber`) first, then by name + `visibleFrame` size, and
/// falls back to `PillGeometry.defaultOrigin` on the screen under the mouse.
///
/// Naming note: `displayId`, not `displayID` — the project's snake_case
/// round-trip rule bans all-caps acronym suffixes on stored keys.
public struct PillPlacement: Codable, Equatable, Sendable {
    /// `NSScreenNumber` of the display the pill was dropped on.
    public var displayId: UInt32
    /// `NSScreen.localizedName`, used to re-find a display whose id changed
    /// (replug, different port).
    public var displayName: String
    /// The `visibleFrame` size the fractions were measured against.
    public var visibleWidth: Double
    public var visibleHeight: Double
    /// Panel center as a fraction of `visibleFrame` width (0 = left edge).
    public var relativeCenterX: Double
    /// Panel center as a fraction of `visibleFrame` height, **0 = bottom**
    /// (Cocoa's y-up screen coordinates).
    public var relativeCenterY: Double
    /// The screen edge the pill is docked on. Only the fraction ALONG that
    /// edge matters for placement (the other one is derived from the edge —
    /// `PillGeometry.dockedCenter`); both are kept so a blob written before
    /// docking existed (nil edge) still restores by nearest edge.
    public var edge: PillGeometry.Edge?

    public init(
        displayId: UInt32,
        displayName: String,
        visibleWidth: Double,
        visibleHeight: Double,
        relativeCenterX: Double,
        relativeCenterY: Double,
        edge: PillGeometry.Edge? = nil
    ) {
        self.displayId = displayId
        self.displayName = displayName
        self.visibleWidth = visibleWidth
        self.visibleHeight = visibleHeight
        self.relativeCenterX = relativeCenterX
        self.relativeCenterY = relativeCenterY
        self.edge = edge
    }
}

/// Pure placement + level math for the dictation pill.
///
/// This lives in `KleothCore` — not in the app target — for one reason: the app
/// package has no test target, so every decision the pill makes that can be
/// checked without a screen belongs here (same rationale as
/// `DictationChordMachine` and `PasteboardPolicy`). All coordinates are Cocoa
/// screen coordinates: y grows **upward**, `origin` is the panel's bottom-left
/// corner, and `panelSize` is the whole `NSPanel` — including the transparent
/// shadow margin the SwiftUI capsule draws inside.
public enum PillGeometry {
    /// Minimum gap between the panel rect and the edge of the bounds. The
    /// visible capsule sits a further `shadowPadding` inside that.
    public static let edgeMargin: CGFloat = 8
    /// Default distance from the bottom of the screen to the bottom of the
    /// *capsule* (not the panel) when the pill is active. Small on purpose: the
    /// pill lives at the very bottom edge, over the Dock if there is one (the
    /// reference bar does the same), and rises here out of its tucked resting
    /// spot. Equals `edgeMargin` + the app's 18 pt shadow padding — the closest
    /// `clamp` lets the capsule sit to the edge.
    public static let defaultBottomInset: CGFloat = 26

    /// The screen edge the pill is docked on. Stored in `PillPlacement` by its
    /// raw value (acronym-free, per the stored-key rule).
    public enum Edge: String, Codable, Equatable, Sendable {
        case bottom, top, left, right

        /// Left/right: the pill stands vertically and slides along y.
        public var isVertical: Bool { self == .left || self == .right }
    }
    /// How much closer (in points) the pointer must be to another edge than
    /// to the current one before a drag re-docks the pill there. Without
    /// this a drag along the bottom would flip to a side edge the moment the
    /// pointer crossed the corner diagonal and flip back a pixel later.
    public static let redockHysteresis: CGFloat = 48
    /// Meter shaping exponent. > 1 so room tone near the −55 dBFS floor stays
    /// visually quiet and speech still swings the bars.
    public static let levelGamma: Double = 1.4

    // MARK: Bounds

    /// The area the *active* pill may occupy: the whole screen minus the menu
    /// bar. Deliberately NOT `visibleFrame`, which also excludes the Dock — the
    /// pill sits at the very bottom edge of the display, over the Dock, so it
    /// can rise straight out of its tucked resting spot. A `visibleFrame` that
    /// does not fit inside `screenFrame` (garbage) falls back to the full screen.
    public static func bounds(screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        guard screenFrame.width.isFinite, screenFrame.height.isFinite else { return screenFrame }
        var top = visibleFrame.maxY
        if !top.isFinite || top <= screenFrame.minY || top > screenFrame.maxY {
            top = screenFrame.maxY
        }
        return CGRect(
            x: screenFrame.minX, y: screenFrame.minY,
            width: screenFrame.width, height: top - screenFrame.minY
        )
    }

    // MARK: Resting

    /// The screen edge closest to the center of a panel at `origin`. Ties go
    /// to the bottom — the default home.
    public static func nearestEdge(
        ofPanelAt origin: CGPoint, panelSize: CGSize, in screenFrame: CGRect
    ) -> Edge {
        let center = CGPoint(x: origin.x + panelSize.width / 2, y: origin.y + panelSize.height / 2)
        let distances: [(Edge, CGFloat)] = [
            (.bottom, abs(center.y - screenFrame.minY)),
            (.top, abs(screenFrame.maxY - center.y)),
            (.left, abs(center.x - screenFrame.minX)),
            (.right, abs(screenFrame.maxX - center.x)),
        ]
        var best = distances[0]
        for candidate in distances.dropFirst() where candidate.1.isFinite && candidate.1 < best.1 {
            best = candidate
        }
        return best.0
    }

    /// Distance from `point` to `edge` of `frame` (negative once past it).
    public static func distance(from point: CGPoint, to edge: Edge, in frame: CGRect) -> CGFloat {
        switch edge {
        case .bottom: return point.y - frame.minY
        case .top: return frame.maxY - point.y
        case .left: return point.x - frame.minX
        case .right: return frame.maxX - point.x
        }
    }

    /// The edge a drag should dock on: stays on `current` unless the pointer
    /// is at least `redockHysteresis` closer to another edge.
    public static func dragEdge(current: Edge, pointer: CGPoint, in frame: CGRect) -> Edge {
        let candidate = nearestEdge(ofPanelAt: pointer, panelSize: .zero, in: frame)
        guard candidate != current else { return current }
        let currentDistance = distance(from: pointer, to: current, in: frame)
        let candidateDistance = distance(from: pointer, to: candidate, in: frame)
        guard currentDistance.isFinite, candidateDistance.isFinite else { return current }
        return candidateDistance + redockHysteresis < currentDistance ? candidate : current
    }

    // MARK: Docking

    /// The center of a panel docked on `edge` of `bounds`: its capsule sits
    /// `defaultBottomInset` in from that edge (`shadowPadding` is the panel's
    /// transparent margin around the capsule) and its center lies at `along`
    /// on the edge's axis — x for bottom/top, y for the sides — clamped so the
    /// whole panel stays inside `bounds` with `edgeMargin` to spare. This is
    /// the one degree of freedom a drag has.
    public static func dockedCenter(
        edge: Edge, along: CGFloat, panelSize: CGSize, shadowPadding: CGFloat, in bounds: CGRect
    ) -> CGPoint {
        let inset = defaultBottomInset - shadowPadding
        switch edge {
        case .bottom, .top:
            let y = edge == .bottom
                ? bounds.minY + inset + panelSize.height / 2
                : bounds.maxY - inset - panelSize.height / 2
            let x = pin(along, lower: bounds.minX + edgeMargin + panelSize.width / 2,
                        upper: bounds.maxX - edgeMargin - panelSize.width / 2)
            return CGPoint(x: x, y: y)
        case .left, .right:
            let x = edge == .left
                ? bounds.minX + inset + panelSize.width / 2
                : bounds.maxX - inset - panelSize.width / 2
            let y = pin(along, lower: bounds.minY + edgeMargin + panelSize.height / 2,
                        upper: bounds.maxY - edgeMargin - panelSize.height / 2)
            return CGPoint(x: x, y: y)
        }
    }

    /// The origin of a panel docked on `edge` at `along`: centred on the
    /// anchor (`dockedCenter` resolved against `referenceSize`, the one size
    /// every phase shares so a pill near a corner never creeps), then clamped
    /// into `bounds` with its OWN size — which lifts a panel thicker than the
    /// reference (the peek dock) off the edge. The settled pill and a drag both
    /// place the panel with this, so a press that has not moved yet moves
    /// nothing (the drag used to skip the clamp: the dock dropped 11 pt).
    public static func dockedOrigin(
        edge: Edge, along: CGFloat, panelSize: CGSize, referenceSize: CGSize, shadowPadding: CGFloat, in bounds: CGRect
    ) -> CGPoint {
        let center = dockedCenter(
            edge: edge, along: along, panelSize: referenceSize, shadowPadding: shadowPadding, in: bounds
        )
        let origin = CGPoint(x: center.x - panelSize.width / 2, y: center.y - panelSize.height / 2)
        return clamp(origin, panelSize: panelSize, in: bounds)
    }

    // MARK: Drag

    /// How far (points) a press on the pill must travel before it is a drag.
    /// Below it the press is a click — a hand that drifts while clicking Stop
    /// must stop the recording, not move the pill.
    public static let dragThreshold: CGFloat = 6

    /// Whether a press that has moved by `translation` is a drag. A
    /// non-finite translation is not.
    public static func isDrag(translation: CGSize) -> Bool {
        let distance = (translation.width * translation.width + translation.height * translation.height).squareRoot()
        return distance.isFinite && distance >= dragThreshold
    }

    /// Where along `edge` the pointer grabbed a panel centred at
    /// `panelCenter`: its offset from that centre on the edge's axis (x on
    /// bottom/top, y on the sides). Kept for the whole drag, so the grabbed
    /// point stays under the cursor instead of the centre snapping to it.
    public static func grabOffset(pointer: CGPoint, panelCenter: CGPoint, edge: Edge) -> CGFloat {
        edge.isVertical ? pointer.y - panelCenter.y : pointer.x - panelCenter.x
    }

    /// The along-axis coordinate a drag puts the panel's centre at: the
    /// pointer's, minus the grab.
    public static func dragAlong(pointer: CGPoint, grabOffset: CGFloat, edge: Edge) -> CGFloat {
        (edge.isVertical ? pointer.y : pointer.x) - grabOffset
    }

    /// A screen pointer's offset from a capsule's centre along the capsule's
    /// OWN axis (the one the dock's fields run along, negative toward its
    /// start). On a side edge an upright capsule is turned — +90° on the
    /// right (its start at the top), −90° on the left (its start at the
    /// bottom); a `flat` one never is. The hover lift's mapping
    /// (`DictationPillModel.capsulePointer`), from screen coordinates.
    public static func alongCapsule(pointer: CGPoint, capsuleCenter: CGPoint, edge: Edge, flat: Bool) -> CGFloat {
        guard !flat else { return pointer.x - capsuleCenter.x }
        switch edge {
        case .bottom, .top: return pointer.x - capsuleCenter.x
        case .right: return capsuleCenter.y - pointer.y
        case .left: return pointer.y - capsuleCenter.y
        }
    }

    /// The along-axis coordinate a saved placement encodes for `edge`.
    public static func along(for placement: PillPlacement, edge: Edge, in bounds: CGRect) -> CGFloat {
        edge.isVertical
            ? bounds.minY + CGFloat(sanitizedFraction(placement.relativeCenterY)) * bounds.height
            : bounds.minX + CGFloat(sanitizedFraction(placement.relativeCenterX)) * bounds.width
    }

    /// Where the pill rests between dictations: the *active* panel rect slid
    /// into the nearest screen edge until its center sits exactly on that
    /// edge. The capsule is centered in the panel, so exactly half of it stays
    /// on screen — a small tab peeking in from the border, like the reference
    /// bar. The other coordinate is untouched, so the pill rises (or slides)
    /// straight back to `activeOrigin` when a dictation starts.
    public static func restingOrigin(
        activeOrigin: CGPoint, panelSize: CGSize, in screenFrame: CGRect
    ) -> CGPoint {
        restingOrigin(
            activeOrigin: activeOrigin, panelSize: panelSize,
            edge: nearestEdge(ofPanelAt: activeOrigin, panelSize: panelSize, in: screenFrame),
            in: screenFrame
        )
    }

    /// `restingOrigin` for a caller that has already picked the edge — the
    /// controller does, because a side edge swaps the panel's width and height
    /// (the tab stands vertically) and the edge must not flip with the size.
    public static func restingOrigin(
        activeOrigin: CGPoint, panelSize: CGSize, edge: Edge, in screenFrame: CGRect
    ) -> CGPoint {
        var origin = activeOrigin
        switch edge {
        case .bottom: origin.y = screenFrame.minY - panelSize.height / 2
        case .top: origin.y = screenFrame.maxY - panelSize.height / 2
        case .left: origin.x = screenFrame.minX - panelSize.width / 2
        case .right: origin.x = screenFrame.maxX - panelSize.width / 2
        }
        return origin
    }

    // MARK: Placement

    /// Bottom-center of `visibleFrame`, with the capsule's bottom edge
    /// `defaultBottomInset` above the bottom of the bounds.
    /// `shadowPadding` is the transparent margin the panel carries around the
    /// capsule, so it is subtracted from the y inset.
    public static func defaultOrigin(
        panelSize: CGSize,
        shadowPadding: CGFloat,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let x = visibleFrame.midX - panelSize.width / 2
        let y = visibleFrame.minY + defaultBottomInset - shadowPadding
        return clamp(CGPoint(x: x, y: y), panelSize: panelSize, in: visibleFrame)
    }

    /// Resolves a saved placement against the *current* `visibleFrame`. Corrupt
    /// or out-of-range fractions can never push the pill off-screen: the result
    /// is always clamped.
    public static func origin(
        for placement: PillPlacement,
        panelSize: CGSize,
        in visibleFrame: CGRect
    ) -> CGPoint {
        let fractionX = sanitizedFraction(placement.relativeCenterX)
        let fractionY = sanitizedFraction(placement.relativeCenterY)
        let centerX = visibleFrame.minX + CGFloat(fractionX) * visibleFrame.width
        let centerY = visibleFrame.minY + CGFloat(fractionY) * visibleFrame.height
        let origin = CGPoint(x: centerX - panelSize.width / 2, y: centerY - panelSize.height / 2)
        return clamp(origin, panelSize: panelSize, in: visibleFrame)
    }

    /// Captures the panel's current position as screen-relative fractions.
    /// Round-trips with `origin(for:panelSize:in:)` for any origin already
    /// inside the clamp bounds.
    public static func placement(
        origin: CGPoint,
        panelSize: CGSize,
        in visibleFrame: CGRect,
        displayId: UInt32,
        displayName: String
    ) -> PillPlacement {
        let width = visibleFrame.width > 0 ? visibleFrame.width : 1
        let height = visibleFrame.height > 0 ? visibleFrame.height : 1
        let centerX = origin.x + panelSize.width / 2
        let centerY = origin.y + panelSize.height / 2
        return PillPlacement(
            displayId: displayId,
            displayName: displayName,
            visibleWidth: Double(visibleFrame.width),
            visibleHeight: Double(visibleFrame.height),
            relativeCenterX: Double((centerX - visibleFrame.minX) / width),
            relativeCenterY: Double((centerY - visibleFrame.minY) / height)
        )
    }

    /// Smallest panel width the cap will ever return, so a pathological
    /// `visibleFrame` cannot collapse the pill to nothing.
    public static let minPanelWidth: CGFloat = 120

    /// The widest a panel may be on a screen: `visibleFrame` minus the edge
    /// margin on both sides. The controller caps the measured width here so an
    /// unbounded message (a raw API error body) truncates inside the capsule
    /// instead of pushing the pill's ✕ off the right edge — without this,
    /// `clamp` degenerates to its `return lower` branch and the panel is
    /// pinned at the left edge running off-screen.
    public static func maxPanelWidth(in visibleFrame: CGRect) -> CGFloat {
        guard visibleFrame.width.isFinite else { return minPanelWidth }
        return max(minPanelWidth, visibleFrame.width - 2 * edgeMargin)
    }

    /// `min(width, maxPanelWidth(in:))`, never below `minPanelWidth`.
    public static func cappedPanelWidth(_ width: CGFloat, in visibleFrame: CGRect) -> CGFloat {
        guard width.isFinite else { return minPanelWidth }
        return max(minPanelWidth, min(width, maxPanelWidth(in: visibleFrame)))
    }

    /// Keeps the whole panel inside `visibleFrame` with `edgeMargin` to spare.
    /// Idempotent; when the panel is larger than the available area it pins to
    /// the lower-left bound rather than producing an inverted range.
    public static func clamp(_ origin: CGPoint, panelSize: CGSize, in visibleFrame: CGRect) -> CGPoint {
        let lowerX = visibleFrame.minX + edgeMargin
        let upperX = visibleFrame.maxX - edgeMargin - panelSize.width
        let lowerY = visibleFrame.minY + edgeMargin
        let upperY = visibleFrame.maxY - edgeMargin - panelSize.height
        return CGPoint(
            x: pin(origin.x, lower: lowerX, upper: upperX),
            y: pin(origin.y, lower: lowerY, upper: upperY)
        )
    }

    // MARK: Peek dock

    /// The field of a `count`-field peek dock under a pointer `along` points
    /// from the capsule's centre (fields `pitch` apart, centred on the
    /// capsule), clamped to `0..<count`. Shared by `PeekDock`'s hit test and
    /// the sandbox's film pointer, so the two can never disagree. A zero or
    /// negative pitch, a non-finite pointer or an empty dock → field 0.
    public static func dockFieldIndex(along: CGFloat, pitch: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard pitch.isFinite, pitch > 0, along.isFinite else { return 0 }
        let raw = (along / pitch + CGFloat(count - 1) / 2).rounded()
        guard raw.isFinite else { return 0 }
        // Clamp BEFORE `Int(_:)`: a finite but huge ratio (a tiny pitch) would trap.
        return Int(min(max(raw, 0), CGFloat(count - 1)))
    }

    /// The centre offset of field `index` — the inverse of `dockFieldIndex`,
    /// for the sandbox. Index clamped to `0..<count`; bad pitch → 0.
    public static func dockFieldCenter(index: Int, pitch: CGFloat, count: Int) -> CGFloat {
        guard count > 0, pitch.isFinite, pitch > 0 else { return 0 }
        let clamped = min(max(index, 0), count - 1)
        return (CGFloat(clamped) - CGFloat(count - 1) / 2) * pitch
    }

    // MARK: Level

    /// RMS amplitude (0…1) → meter level (0…1). Below `floorDecibels` the meter
    /// reads 0; full scale reads 1. Never returns NaN, even for a NaN/negative
    /// sample (silence is the safe answer for a UI meter).
    public static func normalizedLevel(rms: Float, floorDecibels: Double = -55) -> Double {
        let amplitude = Double(rms)
        guard amplitude.isFinite, amplitude > 0 else { return 0 }
        let floor = (floorDecibels.isFinite && floorDecibels < 0) ? floorDecibels : -55
        let decibels = 20 * log10(min(amplitude, 1))
        guard decibels.isFinite, decibels > floor else { return 0 }
        let linear = (decibels - floor) / (0 - floor)
        let shaped = pow(min(max(linear, 0), 1), levelGamma)
        guard shaped.isFinite else { return 0 }
        return min(max(shaped, 0), 1)
    }

    /// One-pole smoother for the 20 Hz level poll: jumps toward a louder target
    /// (`attack`) and eases back from a quieter one (`release`), so the bars
    /// feel responsive without flickering. Never returns NaN.
    public static func smoothLevel(
        previous: Double,
        target: Double,
        attack: Double = 0.6,
        release: Double = 0.25
    ) -> Double {
        let start = clampUnit(previous)
        let goal = clampUnit(target)
        let rawCoefficient = goal > start ? attack : release
        let coefficient = clampUnit(rawCoefficient)
        return clampUnit(start + (goal - start) * coefficient)
    }

    // MARK: Helpers

    private static func pin(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return lower }
        guard upper > lower else { return lower }
        return min(max(value, lower), upper)
    }

    private static func sanitizedFraction(_ value: Double) -> Double {
        // A non-finite fraction (a hand-edited or truncated defaults blob)
        // becomes "centered"; out-of-range values survive here and are handled
        // by the clamp, which is the single place edges are enforced.
        value.isFinite ? value : 0.5
    }

    private static func clampUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// One press on the pill, measured on SCREEN: a click until the pointer has
/// travelled `PillGeometry.dragThreshold` from where it went down, then a
/// drag for good. Not the gesture's own translation, which is measured in
/// the capsule's space: it moves with the window during a drag and grows
/// under a still pointer while the capsule animates (a press on the opening
/// dock was no click).
public struct PillPress: Equatable, Sendable {
    public let start: CGPoint
    /// The press became a drag (and stays one, however its drop came about).
    public private(set) var dragged = false

    public init(at start: CGPoint) {
        self.start = start
    }

    /// Feeds the pointer's screen position; true exactly once — when this
    /// press becomes a drag.
    public mutating func move(to point: CGPoint) -> Bool {
        guard !dragged else { return false }
        let travel = CGSize(width: point.x - start.x, height: point.y - start.y)
        guard PillGeometry.isDrag(translation: travel) else { return false }
        dragged = true
        return true
    }

    /// Whether the release is a click: never once the press became a drag.
    public var isClick: Bool { !dragged }
}

/// What a drag does with the requests that reach the pill while it is
/// carried (`DictationPillController.isDragging`): it HOLDS them for the drop,
/// the latest winning as it would with no drag — except a capture going hot,
/// which applies at once (a live microphone always has its indicator) and,
/// being the newest request, replaces anything held before it.
public struct PillDragHold<Phase: Equatable>: Equatable {
    public enum Request: Equatable {
        case show(Phase)
        case hide
    }

    public enum Decision: Equatable {
        case hold
        case applyNow
    }

    public private(set) var held: Request?

    public init() {}

    public mutating func receive(_ request: Request, hot: Bool) -> Decision {
        if hot {
            held = nil
            return .applyNow
        }
        held = request
        return .hold
    }

    /// The held request, once, at the drop.
    public mutating func drop() -> Request? {
        defer { held = nil }
        return held
    }

    /// The phase the drop will bring (`hidden` for a held hide), or nil.
    public func heldPhase(hidden: Phase) -> Phase? {
        switch held {
        case .show(let phase): return phase
        case .hide: return hidden
        case nil: return nil
        }
    }
}

/// The pill's transitions in flight: each one is a generation, and its shape
/// (phase, size, flatness) is PENDING from the moment it is asked for until
/// its own callout applies it — or until a settle lands it at once. A later
/// transition, a settle or a hide make the earlier generation stale, so its
/// callout and its settle timer do nothing. A settle never drops the pending
/// shape (it did: a drag starting in that turn left the new phase unapplied).
public struct PillTransitionLedger<Shape> {
    public private(set) var generation = 0
    public private(set) var pending: Shape?

    public init() {}

    /// A new transition: supersedes any in flight. Returns its generation.
    public mutating func begin(_ shape: Shape) -> Int {
        generation += 1
        pending = shape
        return generation
    }

    /// Whether `generation` is still the transition in flight.
    public func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /// The transition's own callout: true when it is still current and its
    /// shape still pending — the caller applies it now (it is no longer pending).
    public mutating func take(_ generation: Int) -> Bool {
        guard isCurrent(generation), pending != nil else { return false }
        pending = nil
        return true
    }

    /// Ends whatever is in flight NOW: a new generation (stale callouts and
    /// timers), and the shape still pending, which the caller applies at once.
    public mutating func settle() -> Shape? {
        generation += 1
        defer { pending = nil }
        return pending
    }

    /// Ends whatever is in flight and forgets its shape (a hide; a jump that
    /// applies its own shape directly).
    public mutating func cancel() {
        generation += 1
        pending = nil
    }
}

/// The pill's motion timing (`DictationPillController`): a transition moves
/// the capsule on one spring and reshapes it on another, and the panel
/// SETTLES (shrinks back to the capsule, offset zero) once the last of them
/// has ended. The controller builds its springs from these durations, so the
/// settle can never come before a beat it waits for.
public enum PillMotion {
    /// The move spring (a rise out of the edge, a sink, a slide).
    public static let moveDuration: TimeInterval = 0.34
    /// The shape spring (size, phase, the tumble between upright and flat).
    public static let shapeDuration: TimeInterval = 0.3
    /// A peek: the short hop of the resting pill under the pointer.
    public static let peekDuration: TimeInterval = 0.22
    /// The beat between the two springs when one waits for the other (a sink
    /// shrinks first, then slides into the edge).
    public static let stagger: TimeInterval = 0.06

    /// How long after a transition starts the panel may settle: the end of
    /// its last beat. `staggeredMove` = the move starts a `stagger` late; a
    /// `peek` moves on the peek spring (never staggered). Zero when nothing
    /// animates.
    ///
    /// A timer, not SwiftUI's `withAnimation(completion:)`: on the pill that
    /// callback did not fire for a move and a reshape started in the same
    /// turn (every rise and sink), so the panel stayed a stage — and the
    /// dock's surface stayed held — until the next morph.
    public static func settleDelay(moves: Bool, reshapes: Bool, staggeredMove: Bool, peek: Bool) -> TimeInterval {
        let moveEnd = peek ? peekDuration : (staggeredMove ? stagger : 0) + moveDuration
        return max(moves ? moveEnd : 0, reshapes ? shapeDuration : 0)
    }
}

// MARK: - Motion beats

/// The cue a pill transition plays (`DictationPillController.transition`):
/// the view's squash-and-stretch and its content reveal both key off it.
public enum PillBeat: Equatable, Sendable {
    /// Out of the edge into an active phase.
    case rise
    /// Back into the edge.
    case sink
    /// Phase-to-phase in place (listening → transcribing → …).
    case morph
    /// The resting pill pulled out (or released) by the pointer.
    case peek
}

extension PillMotion {
    /// The beat a transition plays. `toResting`: the destination is `.idle`;
    /// `toDock`: with the peek dock out; `fromResting`: the capsule leaves the
    /// resting sliver (not the dock a start from the pill replaces);
    /// `toArmed`: the chord's first frame.
    ///
    /// An active phase going straight to the DOCK (a confirmation collapsing
    /// under a parked pointer) is a morph, never a sink: the dock is on screen
    /// and its fields must show at once (2026-11-19, the empty dock).
    public static func beat(moves: Bool, toResting: Bool, toDock: Bool, fromResting: Bool, toArmed: Bool) -> PillBeat {
        guard moves else { return .morph }
        if toResting { return fromResting ? .peek : (toDock ? .morph : .sink) }
        return fromResting ? (toArmed ? .peek : .rise) : .morph
    }
}

/// One keyframe of the pill's content reveal (`DictationPillView`'s
/// `ContentReveal`): the value it reaches, how long it takes, and how.
public struct PillRevealKeyframe: Equatable, Sendable {
    public enum Curve: Equatable, Sendable { case cubic, linear, bouncySpring }
    public var value: Double
    public var duration: TimeInterval
    public var curve: Curve

    public init(_ value: Double, _ duration: TimeInterval, _ curve: Curve = .cubic) {
        self.value = value
        self.duration = duration
        self.curve = curve
    }
}

/// How the capsule's CONTENT (never its surface) fades and scales on each
/// beat: hidden for the first stretch of a rise (the pill leaves the edge as
/// a plain blob, then the bars bloom in), gone early on a sink, untouched for
/// in-place morphs and peeks.
///
/// EVERY beat ends with the content shown. A sink used to end at nothing and
/// hold it until the next beat, so anything that landed meanwhile without a
/// clean beat of its own was drawn empty — the dock that peeked out 50 ms
/// into a sink stayed a blank capsule for as long as the pointer stayed
/// (2026-11-19). Now a sink keeps its content hidden only until it has
/// settled in the edge (`sinkEnd`), where the resting sliver has nothing to
/// show, and then shows it again.
public enum PillReveal {
    /// When a sink has settled: its move starts a `stagger` late.
    static var sinkEnd: TimeInterval {
        PillMotion.settleDelay(moves: true, reshapes: true, staggeredMove: true, peek: false)
    }
    private static let fadeOut: TimeInterval = 0.1
    private static let snap: TimeInterval = 0.01

    public static func opacity(for beat: PillBeat) -> [PillRevealKeyframe] {
        switch beat {
        case .rise: return [PillRevealKeyframe(0, 0.08), PillRevealKeyframe(1, 0.16)]
        case .sink:
            return [
                PillRevealKeyframe(0, fadeOut),
                PillRevealKeyframe(0, sinkEnd - fadeOut, .linear),
                PillRevealKeyframe(1, snap),
            ]
        case .morph, .peek: return [PillRevealKeyframe(1, snap)]
        }
    }

    public static func scale(for beat: PillBeat) -> [PillRevealKeyframe] {
        switch beat {
        case .rise: return [PillRevealKeyframe(0.6, 0.08), PillRevealKeyframe(1, 0.22, .bouncySpring)]
        case .sink:
            return [
                PillRevealKeyframe(0.7, fadeOut),
                PillRevealKeyframe(0.7, sinkEnd - fadeOut, .linear),
                PillRevealKeyframe(1, snap),
            ]
        case .morph, .peek: return [PillRevealKeyframe(1, snap)]
        }
    }
}
