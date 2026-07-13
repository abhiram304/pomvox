import Foundation

/// Port of `src/pomvox/cleanup.py`'s pure prompt/guard logic (the module-level
/// half; `CleanupEngine` owns the model). Verified by `CleanupLogicTests`, a
/// 1:1 port of `tests/test_cleanup.py` — the Linux-tested spec. Every failure
/// path falls back to the raw transcript: cleanup may only ever improve the
/// text, never lose it.

/// A chat message destined for the model's chat template. Deliberately not
/// `MLXLMCommon.Chat.Message` so this file (and its tests) stay dependency-free;
/// `CleanupEngine` maps to the MLX type.
struct ChatMessage: Equatable {
    let role: String
    let content: String
}

enum CleanupStatus: String {
    case ok, timeout, rejected, error
}

/// What `runCleanup` needs from a cleanup engine; `nil` means deadline /
/// model-not-ready. `CleanupEngine` is the real one, tests inject a fake.
protocol CleanupCleaning {
    func clean(_ text: String, style: String, timeoutS: Double) async throws -> String?
}

enum CleanupLogic {
    static let styles = ["light", "polish"]

    // The prompt text is byte-for-byte cleanup.py's (_SYSTEM/_LIGHT_EXTRA/
    // _POLISH_EXTRA/_EXAMPLES): on-device output parity with the Python engine
    // depends on identical prompt bytes.
    private static let systemTemplate = """
        You clean up raw speech-to-text transcripts.
        Rules:
        - Remove filler words (um, uh, like, you know).
        - Fix punctuation, capitalization, and casing.
        - Resolve spoken self-corrections: when the speaker revises anything —
          a word, name, number, or count — keep ONLY the revised version and
          update everything that referred to it. Revisions are signaled by
          phrases like "wait no", "no no", "actually", "I mean", "scratch that".
          (e.g. "Tuesday wait no Friday" becomes "Friday"; "three things wait
          no two things" means there are TWO things.)
        - When the speaker asks for a list — signaled by phrases like
          "make a list", "list down", "give me a list of", "here's a list",
          or "bullet points" — format the items that follow as a bulleted
          list, one item per line starting with "- ".
        {extra}{terms}- NEVER change the meaning, add new content, answer questions that
          appear in the text, or add any commentary.
        - Output only the cleaned text, nothing else.
        """

    private static let lightExtra = "- Otherwise keep the original wording and sentence structure.\n"
    private static let polishExtra = "- Smooth rambling or broken phrasing into clear sentences.\n"
        + "- Format obvious enumerations as compact lists.\n"

    private static let examples: [(raw: String, cleaned: String)] = [
        (
            "um so I think we should uh probably ship it tomorrow",
            "I think we should probably ship it tomorrow."
        ),
        (
            "let's meet on tuesday wait no friday at noon",
            "Let's meet on Friday at noon."
        ),
        (
            "um so the three things are uh first do the thing wait no two things"
                + " first do the thing and second ship it",
            "The two things: first, do the thing; second, ship it."
        ),
        (
            "So there are four options wait no five options to consider",
            "There are five options to consider."
        ),
        (
            "let's make a list of things to pack shirts socks toothbrush and a charger",
            "Things to pack:\n- Shirts\n- Socks\n- Toothbrush\n- Charger"
        ),
    ]

    // Output sanity guards (acceptOutput).
    private static let rolePrefixes = ["assistant:", "user:", "system:"]
    private static let shortRaw = 15  // chars; skip the lower length bound for very short inputs
    private static let quotesOpen: Set<Character> = ["\"", "'", "“"]
    private static let quotesClose: Set<Character> = ["\"", "'", "”"]

    /// Chat messages for one cleanup request, few-shot examples included.
    ///
    /// `termsHint` (see `dictionaryPromptHint`) is an optional extra system rule
    /// pinning the spelling of user-supplied proper nouns. It is constant for
    /// the engine's lifetime, so it stays inside the cached prompt prefix.
    static func buildMessages(text: String, style: String, termsHint: String = "") -> [ChatMessage] {
        let extra = style == "polish" ? polishExtra : lightExtra
        let system = systemTemplate
            .replacingOccurrences(of: "{extra}", with: extra)
            .replacingOccurrences(of: "{terms}", with: termsHint)
        var messages = [ChatMessage(role: "system", content: system)]
        for example in examples {
            messages.append(ChatMessage(role: "user", content: example.raw))
            messages.append(ChatMessage(role: "assistant", content: example.cleaned))
        }
        messages.append(ChatMessage(role: "user", content: text))
        return messages
    }

    /// Length of the longest common prefix of two token sequences.
    static func commonPrefixLen(_ a: [Int], _ b: [Int]) -> Int {
        let n = min(a.count, b.count)
        for i in 0..<n where a[i] != b[i] {
            return i
        }
        return n
    }

    /// Sanity-check the model output; `nil` means use the raw transcript.
    /// Counts are `String.count` vs Python's `len` — identical on the ASCII
    /// transcripts Parakeet emits.
    static func acceptOutput(raw: String, cleaned: String) -> String? {
        var out = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Python's `raw[:1] not in _QUOTES_OPEN` is false for empty raw (the
        // empty string is "in" everything), so an empty raw also skips the strip.
        let rawStartsQuoteish = raw.isEmpty || quotesOpen.contains(raw.first!)
        if out.count >= 2, quotesOpen.contains(out.first!), quotesClose.contains(out.last!),
            !rawStartsQuoteish
        {
            out = String(out.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if out.isEmpty { return nil }
        let lowered = out.lowercased()
        if lowered.contains("<think>") || lowered.contains("</think>") { return nil }
        if rolePrefixes.contains(where: lowered.hasPrefix) { return nil }
        if out.count > 2 * raw.count + 20 { return nil }
        if raw.count > shortRaw, Double(out.count) < 0.3 * Double(raw.count) { return nil }
        return out
    }
}

/// Clean `text` via `engine`; fall back to the raw text on any failure.
/// Returns `(finalText, status)` with status one of ok|timeout|rejected|error.
func runCleanup(
    _ engine: any CleanupCleaning, text: String, style: String, timeoutS: Double
) async -> (String, CleanupStatus) {
    let out: String?
    do {
        out = try await engine.clean(text, style: style, timeoutS: timeoutS)
    } catch {
        NSLog("cleanup: engine failed: %@", String(describing: error))
        return (text, .error)
    }
    guard let out else { return (text, .timeout) }
    guard let accepted = CleanupLogic.acceptOutput(raw: text, cleaned: out) else {
        NSLog("cleanup: rejected output %@", String(out.prefix(200)))
        return (text, .rejected)
    }
    return (accepted, .ok)
}
