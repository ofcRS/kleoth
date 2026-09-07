import Foundation

/// Where a screen recording lands and what it is called (design §3.1).
///
/// The file is written under its in-flight name (`…​.recording.mp4`) and renamed
/// only after `finishWriting` succeeds, so a name without that suffix is always
/// a playable file and a name with it is always debris from a crash.
public enum ScreenRecordingFileNaming {
    /// "screen-2026-09-06-143012". Pinned to `en_US_POSIX` + a fixed time zone
    /// -agnostic pattern so a 24-hour-less or non-Gregorian locale in the
    /// environment cannot change the shape of a file name.
    public static func baseName(for date: Date) -> String {
        // Built per call, like `MeetingStore`'s and `DictationLogStore`'s: a
        // `DateFormatter` is not `Sendable`, so it cannot be a shared static
        // under Swift 6 strict concurrency.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(ScreenRecordingDefaults.filePrefix)-\(formatter.string(from: date))"
    }

    /// The in-flight URL to open the writer on, uniqued with `-2`, `-3`, … when
    /// `existing` already holds that name (two sessions inside one second).
    ///
    /// `existing` is meant to be the directory's file names, but a bare base
    /// name counts as taken too — callers that only know the stems still get a
    /// unique answer.
    public static func recordingURL(in dir: URL, date: Date, existing: Set<String>) -> URL {
        let base = baseName(for: date)
        var candidate = base
        var suffix = 2
        while isTaken(candidate, in: existing) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return dir.appendingPathComponent(candidate + ScreenRecordingDefaults.recordingSuffix)
    }

    /// "screen-….recording.mp4" → "screen-….mp4".
    public static func finalURL(for recordingURL: URL) -> URL {
        let dir = recordingURL.deletingLastPathComponent()
        return dir.appendingPathComponent(stem(of: recordingURL) + ".mp4")
    }

    /// "screen-….recording.mp4" → "screen-…-recovered.mp4" — what an
    /// interrupted file is renamed to at launch when it still holds frames.
    public static func recoveredURL(for recordingURL: URL) -> URL {
        let dir = recordingURL.deletingLastPathComponent()
        return dir.appendingPathComponent(stem(of: recordingURL) + ScreenRecordingDefaults.recoveredSuffix)
    }

    /// True for a file still carrying the in-flight suffix.
    public static func isInFlightName(_ name: String) -> Bool {
        name.hasSuffix(ScreenRecordingDefaults.recordingSuffix)
    }

    /// "900 KB" / "48 MB" / "1.2 GB". Decimal units (the Finder convention),
    /// one decimal only above 1 GB, and no locale: the pill's `.saved` label is
    /// measured before it is rendered.
    public static func sizeText(bytes: Int64) -> String {
        let value = max(0, bytes)
        if value < 1_000 { return "\(value) B" }
        if value < 1_000_000 {
            return "\(Int((Double(value) / 1_000).rounded())) KB"
        }
        if value < 1_000_000_000 {
            return "\(Int((Double(value) / 1_000_000).rounded())) MB"
        }
        return String(format: "%.1f GB", Double(value) / 1_000_000_000)
    }

    // MARK: - Internals

    /// A base is taken when the directory already holds it bare, in flight, or
    /// finished.
    private static func isTaken(_ base: String, in existing: Set<String>) -> Bool {
        existing.contains(base)
            || existing.contains(base + ScreenRecordingDefaults.recordingSuffix)
            || existing.contains(base + ".mp4")
            || existing.contains(base + ScreenRecordingDefaults.recoveredSuffix)
    }

    /// The name without ".recording" and without the extension.
    private static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        if isInFlightName(name) {
            return String(name.dropLast(ScreenRecordingDefaults.recordingSuffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
