import SwiftUI
import KleothCore

// MARK: - Liquid Glass adoption (macOS 26 "Tahoe"), gracefully degrading

extension View {
    /// The single prominent "hero" action. Liquid Glass on macOS 26, classic
    /// bordered-prominent below. Apple's guidance: reserve glass for the most
    /// important functional element, so only the record button uses this.
    @ViewBuilder func kleothProminentButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Soft scroll-edge fade under the window/popover chrome on macOS 26; no-op
    /// on earlier systems. Content stays on standard materials, not glass.
    @ViewBuilder func kleothSoftScrollEdge() -> some View {
        if #available(macOS 26, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

// MARK: - Display formatting for meetings

enum MeetingFormat {
    static func usd(_ value: Double) -> String { String(format: "$%.4f", value) }

    /// "1m 03s" / "47s", or nil when unknown/zero.
    static func duration(_ secs: Double?) -> String? {
        guard let secs, secs > 0 else { return nil }
        let total = Int(secs.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(String(format: "%02d", seconds))s" : "\(seconds)s"
    }

    /// A short clock time ("5:26 PM") when the start instant is known.
    static func time(_ meeting: RecentMeeting) -> String? {
        guard let date = meeting.startedAt else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// Relative day header: "Today", "Yesterday", else "Friday, May 30, 2026".
    static func dayLabel(_ meeting: RecentMeeting) -> String {
        let date = meeting.startedAt ?? parseDay(meeting.date)
        guard let date else { return meeting.date }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func parseDay(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}

// MARK: - Empty / unavailable state

/// Small stand-in for `ContentUnavailableView` (kept compatible across
/// toolchains): a centered glyph, title, and message.
struct ContentUnavailableCompat: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
