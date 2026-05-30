import SwiftUI

/// First-run consent acknowledgement shown before recording participants.
///
/// Surfaces the legal/ethical disclosure and records the user's
/// acknowledgement on the shared `RecordingController`.
struct ConsentView: View {
    @EnvironmentObject private var controller: RecordingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Before you record", systemImage: "exclamationmark.shield")
                .font(.headline)

            Text(
                "Kleoth records system + microphone audio locally. "
                + "Make sure everyone in the call consents to being recorded — "
                + "laws vary by jurisdiction."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button {
                controller.acknowledgeConsent()
            } label: {
                Label("I understand — everyone consents", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: 320)
    }
}
