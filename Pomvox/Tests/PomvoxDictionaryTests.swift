import XCTest
@testable import Pomvox

/// Port spec: tests/test_dictionary.py — the native dictionary must reproduce
/// the Python pure-logic vectors exactly (the prompt hint feeds the cleanup
/// prefix; the post-replacements run after cleanup, before paste).
final class PomvoxDictionaryTests: XCTestCase {

    private func sub(_ text: String, _ pairs: [(String, String)]) -> String {
        substitute(text, compileReplacements(pairs))
    }

    // MARK: - promptHint

    func testPromptHintListsTerms() {
        let hint = dictionaryPromptHint(["Salammagari", "parakeet-mlx"])
        XCTAssertTrue(hint.contains("Salammagari"))
        XCTAssertTrue(hint.contains("parakeet-mlx"))
        XCTAssertTrue(hint.hasSuffix("\n"))  // drops cleanly into the rule list
    }

    func testPromptHintEmptyWhenNoTerms() {
        XCTAssertEqual(dictionaryPromptHint([]), "")
        XCTAssertEqual(dictionaryPromptHint(["", "   "]), "")
    }

    func testPromptHintStripsAndSkipsBlanks() {
        let hint = dictionaryPromptHint(["  MLX  ", "", "Pomvox"])
        XCTAssertTrue(hint.contains("MLX, Pomvox"))
    }

    /// Byte-for-byte parity with prompt_hint — the prefix cache depends on it.
    func testPromptHintExactBytes() {
        XCTAssertEqual(
            dictionaryPromptHint(["Pomvox"]),
            "- Keep these terms spelled exactly as written when you hear them "
                + "(match phonetically, fix the spelling): Pomvox.\n")
    }

    // MARK: - substitute

    func testSubstituteBasicReplacement() {
        XCTAssertEqual(sub("i love para keet", [("para keet", "parakeet")]), "i love parakeet")
    }

    func testSubstituteCaseInsensitiveKeepsReplacementCasing() {
        XCTAssertEqual(
            sub("Salam Mcgarry shipped it", [("salam mcgarry", "Salammagari")]),
            "Salammagari shipped it")
    }

    func testSubstituteWholeWordOnly() {
        XCTAssertEqual(sub("the apparatus", [("para", "PARA")]), "the apparatus")
        XCTAssertEqual(sub("para and more", [("para", "PARA")]), "PARA and more")
    }

    func testSubstituteLongestKeyWins() {
        let out = sub("new york city is big",
                      [("new york", "NYC"), ("new york city", "NYC proper")])
        XCTAssertEqual(out, "NYC proper is big")
    }

    func testSubstituteTreatsValueLiterally() {
        // A "$1"/"\1"/"&" in the replacement is not a backreference.
        XCTAssertEqual(sub("ref one", [("ref one", #"\1 & co"#)]), #"\1 & co"#)
        XCTAssertEqual(sub("dollar", [("dollar", "$0 paid")]), "$0 paid")
    }

    func testSubstituteHandlesRegexSpecialSource() {
        XCTAssertEqual(sub("c++ rocks", [("c++", "C-plus-plus")]), "C-plus-plus rocks")
    }

    func testCompileReplacementsSkipsEmptyKey() {
        let compiled = compileReplacements([("", "x"), ("ok", "OK")])
        XCTAssertEqual(compiled.count, 1)
    }

    // MARK: - PomvoxDictionary

    func testDictionaryAppliesReplacementsAndExposesHint() {
        let d = PomvoxDictionary(words: ["Pomvox"], replacements: [("mur mur", "Pomvox")])
        XCTAssertTrue(d.hint.contains("Pomvox"))
        XCTAssertEqual(d.apply("open mur mur now"), "open Pomvox now")
    }

    func testDictionaryDisabledIsPassthrough() {
        let d = PomvoxDictionary(words: ["Pomvox"], replacements: [("mur mur", "Pomvox")],
                                 enabled: false)
        XCTAssertEqual(d.hint, "")
        XCTAssertEqual(d.apply("open mur mur now"), "open mur mur now")
    }

    func testDictionaryEmptyTextPassthrough() {
        let d = PomvoxDictionary(words: [], replacements: [("a", "b")])
        XCTAssertEqual(d.apply(""), "")
    }

    func testDictionaryNoReplacementsReturnsTextUnchanged() {
        let d = PomvoxDictionary(words: ["Pomvox"], replacements: [])
        XCTAssertEqual(d.apply("nothing to change here"), "nothing to change here")
    }
}
