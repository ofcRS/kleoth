import SwiftUI
import KleothCore

/// Settings → Meetings, after Summarization: meeting covers (design doc
/// `2026-09-24-meeting-illustrations.md` §3.1). The engine picker is the
/// opt-in — Off by default, because every engine spends money, plan quota or
/// GPU memory — with a live status line per engine; once an engine is picked,
/// the automatic toggle, the style and (for the HTTP engines) the image model.
/// Plain rows and one caption per engine: no artwork in Settings, and no
/// prices, since money stays in Accounts → Usage.
///
/// The four values live in `SettingsView` so `commitAll()` can flush an
/// unsubmitted model edit when the window goes away. `loadFromController()`
/// seeds them from the stored settings while this section may already be
/// mounted, and `.onChange` cannot tell that re-seed from a pick, so every
/// handler writes only a value that differs from the stored one: opening
/// Settings writes nothing.
struct SettingsCoversSection: View {
    @EnvironmentObject private var controller: RecordingController
    /// "off" or a `CoverEngine` raw value.
    @Binding var coverEngine: String
    @Binding var coverAutomatic: Bool
    /// "auto" or a `CoverStyle` raw value.
    @Binding var coverStyle: String
    /// The picked engine's stored override ("" = its default, shown as the
    /// placeholder). Local server and OpenRouter only.
    @Binding var coverModel: String

    /// The last `AppConfig.coverStatus()`; empty until the first one lands.
    @State private var status: [CoverEngine: ProviderAvailability] = [:]

    private var stored: CoverSettings { controller.settings.coverSettings }

    private var pickedEngine: CoverEngine? { CoverEngine(rawValue: coverEngine) }

    var body: some View {
        Section {
            Picker("Covers", selection: $coverEngine) {
                Text("Off").tag(CoverEngine.offValue)
                ForEach(CoverEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine.rawValue)
                }
            }
            .onChange(of: coverEngine) { oldValue, newValue in
                // A model typed for the old engine but never submitted would be
                // lost to the re-seed below, so it is written first, compared
                // trimmed as `commitAll()` does. Only on a pick (the new value
                // differs from the stored engine): on a `loadFromController()`
                // re-seed the field already holds the NEW engine's override,
                // which must never land on the old one.
                if newValue != stored.engineStorageValue,
                   let old = CoverEngine(rawValue: oldValue), old.takesModel,
                   coverModel.trimmingCharacters(in: .whitespacesAndNewlines) != (stored.models[old] ?? "") {
                    controller.updateCoverModel(coverModel, for: old)
                }
                // The model field edits the picked engine's override: show what
                // is stored for the new one (the `syncProviderModels` idiom).
                coverModel = CoverEngine(rawValue: newValue).flatMap { stored.models[$0] } ?? ""
                guard newValue != stored.engineStorageValue else { return }
                controller.updateCoverEngine(CoverEngine(rawValue: newValue))
            }
            // Keep the status lines honest while the window is open. Cheap: the
            // shared detector caches for 10 min, so this only picks up changes.
            // It rides on the always-present picker row, not the Section — a
            // `Form` should see an unmodified `Section` (the provider section's
            // idiom).
            .task {
                while !Task.isCancelled {
                    status = await AppConfig.coverStatus()
                    try? await Task.sleep(for: .seconds(5))
                }
            }

            ForEach(CoverEngine.allCases) { engine in
                LabeledContent(engine.displayName) {
                    Text(statusText(engine))
                        .foregroundStyle(isAvailable(engine) ? KleothPalette.successTint : .secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            if let engine = pickedEngine {
                // Picking an engine never resets this: `cover_automatic` is on
                // unless stored as "false", so it reads as on the first time.
                Toggle("Draw automatically after the summary", isOn: $coverAutomatic)
                    .onChange(of: coverAutomatic) { _, newValue in
                        guard newValue != stored.automatic else { return }
                        controller.updateCoverAutomatic(newValue)
                    }

                Picker("Style", selection: $coverStyle) {
                    Text("Automatic").tag("auto")
                    ForEach(CoverStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .onChange(of: coverStyle) { _, newValue in
                    guard newValue != stored.styleStorageValue else { return }
                    controller.updateCoverStyle(CoverStyle(rawValue: newValue))
                }

                if engine.takesModel {
                    // Return commits; a keystroke does not (each write is a
                    // Keychain write). `SettingsView.commitAll()` flushes an
                    // unsubmitted edit when the window closes.
                    TextField("Image model", text: $coverModel, prompt: Text(engine.defaultModel))
                        .onSubmit { controller.updateCoverModel(coverModel, for: engine) }
                }
            }
        } header: {
            Text("Covers")
        } footer: {
            captionFooter(caption)
        }
    }

    // MARK: - Status

    private func isAvailable(_ engine: CoverEngine) -> Bool {
        status[engine]?.isAvailable ?? false
    }

    /// The engine's status line; "…" until the first status lands, as the AI
    /// provider rows read while the detector is still checking.
    private func statusText(_ engine: CoverEngine) -> String {
        switch status[engine] {
        case let .available(detail, _): return detail
        case let .unavailable(reason): return reason
        case nil: return "…"
        }
    }

    // MARK: - Caption

    /// What the picked engine sees and spends, in words (spec §3.1, verbatim).
    /// Never a price: money appears only in Accounts → Usage.
    private var caption: String {
        switch pickedEngine {
        case nil:
            return "Draws one small picture per meeting from its summary, shown in History. Pick an engine to turn it on."
        case .localServer?:
            return "Drawn on this Mac by your local server. The scene is written from the summary by your summary provider."
        case .codex?:
            return "Kleoth sends Codex a one-sentence scene written from the summary — no names, quotes or transcript. About a minute per cover; it uses your ChatGPT plan's limits."
        case .openRouter?:
            return "Kleoth sends OpenRouter a one-sentence scene written from the summary — no names, quotes or transcript. Each cover is billed to your OpenRouter account (Accounts → Usage)."
        }
    }

    /// The standard quiet footer caption used under each Settings section.
    /// Duplicated from `SettingsView` on purpose, as the other section files
    /// do: that one is `private` to its own type.
    private func captionFooter(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, KleothMetrics.spacingXS)
    }
}
