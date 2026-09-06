import Foundation

/// Elapsed wall time as digits the pill and the popover can render in a fixed
/// monospaced box (design §3.1). Deliberately locale-free: this is a duration
/// readout, not a date, and it must be byte-identical on every machine so the
/// 56 pt digit frame never re-measures.
///
/// `0 → "00:00"`, `754 → "12:34"`, `3754 → "1:02:34"`, `36000 → "10:00:00"`.
public enum ElapsedFormatter {
    public static func string(seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(pad(minutes)):\(pad(secs))"
        }
        return "\(pad(minutes)):\(pad(secs))"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
