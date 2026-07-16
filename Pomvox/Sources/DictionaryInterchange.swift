import Foundation

/// Plain-text import/export: one word per line for the words list, and
/// `source1|source2,target` per line for rules (the last comma splits sources
/// from target, so sources may contain commas only if the target doesn't —
/// keep it simple; targets are words/phrases, not prose). `#` comments and
/// blank lines are skipped. Import is merge-with-dedupe (the store's
/// addWord/upsert already dedupe), never a destructive replace.
enum DictionaryInterchange {

    static func parseWordList(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func wordList(_ words: [String]) -> String {
        words.map { $0 + "\n" }.joined()
    }

    static func parseRulesCSV(_ text: String) -> [DictionaryRule] {
        text.components(separatedBy: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"),
                  let comma = t.lastIndex(of: ",") else { return nil }
            let sources = String(t[..<comma]).components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let target = String(t[t.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            guard !sources.isEmpty else { return nil }
            return DictionaryRule(sources: sources, target: target,
                                  enabled: true, origin: "manual")
        }
    }

    static func rulesCSV(_ rules: [DictionaryRule]) -> String {
        rules.map { $0.sources.joined(separator: "|") + "," + $0.target + "\n" }.joined()
    }
}
