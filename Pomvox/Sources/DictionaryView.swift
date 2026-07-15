import SwiftUI

/// The Dictionary page: words the cleanup model should spell your way,
/// misheard-term fixup rules (many-to-one, per-rule toggle, hit counts), and
/// a live test box that shows exactly what the rules do to any text.
struct DictionaryView: View {
    @EnvironmentObject var store: DictionaryStore
    @State private var newWord = ""
    @State private var editorState: RuleEditorState?   // Task 10 presents the sheet
    @State private var testText = ""
    @State private var stats: [String: DictionaryRuleStats] = DictionaryStatsStore.shared.allStats()

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Dictionary") {
                if store.applyingHint {
                    Chip(text: "Applying…", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if let err = store.parseError { parseErrorBanner(err) }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    wordsSection
                    rulesSection
                    testSection
                }
                .padding(.horizontal, 34).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $editorState) { state in
            RuleEditorSheet(state: state)   // Task 10
        }
        .onReceive(NotificationCenter.default
            .publisher(for: .pomvoxDictionaryStatsDidChange)
            .receive(on: RunLoop.main)) { _ in
            stats = DictionaryStatsStore.shared.allStats()
        }
    }

    // MARK: - Sections

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Words",
                          subtitle: "Pomvox tells the cleanup model to spell these your way.")
            FlowLayout(spacing: 6) {
                ForEach(store.file.words, id: \.self) { word in
                    WordChip(word: word) { store.removeWord(word) }
                }
                TextField("Add a word…", text: $newWord)
                    .textFieldStyle(.plain).font(Typo.ui(12.5))
                    .frame(width: 120)
                    .onSubmit {
                        store.addWord(newWord)
                        newWord = ""
                    }
            }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Fixups",
                              subtitle: "When Pomvox hears the left side, it writes the right side. Always applied — even with cleanup off.")
                Spacer()
                Button {
                    editorState = RuleEditorState(editing: nil)
                } label: {
                    Chip(text: "New rule", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New fixup rule")
            }
            if store.file.rules.isEmpty {
                Text("No rules yet. Add one here, or select a mistake in History and choose “Fix this…”.")
                    .font(Typo.ui(12.5)).foregroundStyle(Palette.muted)
            }
            ForEach(store.file.rules) { rule in
                RuleRow(rule: rule, stats: stats[rule.id],
                        onToggle: { store.setRuleEnabled(id: rule.id, $0) },
                        onEdit: { editorState = RuleEditorState(editing: rule) },
                        onDelete: { store.removeRule(id: rule.id) })
            }
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Try it",
                          subtitle: "Type anything (or paste a transcript) and watch the rules apply.")
            TextField("say something pomvox would mishear…", text: $testText, axis: .vertical)
                .textFieldStyle(.plain).font(Typo.ui(13))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.pane2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hair, lineWidth: 0.5))
            if !testText.isEmpty {
                let applied = PomvoxDictionary(file: store.file).applyReporting(testText)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 11)).foregroundStyle(Palette.ember)
                    Text(applied.text.isEmpty ? "(everything removed)" : applied.text)
                        .font(Typo.ui(13)).foregroundStyle(Palette.ink)
                }
                if !applied.fired.isEmpty {
                    Text("\(applied.fired.count) rule\(applied.fired.count == 1 ? "" : "s") fired")
                        .font(Typo.ui(11)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Typo.display(17)).foregroundStyle(Palette.ink)
            Text(subtitle).font(Typo.ui(12)).foregroundStyle(Palette.muted)
        }
    }

    private func parseErrorBanner(_ err: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13)).foregroundStyle(Palette.ember)
            Text("dictionary.toml couldn’t be read — \(err). Fix the file, then reload. In-app edits are paused so your changes aren’t overwritten.")
                .font(Typo.ui(12.5)).foregroundStyle(Palette.ink)
            Spacer()
            Button("Reload") { store.reloadFromDisk() }
                .buttonStyle(.plain).font(Typo.ui(12.5, .semibold)).foregroundStyle(Palette.ember)
        }
        .padding(.horizontal, 34).padding(.vertical, 11)
        .background(Palette.emberSoft)
    }
}

/// Identifiable wrapper so `.sheet(item:)` drives the editor (Task 10 fills in
/// the sheet body; `seedSources`/`referenceTranscript` feed add-from-History).
struct RuleEditorState: Identifiable {
    let id = UUID()
    var editing: DictionaryRule?
    var seedSources: [String] = []
    var referenceTranscript: String? = nil
}

private struct WordChip: View {
    let word: String
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(word).font(Typo.ui(12.5)).foregroundStyle(Palette.ink)
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(word)")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Palette.pane2))
        .overlay(Capsule().stroke(Palette.hair, lineWidth: 0.5))
        .onHover { hovering = $0 }
    }
}

private struct RuleRow: View {
    let rule: DictionaryRule
    let stats: DictionaryRuleStats?
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: onToggle))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel("Enable rule for \(rule.target.isEmpty ? "removal" : rule.target)")
            FlowLayout(spacing: 4) {
                ForEach(rule.sources, id: \.self) { s in
                    Text(s).font(Typo.ui(12))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Palette.pane2))
                }
            }
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Palette.muted)
            if rule.target.isEmpty {
                Chip(text: "removes", systemImage: "scissors")
            } else {
                Text(rule.target).font(Typo.ui(13, .semibold)).foregroundStyle(Palette.ink)
            }
            Spacer()
            if let s = stats {
                Text("×\(s.count)").font(Typo.ui(11)).monospacedDigit().foregroundStyle(Palette.muted)
                    .help("Fired \(s.count) time\(s.count == 1 ? "" : "s"), last \(Date(timeIntervalSince1970: s.lastFired).formatted(.relative(presentation: .named)))")
            }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(Palette.muted)
                .accessibilityLabel("Edit rule")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Palette.muted)
                .accessibilityLabel("Delete rule")
        }
        .padding(.vertical, 7)
        .opacity(rule.enabled ? 1 : 0.55)
    }
}

/// Minimal wrap layout for chips (macOS 14 `Layout`).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layout(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for i in row.range {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                    proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var range: Range<Int>; var y: CGFloat; var height: CGFloat }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var start = 0, x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(Row(range: start..<i, y: y, height: rowHeight))
                y += rowHeight + spacing
                start = i; x = 0; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        rows.append(Row(range: start..<subviews.count, y: y, height: rowHeight))
        return rows
    }
}

/// Placeholder until Task 10 lands the real editor.
struct RuleEditorSheet: View {
    let state: RuleEditorState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack { Text("Rule editor (Task 10)"); Button("Close") { dismiss() } }
            .padding(30)
    }
}
