import XCTest
@testable import Pomvox

final class DictionaryDocumentTests: XCTestCase {

    private let sample = DictionaryFile(
        schema: 1,
        words: ["Kubernetes", "Anthropic"],
        rules: [
            DictionaryRule(sources: ["pom box", "palm vox"], target: "Pomvox",
                           enabled: true, origin: "manual"),
            DictionaryRule(sources: ["um"], target: "", enabled: false, origin: "manual"),
        ])

    func testRoundTripIsStable() throws {
        let text = DictionaryDocument.serialize(sample)
        let parsed = try DictionaryDocument.parse(text)
        XCTAssertEqual(parsed, sample)
        // Canonical form: serializing the parse reproduces identical bytes.
        XCTAssertEqual(DictionaryDocument.serialize(parsed), text)
    }

    func testParseEmptyTextIsEmptyFile() throws {
        let f = try DictionaryDocument.parse("")
        XCTAssertEqual(f, DictionaryFile(schema: 1, words: [], rules: []))
    }

    func testParseSkipsCommentsAndBlanks() throws {
        let f = try DictionaryDocument.parse("""
        # header comment

        words = ["MLX"]   # trailing comment on the words line is NOT supported inside strings
        """)
        XCTAssertEqual(f.words, ["MLX"])
    }

    func testParseRuleBlocks() throws {
        let f = try DictionaryDocument.parse("""
        schema = 1
        words = []

        [[rule]]
        sources = ["char gpt", "chat g p t"]
        target = "ChatGPT"
        enabled = true
        origin = "variant"
        """)
        XCTAssertEqual(f.rules.count, 1)
        XCTAssertEqual(f.rules[0].sources, ["char gpt", "chat g p t"])
        XCTAssertEqual(f.rules[0].target, "ChatGPT")
        XCTAssertEqual(f.rules[0].origin, "variant")
    }

    func testRuleDefaultsWhenKeysOmitted() throws {
        let f = try DictionaryDocument.parse("""
        [[rule]]
        sources = ["a b"]
        target = "AB"
        """)
        XCTAssertTrue(f.rules[0].enabled)
        XCTAssertEqual(f.rules[0].origin, "manual")
    }

    func testEscapedQuotesAndBackslashesRoundTrip() throws {
        let file = DictionaryFile(schema: 1, words: [#"say "hi""#, #"back\slash"#], rules: [])
        let parsed = try DictionaryDocument.parse(DictionaryDocument.serialize(file))
        XCTAssertEqual(parsed.words, [#"say "hi""#, #"back\slash"#])
    }

    func testMalformedThrowsWithLineNumber() {
        XCTAssertThrowsError(try DictionaryDocument.parse("words = [oops\n")) { error in
            guard case let DictionaryParseError.malformed(line, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(line, 1)
        }
    }

    func testUnknownKeysAreIgnored() throws {
        // Forward compatibility: a Phase-2 file must not brick a Phase-1 app.
        let f = try DictionaryDocument.parse("""
        future_key = "whatever"
        [[rule]]
        sources = ["x y"]
        target = "XY"
        confidence = "high"
        """)
        XCTAssertEqual(f.rules[0].target, "XY")
    }

    func testUnknownSectionThrows() {
        XCTAssertThrowsError(try DictionaryDocument.parse("[mystery]\nkey = \"v\""))
    }

    func testNewlineAndTabInValuesRoundTrip() throws {
        let file = DictionaryFile(schema: 1, words: ["multi\nline", "tab\there"], rules: [])
        let parsed = try DictionaryDocument.parse(DictionaryDocument.serialize(file))
        XCTAssertEqual(parsed.words, ["multi\nline", "tab\there"])
    }

    func testRuleIDIsStableAndOrderInsensitive() {
        let a = DictionaryRule(sources: ["B", "a"], target: "T", enabled: true, origin: "manual")
        let b = DictionaryRule(sources: ["a", "b"], target: "t", enabled: false, origin: "history")
        XCTAssertEqual(a.id, b.id)  // identity = normalized content, not flags
    }
}
