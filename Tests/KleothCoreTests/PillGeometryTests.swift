import Testing
import Foundation
import CoreGraphics
@testable import KleothCore

/// Placement + level math for the dictation pill (design §3.11, §5.6, §8.1).
/// All coordinates are Cocoa screen coordinates (y up, origin = bottom-left of
/// the panel *including* its transparent shadow margin).
@Suite struct PillGeometryTests {
    private let panelSize = CGSize(width: 240, height: 60)
    private let shadowPadding: CGFloat = 18

    // A "built-in display" style visible frame anchored at the origin.
    private var mainVisible: CGRect { CGRect(x: 0, y: 0, width: 1600, height: 1000) }
    // A second display sitting to the left of and below the main one — the case
    // where forgetting `visibleFrame.minX/minY` puts the pill on the wrong screen.
    private var offOriginVisible: CGRect { CGRect(x: -1920, y: -300, width: 1920, height: 1080) }

    @Test func defaultOriginIsBottomCenter() {
        let origin = PillGeometry.defaultOrigin(
            panelSize: panelSize, shadowPadding: shadowPadding, in: mainVisible
        )
        #expect(origin.x == CGFloat(1600 - 240) / 2)
        // The capsule bottom sits `defaultBottomInset` above the screen; the
        // panel starts `shadowPadding` lower because of the transparent margin.
        #expect(origin.y == PillGeometry.defaultBottomInset - shadowPadding)
    }

    @Test func defaultOriginStaysInsideOffOriginScreen() {
        let origin = PillGeometry.defaultOrigin(
            panelSize: panelSize, shadowPadding: shadowPadding, in: offOriginVisible
        )
        #expect(origin.x == offOriginVisible.midX - panelSize.width / 2)
        #expect(origin.y == offOriginVisible.minY + PillGeometry.defaultBottomInset - shadowPadding)
        let rect = CGRect(origin: origin, size: panelSize)
        #expect(offOriginVisible.contains(rect))
    }

    @Test func clampPinsAllFourEdgesAndIsIdempotent() {
        let lowerX = mainVisible.minX + PillGeometry.edgeMargin
        let lowerY = mainVisible.minY + PillGeometry.edgeMargin
        let upperX = mainVisible.maxX - PillGeometry.edgeMargin - panelSize.width
        let upperY = mainVisible.maxY - PillGeometry.edgeMargin - panelSize.height

        let left = PillGeometry.clamp(CGPoint(x: -500, y: 400), panelSize: panelSize, in: mainVisible)
        #expect(left.x == lowerX)
        let right = PillGeometry.clamp(CGPoint(x: 5000, y: 400), panelSize: panelSize, in: mainVisible)
        #expect(right.x == upperX)
        let bottom = PillGeometry.clamp(CGPoint(x: 400, y: -500), panelSize: panelSize, in: mainVisible)
        #expect(bottom.y == lowerY)
        let top = PillGeometry.clamp(CGPoint(x: 400, y: 5000), panelSize: panelSize, in: mainVisible)
        #expect(top.y == upperY)

        // Idempotent, and an already-legal point is left alone.
        for point in [left, right, bottom, top, CGPoint(x: 400, y: 400)] {
            let once = PillGeometry.clamp(point, panelSize: panelSize, in: mainVisible)
            let twice = PillGeometry.clamp(once, panelSize: panelSize, in: mainVisible)
            #expect(once == twice)
        }

        // A panel wider/taller than the screen pins to the lower bound instead
        // of inverting the range.
        let huge = CGSize(width: 4000, height: 4000)
        let pinned = PillGeometry.clamp(CGPoint(x: 900, y: 900), panelSize: huge, in: mainVisible)
        #expect(pinned == CGPoint(x: lowerX, y: lowerY))
    }

    @Test func placementOriginRoundTrips() {
        let origin = CGPoint(x: 312, y: 640)
        let placement = PillGeometry.placement(
            origin: origin, panelSize: panelSize, in: mainVisible,
            displayId: 7, displayName: "Built-in Retina Display"
        )
        let restored = PillGeometry.origin(for: placement, panelSize: panelSize, in: mainVisible)
        #expect(abs(restored.x - origin.x) < 0.001)
        #expect(abs(restored.y - origin.y) < 0.001)
        #expect(placement.displayId == 7)
        #expect(placement.visibleWidth == 1600)
        #expect(placement.visibleHeight == 1000)
    }

