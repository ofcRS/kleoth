import SwiftUI
import KleothCore

/// The model control for a non-OpenRouter provider (OpenRouter keeps its
/// catalog picker in `SettingsView` / `SettingsDictationSection`). What it
/// renders follows `AIProvider.modelChoice`.
///
/// **Everything committed from here is a user edit.** `model` is also written
/// programmatically — `SettingsView.syncProviderModels()` re-seeds it on load
/// and whenever the resolved provider changes — and `.onChange(of: model)`
/// cannot tell that apart from a pick. Committing on it meant that merely
/// opening Settings persisted an `ai_models` override the user never chose
/// (pinning, say, `claude-code/summary = sonnet` past any future change of
/// default) and dropped the detector's 10 min cache, re-spawning the CLI
/// probes. A control's own `Binding` setter has exactly the right semantics:
/// SwiftUI runs it only when the control is operated, never on a re-seed.
struct ProviderModelField: View {
    let title: String
    let provider: AIProvider
    let task: AIProvider.Task
    @Binding var model: String
    /// Ids the local server lists (`ProviderAvailability.available(models:)`).
    let serverModels: [String]
    @EnvironmentObject private var controller: RecordingController

    var body: some View {
        switch provider.modelChoice {
        case let .aliases(list):
            Picker(title, selection: picked) {
                ForEach(pinned(list), id: \.self) { Text(label($0)).tag($0) }
            }
        case .serverList:
            Picker(title, selection: picked) {
                // Nothing pinned = whatever the server lists first, which is
                // what `ProviderFactory` actually runs. Without a row for it
                // the selection would match no tag and the picker would read
                // blank while a real model answered.
                if model.isEmpty {
                    Text("First available (\(serverModels.first ?? "none"))").tag("")
                }
                ForEach(pinned(serverModels), id: \.self) { Text($0).tag($0) }
            }
        case let .freeText(placeholder):
            // Return commits; a keystroke does not (it would write the Keychain
            // and re-probe every provider per character). An unsubmitted edit is
            // flushed by `SettingsView.commitAll()` when the window closes.
            TextField(title, text: $model, prompt: Text(placeholder))
                .onSubmit { commit() }
        case .fixed:
            // One model, nothing to pick — and so nothing to store either.
            LabeledContent(title) { Text(provider.displayName).foregroundStyle(.secondary) }
        case .openRouterCatalog:
            EmptyView()   // never reached: the caller renders the catalog picker
        }
    }

    /// The pickers' selection: reads `model`, and writes it back — and to the
    /// Keychain — only when the user picks a row.
    private var picked: Binding<String> {
        Binding(
            get: { model },
            set: { newValue in
                guard newValue != model else { return }
                model = newValue
                commit()
            }
        )
    }

    /// The current value always stays selectable (a server that stopped
    /// listing it, an alias typed by hand).
    private func pinned(_ list: [String]) -> [String] {
        model.isEmpty || list.contains(model) ? list : [model] + list
    }

    private func label(_ alias: String) -> String {
        alias == provider.defaultModel(for: task) ? "\(alias)  (default)" : alias
    }

    private func commit() {
        controller.updateProviderModel(model, for: task, on: provider)
    }
}
