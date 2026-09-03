import SwiftUI
import AppKit
import KleothCore

/// The **Dictations** scope of the History window: a day-grouped, searchable
/// sidebar of everything fn+shift ever dictated, plus a detail pane.
///
/// Deliberately a separate `NavigationSplitView` from the meetings list rather
/// than a union of the two ID types — the meetings sidebar is a Finder-like
/// surface (inline rename, multi-select trash) whose row model has nothing in
/// common with a text-only dictation record.
///
/// Reaches the controller through `@EnvironmentObject` only; `logRevision` (which
/// the controller bumps *after* the store's `append` / `delete` has returned)
/// is what re-reads the day files, so a reload always sees what's on disk.
struct DictationsListView: View {
    @EnvironmentObject private var dictation: DictationController

    /// The History window's scope, so this list can carry the same picker above
    /// its own sidebar. (The design sketched `DictationsListView()` with the
    /// picker on the meetings sidebar alone; a shared binding keeps the switch
    /// in the same place in both scopes instead of spanning the whole window.)
    @Binding var scope: HistoryScope

    @State private var entries: [DictationLogEntry] = []
    @State private var selection = Set<DictationLogEntry.ID>()
    @State private var search = ""

    /// Ids awaiting the delete confirmation. Unlike a meeting (which goes to the
    /// Trash and can be dragged back), deleting a dictation rewrites a JSON file
    /// in place — there is nothing to undo, so it asks first.
    @State private var pendingDeletion: Set<DictationLogEntry.ID>?
    /// A failed day-file rewrite, shown as an alert (there is no pill here).
    @State private var deletionError: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task { reload() }
        .onChange(of: dictation.logRevision) { _, _ in reload() }
        .confirmationDialog(
            deletionPrompt,
            isPresented: deletionDialogBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDeletion() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("Dictations aren't moved to the Trash — this rewrites the day file and can't be undone.")
        }
        .alert(
            "Couldn't delete",
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.entries) { entry in
                        DictationSidebarRow(entry: entry)
                            .tag(entry.id)
                            .listRowInsets(EdgeInsets(
                                top: KleothMetrics.spacingXS,
                                leading: KleothMetrics.spacingS,
                                bottom: KleothMetrics.spacingXS,
                                trailing: KleothMetrics.spacingS
                            ))
                    }
                }
            }
        }
        // The closure's `ids` set is authoritative — it is the full selection, or
        // just the row under the pointer when that row sits outside the
        // selection. Never read `selection` in here.
        .contextMenu(forSelectionType: DictationLogEntry.ID.self) { ids in
            contextMenuItems(for: ids)
        }
        .onDeleteCommand { requestDeletion(of: selection) }
        .searchable(text: $search, placement: .sidebar, prompt: "Search dictations")
        .navigationTitle("Dictations")
        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableCompat(
                    title: "No dictations yet",
                    systemImage: "mic",
                    message: "Hold \(DictationDefaults.hotkeyDescription) anywhere and speak. What you dictate lands here — text only, never audio."
                )
            } else if filtered.isEmpty {
                ContentUnavailableCompat(
                    title: "No matches",
                    systemImage: "magnifyingglass",
                    message: "No dictations match “\(search)”."
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { HistoryScopePicker(scope: $scope) }
    }

    @ViewBuilder
    private func contextMenuItems(for ids: Set<DictationLogEntry.ID>) -> some View {
        if !ids.isEmpty {
            if ids.count == 1, let id = ids.first, let entry = entry(for: id) {
                Button("Copy Polished") { copy(entry.displayText) }
                Button("Copy Raw") { copy(entry.rawText) }
            }
            Button("Show Day File in Finder") { revealDayFiles(for: ids) }
            Divider()
            Button(role: .destructive) {
                requestDeletion(of: ids)
            } label: {
                Label(
                    ids.count > 1 ? "Delete \(ids.count) Dictations" : "Delete Dictation",
                    systemImage: "trash"
                )
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        let selected = entries.filter { selection.contains($0.id) }
        if selected.count > 1 {
            multiSelectionState(selected)
        } else if let entry = selected.first {
            DictationDetailView(entry: entry)
                .id(entry.id)
        } else {
            ContentUnavailableCompat(
                title: "Select a dictation",
                systemImage: "text.quote",
                message: "Choose a dictation to read the polished text and what was actually heard."
            )
        }
    }

    private func multiSelectionState(_ selected: [DictationLogEntry]) -> some View {
        VStack(spacing: KleothMetrics.spacingM) {
            Image(systemName: "square.stack.3d.up")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("\(selected.count) dictations selected")
                .font(.headline)
            Text("Deleting rewrites the day files — dictations don't go to the Trash.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(role: .destructive) {
                requestDeletion(of: Set(selected.map(\.id)))
            } label: {
                Label("Delete \(selected.count) Dictations", systemImage: "trash")
            }
            .padding(.top, KleothMetrics.spacingS)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Data

    private func reload() {
        entries = dictation.loadDictations()
        let valid = Set(entries.map(\.id))
        selection = selection.intersection(valid)
        if selection.isEmpty, let first = entries.first?.id {
            selection = [first]
        }
    }

    private func entry(for id: DictationLogEntry.ID) -> DictationLogEntry? {
        entries.first { $0.id == id }
    }

    /// Newest-first already (the store returns them that way); search matches the
    /// polished text, what was actually heard, and the app it was dictated into.
    private var filtered: [DictationLogEntry] {
        guard !search.isEmpty else { return entries }
        let query = search.lowercased()
        return entries.filter {
            $0.polishedText.lowercased().contains(query)
                || $0.rawText.lowercased().contains(query)
                || ($0.appName?.lowercased().contains(query) ?? false)
        }
    }

    private var groups: [(label: String, entries: [DictationLogEntry])] {
        var result: [(String, [DictationLogEntry])] = []
        for entry in filtered {
            let label = DictationFormat.dayLabel(entry)
            if let index = result.firstIndex(where: { $0.0 == label }) {
                result[index].1.append(entry)
            } else {
                result.append((label, [entry]))
            }
        }
        return result.map { (label: $0.0, entries: $0.1) }
    }

    // MARK: - Actions

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Reveals the `<day>.json` file(s) backing the selected rows — the history
    /// is plain JSON the user owns, so Finder is a legitimate destination.
    private func revealDayFiles(for ids: Set<DictationLogEntry.ID>) {
        let store = dictation.logStore
        let urls = Set(
            ids.compactMap { entry(for: $0) }
                .compactMap { $0.date }
                .map { store.dayFileURL(named: DictationLogStore.dayFileName(for: $0)) }
        )
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    // MARK: - Deletion

    private func requestDeletion(of ids: Set<DictationLogEntry.ID>) {
        guard !ids.isEmpty else { return }
        pendingDeletion = ids
    }

    private var deletionPrompt: String {
        let count = pendingDeletion?.count ?? 0
        return count > 1 ? "Delete \(count) dictations?" : "Delete this dictation?"
    }

    private var deletionDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    /// Hops to the log-store actor and waits for it: the controller bumps
    /// `logRevision` only after the write has returned, and `onChange` then
    /// reloads from disk — so the list never shows a row the file still has.
    private func confirmDeletion() {
        guard let ids = pendingDeletion else { return }
        pendingDeletion = nil
        Task {
            do {
                try await dictation.deleteDictations(ids: ids)
            } catch {
                // `delete` walks day files one at a time, so a throw partway
                // can leave earlier days already rewritten; the controller
                // bumps `logRevision` regardless, so the list reloads to what
                // is actually on disk — but the user has to hear about it.
                deletionError = error.localizedDescription
            }
        }
    }
}

// MARK: - Row

/// One dictation in the sidebar: the first lines of what was pasted, then when /
/// where / how long, then the quality chips (language, raw fallback, clipboard).
private struct DictationSidebarRow: View {
    let entry: DictationLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.previewText)
                .font(.body.weight(.medium))
                .lineLimit(2)
                .truncationMode(.tail)

            if let metadata = DictationFormat.timeAppDuration(entry) {
                Text(metadata)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: KleothMetrics.spacingXS) {
                if let language = DictationFormat.languageLabel(entry.language) {
                    KleothPill(language)
                }
                if entry.usedRawFallback {
                    KleothPill("Raw", systemImage: "exclamationmark.triangle", tint: KleothPalette.pendingTint)
                        .help(entry.fallbackReason ?? "Pasted the transcript as heard — the clean-up pass didn't run.")
                }
                if entry.insertMethod == .clipboard {
                    KleothPill("Copied only", systemImage: "doc.on.clipboard", tint: KleothPalette.pendingTint)
                        .help("Kleoth couldn't paste into the app, so the text was left on the clipboard.")
                }
            }
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, KleothMetrics.spacingXS)
    }
}

// MARK: - Entry helpers

extension DictationLogEntry {
    /// What was actually inserted: the polished text, or the raw transcript when
    /// the polish pass fell back.
    var displayText: String {
        polishedText.isEmpty ? rawText : polishedText
    }

    /// The sidebar's one-glance preview — leading whitespace and hard line
    /// breaks collapsed so a multi-paragraph dictation still reads as a row.
    var previewText: String {
        let collapsed = displayText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? "(nothing was heard)" : collapsed
    }
}

// MARK: - Formatting

/// Date / duration / language formatting for the dictation surfaces, kept next
/// to them (the meetings equivalents live in `MeetingFormat`).
enum DictationFormat {
    /// "Today" / "Yesterday" / "September 3, 2026" — the sidebar's day sections.
    static func dayLabel(_ entry: DictationLogEntry) -> String {
        guard let date = entry.date else { return "Undated" }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// "3:14 PM · Slack · 8s", dropping whichever pieces are unknown. The
    /// detail header passes `includingApp: false` — its title IS the app.
    static func timeAppDuration(_ entry: DictationLogEntry, includingApp: Bool = true) -> String? {
        var parts: [String] = []
        if let date = entry.date {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            parts.append(formatter.string(from: date))
        }
        if includingApp, let app = entry.appName, !app.isEmpty {
            parts.append(app)
        }
        if let seconds = entry.durationSeconds, seconds > 0 {
            parts.append(duration(seconds))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "8s" / "1m 12s" — dictations are seconds long, so no hours case.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total)s" }
        return "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }

    /// Scribe's ISO-639-3 code (`"rus"`) as a human name, falling back to the
    /// uppercased code when Foundation doesn't know it. Nil when absent.
    ///
    /// Foundation names 3-letter codes directly (verified: `rus` → "Russian"),
    /// so no lookup table is needed — but it echoes the code back for some
    /// unknown inputs, which the guard below catches.
    static func languageLabel(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        if let name = Locale(identifier: "en_US").localizedString(forLanguageCode: code),
           name.lowercased() != code.lowercased() {
            return name
        }
        return code.uppercased()
    }
}
