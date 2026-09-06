import SwiftUI
import AppKit
import KleothCapture
import KleothCore

/// Settings → Screen Recording: the TCC state and a way into the folder.
///
/// Deliberately two rows (design §2.6, §3.4). Screen recording has **no**
/// preference of its own — no `Settings` field, no Keychain key, no
/// `AppConfig` line, no toggle — because every knob v1 could expose (frame
/// rate, bitrate, region memory) is either derived (`CaptureGeometry`) or
/// chosen per session at the picker. The Settings window is a fixed 460×600
/// and this section has to earn its two rows.
///
/// Reaches the controller through `@EnvironmentObject` only — never
/// `ScreenRecordingController.shared`. Reading a `@Published` through a plain
/// static does not subscribe the view, so the polled permission state would
/// never refresh on screen.
struct SettingsScreenRecordingSection: View {
    @EnvironmentObject private var screenRecording: ScreenRecordingController

    var body: some View {
        Section {
            permissionRow
                // Screen Recording TCC can be granted (or revoked) in System
                // Settings while this window is open and macOS posts no
                // notification for it, so poll gently — the same idiom as the
                // dictation section's Accessibility row. It rides on the
                // always-present permission row rather than the Section itself
                // (a `Form` should see an unmodified `Section`), and `.task`
                // cancels the loop when the row goes away.
                //
                // Note the honest caveat this polling exposes: a *fresh* grant
                // does not flip this row green, because
                // `CGPreflightScreenCaptureAccess()` answers for the process as
                // it was launched. It flips after the relaunch — which is
                // exactly what the not-granted copy tells the user to do.
                .task {
                    while !Task.isCancelled {
                        screenRecording.refreshPermission()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }

            Button("Open Recordings Folder") {
                screenRecording.openRecordingsFolder()
            }
            .help("Reveal ~/Kleoth/screen-recordings in Finder, creating it if this is the first time")
        } header: {
            KleothSectionHeader("Screen Recording", systemImage: "record.circle")
        } footer: {
            captionFooter("Records the screen with system audio and your microphone into ~/Kleoth/screen-recordings. macOS may ask you to re-allow screen recording about once a month. A Bluetooth headset's playback quality drops while its microphone is open.")
        }
    }

    // MARK: - Permission

    /// The outer `VStack` is deliberately unconditional: the granted and
    /// not-granted bodies swap inside it, so the view identity — and with it
    /// the 1 Hz `.task` above — survives the flip.
    private var permissionRow: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
            if screenRecording.permissionState == .granted {
                Label("Screen Recording access granted", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(KleothPalette.successTint)
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: KleothMetrics.spacingS) {
                    Text("Not granted — allow it, then quit and reopen Kleoth.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: KleothMetrics.spacingM)
                    Button("Open System Settings") { openScreenRecordingSettings() }
                }
            }
        }
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: ScreenRecordingPermission.settingsURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Section helpers

    /// The standard quiet footer caption used under each Settings section.
    /// Duplicated from `SettingsView` on purpose — that one is `private` to its
    /// own type, and this section is a separate file so the fixed-size window's
    /// biggest view does not grow another 60 lines.
    private func captionFooter(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, KleothMetrics.spacingXS)
    }
}
