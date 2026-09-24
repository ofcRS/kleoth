import SwiftUI

/// First-run consent acknowledgement shown before recording participants.
///
/// Surfaces the legal/ethical disclosure and records the user's
/// acknowledgement on the shared `RecordingController`, in one of two forms:
///
/// - `startsRecording: false` (the default): the popover card above the record
///   button, which stays disabled until the user acknowledges.
/// - `startsRecording: true`: the "Before you record" window, which the
///   menu-bar label opens when `start()` refuses for missing consent from a
///   surface with no card of its own — the global hotkey,
///   `kleoth://record|toggle`, the Start Recording intent. The user already
///   asked to record there, so its primary button acknowledges AND starts.
///   That button never closes the window; it closes itself once `isRecording`
///   is true, so a start that fails keeps it up with the reason instead of
///   leaving the explanation in a popover nobody is looking at. Not now, Esc
///   and the close button close it without recording.
struct ConsentView: View {
    @EnvironmentObject private var controller: RecordingController
    @Environment(\.dismissWindow) private var dismissWindow

    /// The "Before you record" window (`true`) or the popover card (`false`).
    private let startsRecording: Bool

    /// Why the window's last start attempt failed: `statusMessage` as it stood
    /// when `start()` returned without recording. A snapshot, not a live read —
    /// background pipeline runs share that line and would replace the reason
    /// while the window is still up. `nil` until an attempt fails.
    @State private var startFailure: String?

    /// Explicit because the private property wrappers above would make the
    /// synthesized memberwise initializer private to this file.
    init(startsRecording: Bool = false) {
        self.startsRecording = startsRecording
    }

    var body: some View {
        if startsRecording {
            window
        } else {
            card
        }
    }

    // MARK: - Shared content

    private var header: some View {
        KleothSectionHeader("Before you record", systemImage: "exclamationmark.shield")
    }

    private var notice: some View {
        Text(
            "Kleoth records system + microphone audio locally. "
            + "Make sure everyone in the call consents to being recorded — "
            + "laws vary by jurisdiction."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Popover card

    private var card: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
            header

            notice

            Button {
                controller.acknowledgeConsent()
            } label: {
                Label("I understand — everyone consents", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .kleothCard(padding: KleothMetrics.spacingM)
    }

    // MARK: - "Before you record" window

    private var window: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingL) {
            header

            notice

            HStack(spacing: KleothMetrics.spacingM) {
                Spacer(minLength: 0)

                Button("Not now") {
                    dismissWindow(id: "kleoth-consent")
                }
                .keyboardShortcut(.cancelAction)

                // Deliberately no `.defaultAction`: the window can come up
                // while the user is typing elsewhere, and a stray Return must
                // not acknowledge consent and start a recording.
                Button("I understand — start recording") {
                    acknowledgeAndStart()
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)

            if let startFailure {
                Label {
                    Text(startFailure)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(KleothPalette.failureTint)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(KleothMetrics.spacingXL)
        .frame(width: 420)
        // A titled window like History and Settings: a regular, ⌘-Tab-able app
        // while it is open, back to a pure menu-bar agent once it closes.
        .onAppear { AppActivation.shared.windowOpened() }
        .onDisappear { AppActivation.shared.windowClosed() }
        // Close on the recording actually running, never on the click, so a
        // failed start stays visible here. A start from anywhere counts (the
        // popover's too): once a meeting records, there is nothing left to ask.
        .onChange(of: controller.isRecording) { _, isRecording in
            if isRecording { dismissWindow(id: "kleoth-consent") }
        }
    }

    /// The window's primary action: acknowledge, then start. `start()` reports
    /// a failure only through `statusMessage`, so one that returns without
    /// recording pins that message under the buttons.
    private func acknowledgeAndStart() {
        startFailure = nil
        controller.acknowledgeConsent()
        Task {
            await controller.start()
            if !controller.isRecording {
                startFailure = controller.statusMessage
            }
        }
    }
}
