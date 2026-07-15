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

    // MARK: - v2: rules, reporting, wipe tidy-up

    private func rule(_ sources: [String], _ target: String,
                      enabled: Bool = true) -> DictionaryRule {
        DictionaryRule(sources: sources, target: target, enabled: enabled, origin: "manual")
    }

    func testManyToOneRuleAllSourcesRewrite() {
        let d = PomvoxDictionary(file: DictionaryFile(
            rules: [rule(["pom box", "palm vox"], "Pomvox")]))
        XCTAssertEqual(d.apply("try pom box and palm vox"), "try Pomvox and Pomvox")
    }

    func testDisabledRuleIsSkipped() {
        let d = PomvoxDictionary(file: DictionaryFile(
            rules: [rule(["pom box"], "Pomvox", enabled: false)]))
        XCTAssertEqual(d.apply("try pom box"), "try pom box")
    }

    func testApplyReportingNamesFiredRules() {
        let r1 = rule(["pom box"], "Pomvox")
        let r2 = rule(["never heard"], "Nope")
        let d = PomvoxDictionary(file: DictionaryFile(rules: [r1, r2]))
        let out = d.applyReporting("open pom box now")
        XCTAssertEqual(out.text, "open Pomvox now")
        XCTAssertEqual(out.fired, [r1.id])
    }

    func testApplyReportingNoMatchesFiresNothing() {
        let d = PomvoxDictionary(file: DictionaryFile(rules: [rule(["x y"], "XY")]))
        XCTAssertEqual(d.applyReporting("hello world").fired, [])
    }

    func testWordsFileInitFeedsHint() {
        let d = PomvoxDictionary(file: DictionaryFile(words: ["Pomvox"]))
        XCTAssertTrue(d.hint.contains("Pomvox"))
    }

    // The v0.1.8 rough edge: wiping a word must not strand its punctuation.
    func testWipeAbsorbsTrailingCommaAndSpace() {
        let d = PomvoxDictionary(file: DictionaryFile(rules: [rule(["um"], "")]))
        XCTAssertEqual(d.apply("well, um, yes"), "well, yes")
    }

    func testWipeAbsorbsTrailingPeriod() {
        let d = PomvoxDictionary(file: DictionaryFile(rules: [rule(["um"], "")]))
        XCTAssertEqual(d.apply("um. next thing"), "next thing")
    }

    func testWipeMidSentenceCollapsesDoubleSpace() {
        let d = PomvoxDictionary(file: DictionaryFile(rules: [rule(["um"], "")]))
        XCTAssertEqual(d.apply("I um think so"), "I think so")
    }

    func testWipeAtEndTrims() {
        let d = PomvoxDictionary(file: DictionaryFile(rules: [rule(["um"], "")]))
        XCTAssertEqual(d.apply("stop it um."), "stop it.")
    }

    func testNonWipeRuleLeavesPunctuationAlone() {
        let d = PomvoxDictionary(file: DictionaryFile(rules: [rule(["mur mur"], "Pomvox")]))
        XCTAssertEqual(d.apply("hi mur mur."), "hi Pomvox.")
    }

    func testWholeTranscriptWipeStillPossible() {
        // The wipe contract depends on this producing "" for classification.
        let d = PomvoxDictionary(file: DictionaryFile(rules: [rule(["um"], "")]))
        XCTAssertEqual(d.apply("um um um."), "")
    }
}