    @Test func placementRestoresOnResizedScreen() {
        // Parked dead center of a 1600×1000 screen…
        let origin = CGPoint(x: mainVisible.midX - panelSize.width / 2,
                             y: mainVisible.midY - panelSize.height / 2)
        let placement = PillGeometry.placement(
            origin: origin, panelSize: panelSize, in: mainVisible,
            displayId: 1, displayName: "Main"
        )
        #expect(abs(placement.relativeCenterX - 0.5) < 0.001)
        #expect(abs(placement.relativeCenterY - 0.5) < 0.001)

        // …still dead center on a differently sized, differently placed screen.
        let resized = CGRect(x: 200, y: 100, width: 800, height: 600)
        let restored = PillGeometry.origin(for: placement, panelSize: panelSize, in: resized)
        #expect(abs(restored.x - (resized.midX - panelSize.width / 2)) < 0.001)
        #expect(abs(restored.y - (resized.midY - panelSize.height / 2)) < 0.001)
        #expect(resized.contains(CGRect(origin: restored, size: panelSize)))
    }

    @Test func corruptFractionsClamp() {
        let wild = PillPlacement(
            displayId: 1, displayName: "Main", visibleWidth: 1600, visibleHeight: 1000,
            relativeCenterX: 42, relativeCenterY: -17
        )
        let origin = PillGeometry.origin(for: wild, panelSize: panelSize, in: mainVisible)
        #expect(mainVisible.contains(CGRect(origin: origin, size: panelSize)))

        let nonFinite = PillPlacement(
            displayId: 1, displayName: "Main", visibleWidth: 1600, visibleHeight: 1000,
            relativeCenterX: .nan, relativeCenterY: .infinity
        )
        let centered = PillGeometry.origin(for: nonFinite, panelSize: panelSize, in: mainVisible)
        #expect(centered.x.isFinite && centered.y.isFinite)
        #expect(mainVisible.contains(CGRect(origin: centered, size: panelSize)))
        // Non-finite fractions read as "centered", not "corner".
        #expect(abs(centered.x - (mainVisible.midX - panelSize.width / 2)) < 0.001)
    }

    @Test func placementCodableRoundTripAndGarbageFails() throws {
        let placement = PillPlacement(
            displayId: 69_733_382, displayName: "Studio Display",
            visibleWidth: 2560, visibleHeight: 1415,
            relativeCenterX: 0.42, relativeCenterY: 0.11
        )
        let data = try JSONEncoder().encode(placement)
        let decoded = try JSONDecoder().decode(PillPlacement.self, from: data)
        #expect(decoded == placement)

        // A stale/hand-edited defaults blob must throw, not decode into
        // nonsense — the controller falls back to the default origin.
        let garbage = Data(#"{"displayId":"not-a-number"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(PillPlacement.self, from: garbage)
        }
    }

    @Test func normalizedLevelBoundsMonotonicAndNeverNaN() {
        #expect(PillGeometry.normalizedLevel(rms: 0) == 0)
        #expect(PillGeometry.normalizedLevel(rms: 1) == 1)
        #expect(PillGeometry.normalizedLevel(rms: 2) == 1)          // clipped input
        #expect(PillGeometry.normalizedLevel(rms: -0.5) == 0)
        #expect(PillGeometry.normalizedLevel(rms: .nan) == 0)
        #expect(PillGeometry.normalizedLevel(rms: .infinity) == 0)
        #expect(PillGeometry.normalizedLevel(rms: 0.0001) == 0)     // below the −55 dB floor

        var previous = -1.0
        for step in 0...20 {
            let level = PillGeometry.normalizedLevel(rms: Float(step) / 20)
            #expect(!level.isNaN)
            #expect(level >= 0 && level <= 1)
            #expect(level >= previous)
            previous = level
        }
    }

    @Test func smoothLevelAttackFasterThanRelease() {
        let rising = PillGeometry.smoothLevel(previous: 0, target: 1)
        let falling = PillGeometry.smoothLevel(previous: 1, target: 0)
        #expect(abs(rising - 0.6) < 0.0001)
        #expect(abs(falling - 0.75) < 0.0001)
        // Attack moves further per tick than release.
        #expect(abs(rising - 0) > abs(1 - falling))

        // Converges, stays in range, and survives garbage.
        var level = 0.0
        for _ in 0..<40 { level = PillGeometry.smoothLevel(previous: level, target: 0.8) }
        #expect(abs(level - 0.8) < 0.01)
        #expect(PillGeometry.smoothLevel(previous: .nan, target: .nan) == 0)
        #expect(PillGeometry.smoothLevel(previous: 0.5, target: 0.5) == 0.5)
    }
}
