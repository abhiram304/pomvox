import Foundation
import SwiftUI

/// The single writer of `~/.pomvox/dictionary.toml`. Every mutation saves
/// atomically and posts `.pomvoxDictionaryDidChange`, which the engine picks
/// up to hot-reload (NativeEngine.reloadDictionary). On first launch with no
/// dictionary.toml this migrates the legacy `[dictionary]` section out of
/// config.toml into the new file (read-only on config.toml — the old section
/// simply becomes dormant).
///
/// A malformed hand-edited file is surfaced via `parseError` and BLOCKS
/// in-app edits (saving would clobber whatever the user was hand-writing);
/// the page shows the error + a "Reload" button for after they fix it.
@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var file = DictionaryFile()
    @Published private(set) var parseError: String?
    /// True from a words-affecting save until the engine posts
    /// `.pomvoxDictionaryHintApplied` (the "applying…" chip on the page).
    @Published private(set) var applyingHint = false

    let path: String
    let configPath: String

    init(path: String = DictionaryPaths.dictionaryPath(),
         configPath: String = SettingsModel.defaultPath()) {
        self.path = path
        self.configPath = configPath
        NotificationCenter.default.addObserver(
            forName: .pomvoxDictionaryHintApplied, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyingHint = false }
        }
        reloadFromDisk()
        migrateLegacyIfNeeded()
    }

    func reloadFromDisk() {
        let r = DictionaryLoader.load(configPath: configPath, dictionaryPath: path)
        parseError = r.parseError
        if r.parseError == nil { file = r.file }
    }

    /// First run with no dictionary.toml: persist the legacy section so the
    /// page has a real file to edit. config.toml is never written.
    private func migrateLegacyIfNeeded() {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let legacy = DictionaryLoader.legacyFile(configPath: configPath)
        guard !legacy.words.isEmpty || !legacy.rules.isEmpty else { return }
        file = legacy
        save()
        NSLog("dictionary: migrated %d word(s), %d rule(s) from config.toml",
              legacy.words.count, legacy.rules.count)
    }

    // MARK: - Words

    func addWord(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty, !file.words.contains(w) else { return }
        file.words.append(w)
        save(wordsChanged: true)
    }

    func removeWord(_ word: String) {
        guard let i = file.words.firstIndex(of: word) else { return }
        file.words.remove(at: i)
        save(wordsChanged: true)
    }

    // MARK: - Rules

    /// Insert or replace a rule. `replacingID` is the pre-edit id when editing
    /// (content edits change the content-derived id, so we can't match on the
    /// new one). Sources are trimmed/deduped; a rule with no sources is a
    /// delete.
    func upsert(_ rule: DictionaryRule, replacingID: String?) {
        var r = rule
        var seen = Set<String>()
        r.sources = r.sources
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        r.target = r.target.trimmingCharacters(in: .whitespaces)
        if let old = replacingID, let i = file.rules.firstIndex(where: { $0.id == old }) {
            if r.sources.isEmpty { file.rules.remove(at: i) } else { file.rules[i] = r }
        } else if !r.sources.isEmpty, !file.rules.contains(where: { $0.id == r.id }) {
            file.rules.append(r)
        }
        save()
    }

    func removeRule(id: String) {
        file.rules.removeAll { $0.id == id }
        save()
    }

    func setRuleEnabled(id: String, _ enabled: Bool) {
        guard let i = file.rules.firstIndex(where: { $0.id == id }) else { return }
        file.rules[i].enabled = enabled
        save()
    }

    // MARK: - Save

    private func save(wordsChanged: Bool = false) {
        guard parseError == nil else { return }   // never clobber a hand-edit mid-fix
        let dirPath = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dirPath, withIntermediateDirectories: true)
        do {
            try DictionaryDocument.serialize(file)
                .write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            NSLog("dictionary: save failed: %@", String(describing: error))
            return
        }
        if wordsChanged { applyingHint = true }
        NotificationCenter.default.post(name: .pomvoxDictionaryDidChange, object: nil)
    }
}
