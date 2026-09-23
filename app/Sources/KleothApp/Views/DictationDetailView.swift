import SwiftUI
import AppKit
import KleothCore

/// The detail pane for one dictation: where it went, what was pasted, and — one
/// disclosure away — what Scribe actually heard before the polish pass.
///
/// Read-only for a transcribed row: it is a record of something that already
/// landed in another app, and the only actions are copying it out. A PENDING
/// row (the transcription failed or was stopped; its audio is kept) gets the
/// one thing it needs instead: try again, in the cloud or on this Mac, with
/// the text copied to the clipboard when it is ready (dictation-retry design
/// §3.4).
struct DictationDetailView: View {
    let entry: DictationLogEntry

    @EnvironmentObject private var dictation: DictationController

    /// How this pane's last "Try again" ended. `.copied` outlives the row's
    /// switch to its transcribed layout (the view keeps its identity — the
    /// list tags it by the row id), which is where the note is shown.
    @State private var runNote: RunNote?

    private enum RunNote: Equatable {
        case copied
        case failed(String)
    }

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
                if entry.isPending {
                    pendingPanel
                } else {
                    polished
                    raw
                }
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
                    if entry.isPending {
                        KleothPill("Audio saved", systemImage: "exclamationmark.arrow.circlepath", tint: KleothPalette.pendingTint)
                    }
                    if let language = DictationFormat.languageLabel(entry.language) {
                        KleothPill(language, systemImage: "character.bubble")
                    }
                    if let model = entry.transcriptionModel, !model.isEmpty {
                        let engine = DictationFormat.transcriptionLabel(model)
                        KleothPill(engine.title, systemImage: engine.systemImage)
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
                if runNote == .copied, !entry.isPending {
                    Label("Copied to the clipboard.", systemImage: "doc.on.clipboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        // A pending row has no text to have skipped anything on.
        guard !entry.isPending, !entry.usedRawFallback, (entry.polishModel ?? "").isEmpty else { return nil }
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

    // MARK: - Pending (not transcribed yet)

    /// Why the row has no text, and the way out: try again in the cloud or
    /// on this Mac. A "Transcribing…" row replaces the buttons while this row
    /// runs — from here or from the pill's Retry.
    @ViewBuilder
    private var pendingPanel: some View {
        let audio = dictation.keptAudioURL(for: entry)
        let isBusy = dictation.busyPendingIds.contains(entry.id)
        VStack(alignment: .leading, spacing: KleothMetrics.spacingM) {
            pendingCard(audioMissing: audio == nil)
            if isBusy {
                transcribingRow
            } else if audio != nil {
                retryButtons
                Text("The text is copied to the clipboard when it's ready. Kleoth keeps the audio until then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A refusal the row itself doesn't record (no key, already
            // running); a failed transcription is already the card's reason.
            if !isBusy, case .failed(let reason) = runNote, reason != entry.transcriptionError {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(KleothPalette.failureTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let audio {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([audio])
                } label: {
                    Label("Show Audio in Finder", systemImage: "folder")
                }
                .buttonStyle(.link)
            }
        }
    }

    /// Same shape as the recordings viewer's failure card, in the pending
    /// tint: nothing was lost, the audio is right here.
    private func pendingCard(audioMissing: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: KleothMetrics.spacingS) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .foregroundStyle(KleothPalette.pendingTint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: KleothMetrics.spacingXS) {
                Text("Not transcribed")
                    .font(.callout.weight(.semibold))
                Text(entry.transcriptionError ?? "The transcription didn't finish.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if audioMissing {
                    Text("The saved audio is gone, so this dictation can't be transcribed again. Delete it to clear the row.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(KleothMetrics.spacingM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            KleothPalette.pendingTint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: KleothMetrics.cornerRadiusCard, style: .continuous)
                .strokeBorder(KleothPalette.pendingTint.opacity(0.25), lineWidth: KleothMetrics.hairline)
        )
    }

    /// The two engines, worded the way the recordings viewer words a retry.
    /// The cloud comes first: it is what a dictation normally uses.
    private var retryButtons: some View {
        HStack(spacing: KleothMetrics.spacingS) {
            Button {
                transcribe(onDevice: false)
            } label: {
                Label("Try again in cloud", systemImage: "cloud")
                    .padding(.horizontal, KleothMetrics.spacingS)
            }
            .kleothProminentButton()
            .controlSize(.large)
            .help("Send the saved audio to ElevenLabs Scribe again.")

            Button {
                transcribe(onDevice: true)
            } label: {
                Label("Try again on device", systemImage: "desktopcomputer")
                    .padding(.horizontal, KleothMetrics.spacingS)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Transcribe with the free on-device engine — the audio stays on this Mac. The first run downloads the model (about 600 MB).")
        }
    }

    private var transcribingRow: some View {
        HStack(spacing: KleothMetrics.spacingS) {
            ProgressView().controlSize(.small)
            Text("Transcribing…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .kleothCard(padding: KleothMetrics.spacingM)
        .accessibilityElement(children: .combine)
    }

    /// A background run (no pill); the controller files the result and bumps
    /// `logRevision`, and the list hands this pane the filled-in row.
    private func transcribe(onDevice: Bool) {
        runNote = nil
        let id = entry.id
        Task {
            switch await dictation.transcribePending(id: id, onDevice: onDevice) {
            case .copied:
                runNote = .copied
            case .failed(let reason):
                runNote = .failed(reason)
            }
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
