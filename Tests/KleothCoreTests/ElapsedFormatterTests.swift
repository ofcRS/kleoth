import Testing
import Foundation
@testable import KleothCore

/// The recording pill's digit box (design §3.1). The point of these numbers is
/// that they are locale-free and byte-stable: the pill measures a fixed 56 pt
/// monospaced frame once and must never have to re-measure mid-recording.
@Suite struct ElapsedFormatterTests {
    @Test func belowAnHourIsAlwaysTwoZeroPaddedFields() {
        #expect(ElapsedFormatter.string(seconds: 0) == "00:00")
        #expect(ElapsedFormatter.string(seconds: 59) == "00:59")
        #expect(ElapsedFormatter.string(seconds: 60) == "01:00")
        #expect(ElapsedFormatter.string(seconds: 754) == "12:34")
        #expect(ElapsedFormatter.string(seconds: 3599) == "59:59")
    }

    @Test func anHourAddsAnUnpaddedHoursField() {
        #expect(ElapsedFormatter.string(seconds: 3600) == "1:00:00")
        #expect(ElapsedFormatter.string(seconds: 3754) == "1:02:34")
        #expect(ElapsedFormatter.string(seconds: 36_000) == "10:00:00")
    }

    /// A negative elapsed time can only come from a clock jump; it must render
    /// as zero rather than "-1:-1".
    @Test func negativeSecondsClampToZero() {
        #expect(ElapsedFormatter.string(seconds: -5) == "00:00")
    }

    /// The width of the string only ever grows at the hour boundary — that is
    /// what lets the pill reserve one fixed frame.
    @Test func widthIsStableWithinEachRange() {
        for seconds in stride(from: 0, to: 3600, by: 137) {
            #expect(ElapsedFormatter.string(seconds: seconds).count == 5)
        }
        for seconds in stride(from: 3600, to: 35_999, by: 977) {
            #expect(ElapsedFormatter.string(seconds: seconds).count == 7)
        }
    }
}
