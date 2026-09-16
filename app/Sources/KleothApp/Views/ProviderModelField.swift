import SwiftUI
import KleothCore

/// The model control for a non-OpenRouter provider (OpenRouter keeps its
/// catalog picker in `SettingsView` / `SettingsDictationSection`). What it
/// renders follows `AIProvider.modelChoice`.
struct ProviderModelField: View {
    let title: String
    let provider: AIProvider
    let task: AIProvider.Task
    @Binding var model: String
    /// Ids the local server lists (`ProviderAvailability.available(models:)`).
    let serverModels: [String]
    @EnvironmentObject private var controller: RecordingController

    var body: some View {
        Group {
            switch provider.modelChoice {
            case let .aliases(list):
                Picker(title, selection: $model) {
                    ForEach(pinned(list), id: \.self) { Text(label($0)).tag($0) }
                }
            case .serverList:
                Picker(title, selection: $model) {
                    ForEach(pinned(serverModels), id: \.self) { Text($0).tag($0) }
                }
            case let .freeText(placeholder):
                TextField(title, text: $model, prompt: Text(placeholder))
                    .onSubmit { commit() }
            case .fixed:
                LabeledContent(title) { Text(provider.displayName).foregroundStyle(.secondary) }
            case .openRouterCatalog:
                EmptyView()   // never reached: the caller renders the catalog picker
            }
        }
        .onChange(of: model) { _, _ in commit() }
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
