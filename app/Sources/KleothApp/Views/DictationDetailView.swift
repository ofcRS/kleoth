import SwiftUI
import AppKit
import KleothCore

/// The detail pane for one dictation: where it went, what was pasted, and — one
/// disclosure away — what Scribe actually heard before the polish pass.
///
/// Read-only by design. The row is a record of something that already landed in
/// another app; the only actions are copying it out.
struct DictationDetailView: View {
    let entry: DictationLogEntry

    /// "Copy" → "Copied!" for 1.5 s, cancel-and-restart so rapid copies keep the
    /// checkmark a full beat from the most recent one (same idiom as
    /// `MeetingDetailView`).
    @State private var copied = false
    @State private var copiedResetTask: Task<Void, Never>?

    @State private var showsRaw = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KleothMetrics.spacingL) {
                header
                polished
                raw
            }
            .padding(KleothMetrics.spacingL)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Dictation")
        .toolbar { copyMenu }
        .onDisappear {
            copiedResetTask?.cancel()
            copied = false
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: KleothMetrics.spacingM) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
                Text(entry.appName ?? "Dictation")
                    .font(.headline)
                // The app name is already the title above; repeating it here
                // (next to the app's icon) would print it three times over.
                if let subtitle = DictationFormat.timeAppDuration(entry, includingApp: false) {
                    Text(subtitle)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                // Product voice, not engine slugs (the same rule as the meeting
                // tier badges — "On-device"/"Cloud", never "Local"/"SOTA"); the
                // exact model hangs off the tooltip for the curious.
                KleothFlowLayout(spacing: KleothMetrics.spacingXS) {
                    if let language = DictationFormat.languageLabel(entry.language) {
                        KleothPill(language, systemImage: "character.bubble")
                    }
                    if let model = entry.transcriptionModel, !model.isEmpty {
                        KleothPill("Cloud transcription", systemImage: "waveform")
                            .help("Transcribed with \(model)")
                    }
                    if !entry.usedRawFallback, let model = entry.polishModel, !model.isEmpty {
                        KleothPill("Cleaned up", systemImage: "sparkles")
                            .help("Polished with \(model)")
                    }
                    if entry.usedRawFallback {
                        KleothPill("Raw", systemImage: "exclamationmark.triangle", tint: KleothPalette.pendingTint)
                    }
                    if let reason = skippedReason {
                        KleothPill("As heard", systemImage: "waveform.badge.checkmark")
                            .help(reason)
                    }
                    if entry.insertMethod == .clipboard {
                        KleothPill("Copied only", systemImage: "doc.on.clipboard", tint: KleothPalette.pendingTint)
                    }
                }
                if entry.usedRawFallback, let reason = entry.fallbackReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .kleothCard()
    }

    /// Why the clean-up pass was deliberately skipped for this row — a
    /// messenger target or a short utterance (`PolishGate`). Recomputed from
    /// the stored fields (the row carries no reason of its own); nil for rows
    /// that were polished or fell back.
    private var skippedReason: String? {
        guard !entry.usedRawFallback, (entry.polishModel ?? "").isEmpty else { return nil }
        let decision = PolishGate.decide(
            rawText: entry.rawText,
            style: AppStyle.classify(bundleId: entry.appBundleId),
            alwaysPolish: false
        )
        if case let .skip(reason) = decision { return reason }
        return "Pasted as heard — the clean-up pass didn't run."
    }

    /// The icon of the app the text was dictated into, when that app is still
    /// installed. Purely decorative — a missing icon just drops the column.
    private var appIcon: NSImage? {
        guard let bundleId = entry.appBundleId, !bundleId.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Text

    private var polished: some View {
        VStack(alignment: .leading, spacing: KleothMetrics.spacingS) {
            KleothSectionHeader("Polished", systemImage: "sparkles")
            Text(entry.displayText.isEmpty ? "(nothing was heard)" : entry.displayText)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var raw: some View {
        // Nothing to disclose when the polish pass fell back — the two texts are
        // then the same string.
        if !entry.rawText.isEmpty, entry.rawText != entry.displayText {
            DisclosureGroup("Raw transcript", isExpanded: $showsRaw) {
                Text(entry.rawText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, KleothMetrics.spacingXS)
            }
            .font(.callout.weight(.medium))
        }
    }

    // MARK: - Toolbar

    private var copyMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Copy Polished") { copy(entry.displayText) }
                Button("Copy Raw") { copy(entry.rawText) }
            } label: {
                Label(
                    copied ? "Copied!" : "Copy",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
            }
            .disabled(entry.rawText.isEmpty && entry.polishedText.isEmpty)
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        flashCopied()
    }

    private func flashCopied() {
        copiedResetTask?.cancel()
        copied = true
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
