import SwiftUI
import KleothCore

/// Settings → Accounts, top: which backend runs summaries and dictation
/// polish. One picker (Automatic + the five providers), the local server's
/// URL/key when relevant, a live status row per provider and a footer that
/// says what each task resolves to right now.
struct SettingsAIProviderSection: View {
    @EnvironmentObject private var controller: RecordingController
    @Binding var aiProvider: String
    @Binding var localServerURL: String
    @Binding var localServerKey: String

    private var status: ProviderStatus? { controller.providerStatus }

    var body: some View {
        Section {
            Picker("AI provider", selection: $aiProvider) {
                Text("Automatic").tag("auto")
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
                }
            }
            .onChange(of: aiProvider) { _, newValue in controller.updateAIProvider(newValue) }
            // Keep the status rows honest while the window is open. Cheap: the
            // detector caches for 10 min, so this only picks up changes. It
            // rides on the always-present picker row rather than the Section
            // itself — a `Form` should see an unmodified `Section` (the same
            // reason `SettingsDictationSection` polls from its toggle row).
            .task {
                while !Task.isCancelled {
                    await controller.refreshProviderStatus()
                    try? await Task.sleep(for: .seconds(5))
                }
            }

            if showsServerFields {
                TextField("Server URL", text: $localServerURL, prompt: Text(ProviderSettings.defaultLocalServerURL.absoluteString))
                    .onSubmit { controller.updateLocalServerURL(localServerURL) }
                // Never displayed and never logged: the token only ever goes to
                // the Keychain and out as the server's `Authorization` header.
                SecureField("Server key (optional)", text: $localServerKey)
                    .onSubmit { controller.updateLocalServerKey(localServerKey) }
            }

            ForEach(AIProvider.allCases) { provider in
                LabeledContent(provider.displayName) {
                    Text(availabilityText(provider))
                        .foregroundStyle(isAvailable(provider) ? KleothPalette.successTint : .secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            HStack(spacing: KleothMetrics.spacingS) {
                Text("AI provider")
                Button {
                    Task {
                        await AppConfig.detector.refresh()
                        await controller.refreshProviderStatus()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Check again which tools and servers are available")
            }
        } footer: {
            Text(status?.footerText ?? "Checking installed AI tools…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The URL/key fields show when the local server is picked or is what
    /// Automatic resolved to for either task.
    private var showsServerFields: Bool {
        if aiProvider == AIProvider.localServer.rawValue { return true }
        guard let status else { return false }
        for result in [status.summary, status.dictation] {
            if case let .success(selection) = result, selection.provider == .localServer { return true }
        }
        return false
    }

    private func isAvailable(_ provider: AIProvider) -> Bool {
        status?.snapshot[provider]?.isAvailable ?? false
    }

    private func availabilityText(_ provider: AIProvider) -> String {
        switch status?.snapshot[provider] {
        case let .available(detail, _): return detail
        case let .unavailable(reason): return reason
        case nil: return "…"
        }
    }
}
