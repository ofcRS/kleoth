import SwiftUI
import KleothCore
import KleothPillUI

/// Settings → Meetings, under Calendar: call detection (meetings-in-the-pill
/// design §3.2.7). Off by default — the toggle is the only way to turn the
/// offers on. Under it, the reason the watcher can't start when the
/// controller reports one, then one row per "Never for …" answer with Remove
/// (hidden when there are none), and a footer that says what is watched, what
/// is read, and that nothing new is asked for.
///
/// Reads `MeetingDetectionController` through `@EnvironmentObject` (injected
/// into the Settings scene only), so every change — a "Never for …" clicked on
/// the pill while this window is open — shows at once.
struct SettingsMeetingDetectionSection: View {
    @EnvironmentObject private var detection: MeetingDetectionController

    var body: some View {
        Section {
            Toggle("Offer to record calls", isOn: enabledBinding)

            // Only while something wants the watcher (this toggle, or a
            // meeting recording) and Core Audio refused it; cleared otherwise.
            if let reason = detection.unavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(neverRows) { row in
                LabeledContent {
                    Button("Remove") { detection.unignore(key: row.key) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                        if let note = row.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Call detection")
        } footer: {
            captionFooter("Kleoth notices which apps are using the microphone — no audio is read. When Zoom, Teams, Slack, FaceTime, Google Meet or another app starts using it, the pill asks whether to record, and when the call app lets go of it, the pill suggests stopping. Nothing is recorded until you click Record, and Kleoth never stops a recording on its own. With Screen Recording or Accessibility already allowed, it reads the call window's title to tell a meeting tab from other sites (a title that names no meeting is never saved); with calendar naming on, an offer for a call names the event. No new permission is asked for. Whether this is on or off, each meeting you record notes which app it happened in.")
        }
    }

    // MARK: - Toggle

    /// Straight through to the controller, which persists it and starts or
    /// stops the watcher (pre-flight M-11: no local mirror to keep in sync).
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { detection.isEnabled },
            set: { detection.setEnabled($0) }
        )
    }

    // MARK: - Never list

    private struct NeverRow: Identifiable {
        let key: String
        /// The pill button's own words: "Never for Zoom", "Never for calls in
        /// Chrome", "Never for Chrome".
        let label: String
        /// What stays offered, for a `browser:` entry only.
        let note: String?
        var id: String { key }
    }

    /// The ignored sources, worded exactly as the pill's button was
    /// (`MeetingPillAction.neverOffer(...).title`), so "calls in Chrome" and
    /// plain "Chrome" — two entries with the same stored name — stay apart.
    /// A `browser:` entry silences only mic use where no call was seen, so it
    /// says what is still offered (the pill button's tooltip, §3.2.4).
    private var neverRows: [NeverRow] {
        detection.ignored.map { key, storedName in
            let trimmed = storedName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? key : trimmed
            return NeverRow(
                key: key,
                label: MeetingPillAction.neverOffer(key: key, name: name).title,
                note: key.hasPrefix("browser:") ? "Google Meet and other calls in \(name) are still offered" : nil
            )
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    // MARK: - Section helpers

    /// The standard quiet footer caption used under each Settings section.
    /// Duplicated from `SettingsView` on purpose — that one is `private` to
    /// its own type (the `SettingsScreenRecordingSection` idiom).
    private func captionFooter(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, KleothMetrics.spacingXS)
    }
}
