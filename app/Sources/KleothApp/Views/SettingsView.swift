import SwiftUI
import KleothCore
import KeyboardShortcuts

/// Settings screen: API keys (persisted to the Keychain), output directory,
/// default summarization model, and Slack webhook.
struct SettingsView: View {
    @EnvironmentObject private var controller: RecordingController

    // Local editable copies; committed to the controller (and Keychain) on change.
    @State private var elevenLabsKey: String = ""
    @State private var openRouterKey: String = ""
    @State private var slackWebhook: String = ""
    @State private var outputDirPath: String = ""
    @State private var selectedModel: String = ""

    /// A small, curated set of summarization models. The current value is
    /// always present so an externally configured model still shows.
    private var modelChoices: [String] {
        let defaults = [
            "anthropic/claude-haiku-4.5",
            "anthropic/claude-sonnet-4.5",
            "openai/gpt-4o-mini",
            "openai/gpt-4o",
            "google/gemini-2.5-flash",
        ]
        if selectedModel.isEmpty || defaults.contains(selectedModel) {
            return defaults
        }
        return [selectedModel] + defaults
    }

    var body: some View {
        Form {
            Section("Credentials") {
                SecureField("ElevenLabs API key", text: $elevenLabsKey)
                    .onSubmit { controller.updateElevenLabsKey(elevenLabsKey) }
                SecureField("OpenRouter API key (optional)", text: $openRouterKey)
                    .onSubmit { controller.updateOpenRouterKey(openRouterKey) }
                Text("Keys are stored in your macOS Keychain and never logged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                HStack {
                    TextField("Output folder", text: $outputDirPath)
                        .onSubmit { controller.updateOutputDir(outputDirPath) }
                    Button("Choose…") { chooseFolder() }
                }
            }

            Section("Summarization") {
                Picker("Default model", selection: $selectedModel) {
                    ForEach(modelChoices, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .onChange(of: selectedModel) { _, newValue in
                    controller.updateDefaultModel(newValue)
                }
            }

            Section("Slack") {
                TextField("Incoming webhook URL", text: $slackWebhook)
                    .onSubmit { controller.updateSlackWebhook(slackWebhook) }
            }

            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Start / stop recording:", name: .toggleRecording)
                Text("Also available as Shortcuts/Spotlight actions and via kleoth:// URLs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calendar") {
                if controller.calendarAuthorized {
                    Label("Meetings are named from your calendar event.", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("Name meetings from your calendar")
                        Spacer()
                        Button("Enable") { Task { await controller.requestCalendarAccess() } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 420)
        .onAppear(perform: loadFromController)
        // Commit any unsubmitted edits when the window goes away.
        .onDisappear(perform: commitAll)
    }

    // MARK: - Loading / committing

    private func loadFromController() {
        elevenLabsKey = controller.credentials.elevenLabsKey ?? ""
        openRouterKey = controller.credentials.openRouterKey ?? ""
        slackWebhook = controller.settings.slackWebhook ?? ""
        outputDirPath = controller.settings.outputDir.path
        selectedModel = controller.settings.defaultModel
    }

    private func commitAll() {
        controller.updateElevenLabsKey(elevenLabsKey)
        controller.updateOpenRouterKey(openRouterKey)
        controller.updateSlackWebhook(slackWebhook)
        controller.updateOutputDir(outputDirPath)
        controller.updateDefaultModel(selectedModel)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirPath = url.path
            controller.updateOutputDir(url.path)
        }
    }
}
