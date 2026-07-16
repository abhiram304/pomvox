import XCTest
@testable import Pomvox

final class DictionaryInterchangeTests: XCTestCase {

    func testWordListRoundTrip() {
        let words = ["Kubernetes", "MLX", "Salammagari"]
        let text = DictionaryInterchange.wordList(words)
        XCTAssertEqual(text, "Kubernetes\nMLX\nSalammagari\n")
        XCTAssertEqual(DictionaryInterchange.parseWordList(text), words)
    }

    func testParseWordListSkipsBlanksCommentsAndTrims() {
        XCTAssertEqual(
            DictionaryInterchange.parseWordList("# my words\n  MLX  \n\nKubernetes\n"),
            ["MLX", "Kubernetes"])
    }

    func testRulesCSVRoundTrip() {
        let rules = [
            DictionaryRule(sources: ["pom box", "palm vox"], target: "Pomvox",
                           enabled: true, origin: "manual"),
            DictionaryRule(sources: ["um"], target: "", enabled: true, origin: "manual"),
        ]
        let csv = DictionaryInterchange.rulesCSV(rules)
        XCTAssertEqual(csv, "pom box|palm vox,Pomvox\num,\n")
        XCTAssertEqual(DictionaryInterchange.parseRulesCSV(csv).map(\.sources),
                       [["pom box", "palm vox"], ["um"]])
        XCTAssertEqual(DictionaryInterchange.parseRulesCSV(csv).map(\.target), ["Pomvox", ""])
    }

    func testParseRulesCSVSkipsMalformedRows() {
        // No comma at all → not a rule row; skipped, not fatal.
        let rules = DictionaryInterchange.parseRulesCSV("just words\npom box,Pomvox\n")
        XCTAssertEqual(rules.count, 1)
    }

    func testImportedRulesAreManualOriginAndEnabled() {
        let r = DictionaryInterchange.parseRulesCSV("a b,AB\n")[0]
        XCTAssertEqual(r.origin, "manual")
        XCTAssertTrue(r.enabled)
    }
}
