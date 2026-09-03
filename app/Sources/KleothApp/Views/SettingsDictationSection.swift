import SwiftUI
import AppKit
import KleothCore

/// Settings → Dictation: the opt-in toggle, the Accessibility gate, the polish
/// model, and the personal dictionary.
///
/// Reaches the controller through `@EnvironmentObject` only — never
/// `DictationController.shared`. Reading a `@Published` through a plain static
/// does not subscribe the view, so the live trust state would never refresh.
///
/// The model slug and the dictionary text are owned by `SettingsView` (passed
/// in as bindings) so its `commitAll()` can flush unsubmitted edits when the
/// window goes away, exactly like the keys and the output folder.
struct SettingsDictationSection: View {
    @EnvironmentObject private var dictation: DictationController

    /// The polish model slug, mirrored in `SettingsView` so `commitAll()` and
    /// the catalog refresh (`keepingAll:`) both see it.
    @Binding var dictationModel: String
    /// The dictionary editor's text, one term per line.
    @Binding var dictionaryText: String
    /// The shared, filtered OpenRouter catalog. Already pinned to keep both the
    /// summary default and `dictationModel`, so neither can vanish.
    let availableModels: [String]

    /// Debounce for the dictionary editor — writing the file on every keystroke
    /// would rewrite `~/.config/kleoth/dictionary.json` a hundred times a line.
    @State private var dictionarySaveTask: Task<Void, Never>?

    var body: some View {
        Section {
            Toggle("Enable hold-to-talk dictation", isOn: enabledBinding)
                // Trust can be granted (or revoked) in System Settings while this
                // window is open and macOS posts no notification for it, so poll
                // gently. It rides on the always-present toggle row rather than the
                // Section itself (a `Form` should see an unmodified `Section`), and
                // `.task` cancels the loop when the row goes away.
                .task {
                    while !Task.isCancelled {
                        dictation.refreshTrust()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }

            LabeledContent("Shortcut") {
                Text(DictationDefaults.hotkeyDescription)
                    .monospaced()
            }
            .help("Hold fn+shift and speak. Double-tap for hands-free; tap once to stop. Needs Apple's built-in keyboard — fn is a hardware signal.")

            accessibilityRow

            if showsGlobeKeyHint {
                globeKeyHint
            }

            Picker("Polish model", selection: $dictationModel) {
                ForEach(pickerModels, id: \.self) { model in
                    Text(modelLabel(model)).tag(model)
                }
            }
            .onChange(of: dictationModel) { _, newValue in
                dictation.setDictationModel(newValue)
            }

            dictionaryEditor

            Button("Reset pill position") { dictation.resetPillPosition() }
        } header: {
            KleothSectionHeader("Dictation", systemImage: "mic.and.signal.meter")
        } footer: {
            captionFooter("Hold fn+shift anywhere and speak; release and Kleoth pastes polished text into the app you're in. Double-tap to keep it listening hands-free. Audio is uploaded to ElevenLabs to transcribe and the text to OpenRouter to clean up — the audio is deleted right after, and only the text is kept in ~/Kleoth/dictations.")
        }
    }

    // MARK: - Toggle

    /// Turning the toggle ON *is* the intent to grant Accessibility, so the
    /// controller is allowed to fire the system prompt from here.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { dictation.isEnabled },
            set: { dictation.setEnabled($0) }
        )
    }

    // MARK: - Accessibility

    @ViewBuilder
    private var accessibilityRow: some View {
        if dictation.isTrusted {
            Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(KleothPalette.successTint)
                .labelStyle(.titleAndIcon)
        } else {
            VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
                HStack(spacing: KleothMetrics.spacingS) {
                    Text("Kleoth needs Accessibility access to hear the shortcut and paste.")
                        .font(.callout)
                    Spacer(minLength: KleothMetrics.spacingM)
                    Button("Grant…") { dictation.requestAccessibility() }
                    Button("Open System Settings") { AccessibilityPermission.openSystemSettings() }
                }
                Text("If the shortcut stays silent after granting, relaunch Kleoth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Globe key

    /// macOS maps the fn/🌐 key to the emoji picker or system dictation by
    /// default, which swallows the chord. `AppleFnUsageType` is 0 only when the
    /// user has already set "Do Nothing"; absent means the default is in force.
    private var showsGlobeKeyHint: Bool {
        guard let value = UserDefaults.standard.object(forKey: "AppleFnUsageType") as? Int else {
            return true
        }
        return value != 0
    }

    private var globeKeyHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: KleothMetrics.spacingS) {
            Image(systemName: "globe")
                .foregroundStyle(KleothPalette.pendingTint)
            Text("If pressing fn opens the emoji picker or dictation, set *Press 🌐 key to → Do Nothing*.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: KleothMetrics.spacingS)
            Button("Keyboard Settings…") { openKeyboardSettings() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Personal dictionary

    private var dictionaryEditor: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
            Text("Personal dictionary")
                .font(.callout)
            TextEditor(text: $dictionaryText)
                .font(.callout.monospaced())
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(KleothMetrics.spacingXS)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusControl, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusControl, style: .continuous)
                        .strokeBorder(KleothPalette.hairlineStroke, lineWidth: KleothMetrics.hairline)
                )
            Text(dictionaryCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, KleothMetrics.spacingXS)
        .onChange(of: dictionaryText) { _, newValue in
            scheduleDictionarySave(newValue)
        }
    }

    private var dictionaryCaption: String {
        let count = PersonalDictionaryStore.parse(text: dictionaryText).count
        let terms = count == 1 ? "1 term" : "\(count) terms"
        // The cap is enforced by the sanitizer (`Keyterms.sanitize`), never by
        // this string — so the number is read from the same constant. No
        // figures here: Settings → Usage is the app's only money surface.
        return "\(terms) · biases recognition toward your names and jargon. One per line. The first \(Keyterms.maxTerms) are sent with each dictation, which makes it cost slightly more."
    }

    /// Cancel-and-restart debounce: the file is written 0.5 s after the last
    /// keystroke. `SettingsView.commitAll()` flushes whatever is pending when
    /// the window closes, so nothing is lost if the user quits mid-edit.
    private func scheduleDictionarySave(_ text: String) {
        dictionarySaveTask?.cancel()
        dictionarySaveTask = Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            dictation.saveDictionaryTerms(PersonalDictionaryStore.parse(text: text))
        }
    }

    // MARK: - Model picker

    /// The catalog, guaranteed to contain the current selection even if a
    /// refresh hasn't landed yet (an empty picker would silently reset it).
    private var pickerModels: [String] {
        availableModels.contains(dictationModel) ? availableModels : [dictationModel] + availableModels
    }

    private func modelLabel(_ slug: String) -> String {
        slug == DictationDefaults.polishModel ? "\(slug)  (default)" : slug
    }

    private func captionFooter(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, KleothMetrics.spacingXS)
    }
}
