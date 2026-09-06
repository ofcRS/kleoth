import Testing
import Foundation
@testable import KleothCore

/// File naming for screen recordings (design §3.1). The invariant these tests
/// defend: a name WITHOUT `.recording` is always a finished, playable file and a
/// name WITH it is always debris — the launch sweep and the Finder reveal both
/// key on nothing else.
@Suite struct ScreenRecordingFileNamingTests {
    private let dir = URL(fileURLWithPath: "/Users/someone/Kleoth/screen-recordings", isDirectory: true)

    /// A fixed LOCAL wall-clock instant: the name is meant to read as the time
    /// the user saw on their menu bar, so it follows `TimeZone.current` on
    /// purpose. Constructing it from components is what makes the expected
    /// string below deterministic on any machine.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var components = DateComponents()
        components.year = y; components.month = mo; components.day = d
        components.hour = h; components.minute = mi; components.second = s
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components)!
    }

    @Test func baseNameIsThePrefixPlusASortableTimestamp() {
        #expect(ScreenRecordingFileNaming.baseName(for: date(2026, 9, 6, 14, 30, 12)) == "screen-2026-09-06-143012")
    }

    /// 24-hour digits, zero padded, no separators inside the time — the shape
    /// the sweep's glob and a human `ls` both rely on.
    @Test func baseNameShapeIsStrict() {
        let name = ScreenRecordingFileNaming.baseName(for: date(2026, 1, 2, 3, 4, 5))
        #expect(name == "screen-2026-01-02-030405")
        #expect(name.range(of: "^screen-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$", options: .regularExpression) != nil)
    }

    /// The formatter is pinned to `en_US_POSIX` + Gregorian. A user whose locale
    /// is Buddhist (year 2569) or 12-hour must still get the same bytes, so the
    /// name must NOT match what those locales would produce.
    @Test func baseNameIgnoresTheEnvironmentsCalendarAndHourCycle() {
        let instant = date(2026, 9, 6, 14, 30, 12)

        let buddhist = DateFormatter()
        buddhist.locale = Locale(identifier: "th_TH_u_ca_buddhist")
        buddhist.dateFormat = "yyyy-MM-dd-HHmmss"
        #expect(ScreenRecordingFileNaming.baseName(for: instant) != "screen-\(buddhist.string(from: instant))")

        let twelveHour = DateFormatter()
        twelveHour.locale = Locale(identifier: "en_US")
        twelveHour.dateFormat = "yyyy-MM-dd-hhmmss a"
        #expect(ScreenRecordingFileNaming.baseName(for: instant) != "screen-\(twelveHour.string(from: instant))")

        // Positive control: the Gregorian year is what lands in the name.
        #expect(ScreenRecordingFileNaming.baseName(for: instant).contains("2026"))
    }

    @Test func recordingURLUsesTheInFlightSuffixWhenNothingClashes() {
        let url = ScreenRecordingFileNaming.recordingURL(in: dir, date: date(2026, 9, 6, 14, 30, 12), existing: [])
        #expect(url == dir.appendingPathComponent("screen-2026-09-06-143012.recording.mp4"))
        #expect(ScreenRecordingFileNaming.isInFlightName(url.lastPathComponent))
    }

    /// Two sessions inside one second (or a finished file from an earlier one)
    /// must not collide — the second gets `-2`, the third `-3`.
    @Test func recordingURLUniquesAgainstExistingNames() {
        let when = date(2026, 9, 6, 14, 30, 12)

        let againstBase = ScreenRecordingFileNaming.recordingURL(in: dir, date: when, existing: ["screen-2026-09-06-143012"])
        #expect(againstBase.lastPathComponent == "screen-2026-09-06-143012-2.recording.mp4")

        let againstFinished = ScreenRecordingFileNaming.recordingURL(
            in: dir, date: when, existing: ["screen-2026-09-06-143012.mp4"]
        )
        #expect(againstFinished.lastPathComponent == "screen-2026-09-06-143012-2.recording.mp4")

        let againstTwo = ScreenRecordingFileNaming.recordingURL(
            in: dir, date: when,
            existing: ["screen-2026-09-06-143012.mp4", "screen-2026-09-06-143012-2.recording.mp4"]
        )
        #expect(againstTwo.lastPathComponent == "screen-2026-09-06-143012-3.recording.mp4")
    }

    /// Debris from a crash counts as taken too, otherwise the recovery sweep and
    /// a fresh session would fight over one name.
    @Test func recoveredDebrisAlsoBlocksAName() {
        let url = ScreenRecordingFileNaming.recordingURL(
            in: dir, date: date(2026, 9, 6, 14, 30, 12),
            existing: ["screen-2026-09-06-143012-recovered.mp4"]
        )
        #expect(url.lastPathComponent == "screen-2026-09-06-143012-2.recording.mp4")
    }

    @Test func finalURLStripsOnlyTheInFlightMarker() {
        let recording = dir.appendingPathComponent("screen-2026-09-06-143012.recording.mp4")
        #expect(ScreenRecordingFileNaming.finalURL(for: recording)
            == dir.appendingPathComponent("screen-2026-09-06-143012.mp4"))
        #expect(ScreenRecordingFileNaming.finalURL(for: recording).lastPathComponent.contains(".recording") == false)
    }

    /// Renaming an already-final URL is a no-op, so a double call cannot eat a
    /// path component.
    @Test func finalURLIsIdempotent() {
        let final = dir.appendingPathComponent("screen-2026-09-06-143012.mp4")
        #expect(ScreenRecordingFileNaming.finalURL(for: final) == final)
    }

    @Test func recoveredURLMarksAnInterruptedFile() {
        let recording = dir.appendingPathComponent("screen-2026-09-06-143012.recording.mp4")
        #expect(ScreenRecordingFileNaming.recoveredURL(for: recording)
            == dir.appendingPathComponent("screen-2026-09-06-143012-recovered.mp4"))
    }

    @Test func isInFlightNameOnlyMatchesTheSuffix() {
        #expect(ScreenRecordingFileNaming.isInFlightName("screen-2026-09-06-143012.recording.mp4"))
        #expect(ScreenRecordingFileNaming.isInFlightName("screen-2026-09-06-143012.mp4") == false)
        #expect(ScreenRecordingFileNaming.isInFlightName("screen-2026-09-06-143012-recovered.mp4") == false)
        #expect(ScreenRecordingFileNaming.isInFlightName("meeting.m4a") == false)
    }

    /// Decimal units (the Finder convention), one decimal only above 1 GB, and
    /// no locale — the `.saved` pill measures this string before it renders it.
    @Test func sizeTextUsesDecimalUnits() {
        #expect(ScreenRecordingFileNaming.sizeText(bytes: 900_000) == "900 KB")
        #expect(ScreenRecordingFileNaming.sizeText(bytes: 48_000_000) == "48 MB")
        #expect(ScreenRecordingFileNaming.sizeText(bytes: 1_200_000_000) == "1.2 GB")
    }

    @Test func sizeTextHandlesTheEdges() {
        #expect(ScreenRecordingFileNaming.sizeText(bytes: 0) == "0 B")
        #expect(ScreenRecordingFileNaming.sizeText(bytes: -1) == "0 B")
        #expect(ScreenRecordingFileNaming.sizeText(bytes: 999) == "999 B")
        #expect(ScreenRecordingFileNaming.sizeText(bytes: 1_000) == "1 KB")
        #expect(ScreenRecordingFileNaming.sizeText(bytes: 1_000_000) == "1 MB")
        #expect(ScreenRecordingFileNaming.sizeText(bytes: 1_000_000_000) == "1.0 GB")
    }
}
