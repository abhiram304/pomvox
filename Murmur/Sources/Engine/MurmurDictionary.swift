import Foundation

/// Port of `src/murmur/dictionary.py` — the user dictionary, Phase 4. Two
/// independent, pure-logic mechanisms (vector-parity tested against
/// `tests/test_dictionary.py`):
///
/// - `dictionaryPromptHint` injects proper nouns / jargon into the cleanup
///   system prompt so the LLM prefers the user's spelling. Constant for the
///   engine's lifetime, so it rides inside the cached prompt prefix and costs
///   nothing per utterance (changing it is re-arm/restart-required).
/// - `substitute` runs literal post-replacements on the final text, so a term
///   the STT model reliably mishears is fixed even when cleanup is off, times
///   out, or its output is rejected — the robust path, never model-dependent.
///   Like every stage it only rewrites; it can fix or re-case a term but never
///   drops the surrounding words.

/// A cleanup-prompt rule pinning the spelling of *words*; "" if none.
func dictionaryPromptHint(_ words: [String]) -> String {
    let terms = words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !terms.isEmpty else { return "" }
    return "- Keep these terms spelled exactly as written when you hear them "
        + "(match phonetically, fix the spelling): " + terms.joined(separator: ", ") + ".\n"
}

/// Pre-compile (misheard → correct) pairs for `substitute`. Longest source
/// first so a multi-word phrase wins over a shorter key it contains;
/// whole-word, case-insensitive so "para" never rewrites inside "apparatus".
/// An empty source is skipped — it would match everywhere.
func compileReplacements(_ pairs: [(String, String)]) -> [(NSRegularExpression, String)] {
    var compiled: [(NSRegularExpression, String)] = []
    for (src, repl) in pairs.sorted(by: { $0.0.count > $1.0.count }) {
        let stripped = src.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else {
            NSLog("dictionary: ignoring empty replacement key")
            continue
        }
        let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: stripped) + "(?!\\w)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else {
            NSLog("dictionary: bad replacement pattern for %@", stripped)
            continue
        }
        compiled.append((re, repl))
    }
    return compiled
}

/// Apply pre-compiled replacements to *text*, left to right.
func substitute(_ text: String, _ compiled: [(NSRegularExpression, String)]) -> String {
    var out = text
    for (re, repl) in compiled {
        let range = NSRange(out.startIndex..., in: out)
        // An escaped template treats the value literally — a "$1"/"\1"/"&" in a
        // corrected spelling must not be read as a backreference.
        out = re.stringByReplacingMatches(
            in: out, options: [], range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: repl))
    }
    return out
}

/// The user dictionary, built once from config and read per utterance. `hint`
/// is handed to the cleanup engine at arm (it becomes part of the cached prompt
/// prefix); `apply` runs on the final text just before insertion.
struct MurmurDictionary {
    let hint: String
    private let compiled: [(NSRegularExpression, String)]
    private let enabled: Bool

    init(words: [String], replacements: [(String, String)], enabled: Bool = true) {
        self.enabled = enabled
        self.hint = enabled ? dictionaryPromptHint(words) : ""
        self.compiled = enabled ? compileReplacements(replacements) : []
        if enabled, !self.hint.isEmpty || !self.compiled.isEmpty {
            let termCount = words.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            NSLog("dictionary: %d term(s), %d replacement(s)", termCount, self.compiled.count)
        }
    }

    func apply(_ text: String) -> String {
        guard enabled, !text.isEmpty, !compiled.isEmpty else { return text }
        return substitute(text, compiled)
    }
}
