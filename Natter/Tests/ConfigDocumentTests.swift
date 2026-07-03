import XCTest
@testable import Natter

/// The surgical TOML editor is the acceptance-critical piece of M2: the Hub
/// must rewrite only the UI-owned keys it changes and leave every other byte —
/// hand-added comments, unknown sections, blank lines, formatting — untouched.
/// A full parse-and-reserialize (e.g. toml++) drops comments; this editor
/// can't, because it never rewrites a line it didn't change.
final class ConfigDocumentTests: XCTestCase {

    func testRoundTripIsByteIdentical() {
        let text = """
            # Natter configuration — hand-edited.
            [cleanup]
            enabled = true
            style = "polish"   # smooths rambles

            [experimental]
            secret_flag = 42
            """
        let doc = ConfigDocument(text: text)
        XCTAssertEqual(doc.render(), text)
    }

    func testEditingOneValueLeavesEverythingElseByteForByte() {
        let text = """
            # keep me
            [cleanup]
            style = "polish"   # inline note

            [experimental]
            unknown_key = "leave alone"
            """
        var doc = ConfigDocument(text: text)
        doc.set("cleanup", "style", string: "light")

        let expected = """
            # keep me
            [cleanup]
            style = "light"   # inline note

            [experimental]
            unknown_key = "leave alone"
            """
        XCTAssertEqual(doc.render(), expected)
    }

    func testSetTypedValues() {
        var doc = ConfigDocument(text: "[vad]\nsilence_ms = 2000\nenergy_gate_dbfs = -45.0\nenabled = true\n")
        doc.set("vad", "silence_ms", int: 800)
        doc.set("vad", "energy_gate_dbfs", double: -50.0)
        doc.set("vad", "enabled", bool: false)
        XCTAssertEqual(doc.int("vad", "silence_ms"), 800)
        XCTAssertEqual(doc.double("vad", "energy_gate_dbfs"), -50.0)
        XCTAssertEqual(doc.bool("vad", "enabled"), false)
        // floats must keep a decimal point so tomllib reads a float, not an int
        XCTAssertTrue(doc.render().contains("energy_gate_dbfs = -50.0"))
    }

    func testAppendsKeyWhenMissingInExistingSection() {
        var doc = ConfigDocument(text: "[audio]\n# pick a mic\n")
        doc.set("audio", "device", string: "USB Mic")
        XCTAssertEqual(doc.string("audio", "device"), "USB Mic")
        // existing comment preserved, key added under the section
        XCTAssertTrue(doc.render().contains("# pick a mic"))
        XCTAssertTrue(doc.render().contains("device = \"USB Mic\""))
    }

    func testAppendsSectionWhenMissing() {
        var doc = ConfigDocument(text: "[cleanup]\nstyle = \"polish\"\n")
        doc.set("audio", "device", string: "BlackHole 2ch")
        XCTAssertEqual(doc.string("audio", "device"), "BlackHole 2ch")
        XCTAssertEqual(doc.string("cleanup", "style"), "polish")
    }

    func testGetReturnsNilForAbsentKeyOrSection() {
        let doc = ConfigDocument(text: "[cleanup]\nstyle = \"polish\"\n")
        XCTAssertNil(doc.string("cleanup", "model"))
        XCTAssertNil(doc.string("nope", "key"))
        XCTAssertNil(doc.bool("cleanup", "style"))   // not a bool
    }

    func testStringValuesWithSlashesAndSpacesRoundTrip() {
        var doc = ConfigDocument(text: "[stt]\nmodel = \"mlx-community/parakeet-tdt-0.6b-v3\"\n")
        XCTAssertEqual(doc.string("stt", "model"), "mlx-community/parakeet-tdt-0.6b-v3")
        doc.set("stt", "model", string: "my-org/Custom Model v2")
        XCTAssertEqual(doc.string("stt", "model"), "my-org/Custom Model v2")
        XCTAssertTrue(doc.render().contains("model = \"my-org/Custom Model v2\""))
    }

    func testEmptyDocumentBuildsValidToml() {
        var doc = ConfigDocument(text: "")
        doc.set("cleanup", "style", string: "light")
        XCTAssertEqual(doc.string("cleanup", "style"), "light")
        XCTAssertTrue(doc.render().contains("[cleanup]"))
    }

    func testFinalNewlinePreservedBothWays() {
        XCTAssertEqual(ConfigDocument(text: "[a]\nx = 1\n").render(), "[a]\nx = 1\n")
        XCTAssertEqual(ConfigDocument(text: "[a]\nx = 1").render(), "[a]\nx = 1")
    }

    func testDottedAndArrayHeadersArePreservedNotMisread() {
        // We never write these, but they must survive verbatim.
        let text = "[[products]]\nname = \"x\"\n\n[tool.black]\nline-length = 88\n"
        XCTAssertEqual(ConfigDocument(text: text).render(), text)
    }

    // MARK: - Read-only array / table helpers (the custom dictionary)

    func testStringArrayReadsInlineList() {
        let doc = ConfigDocument(text: """
            [dictionary]
            enabled = true
            words = ["Salammagari", "parakeet-mlx", "MLX"]
            """)
        XCTAssertEqual(doc.stringArray("dictionary", "words"),
                       ["Salammagari", "parakeet-mlx", "MLX"])
    }

    func testStringArrayEmptyAndMissing() {
        let doc = ConfigDocument(text: "[dictionary]\nwords = []\n")
        XCTAssertEqual(doc.stringArray("dictionary", "words"), [])
        XCTAssertNil(doc.stringArray("dictionary", "absent"))
        XCTAssertNil(ConfigDocument(text: "").stringArray("dictionary", "words"))
    }

    func testStringTableReadsQuotedKeyValuePairs() {
        let doc = ConfigDocument(text: """
            [dictionary.replacements]
            "salam mcgarry" = "Salammagari"
            "para keet" = "parakeet"
            """)
        let pairs = doc.stringTable("dictionary.replacements")
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs.first { $0.key == "salam mcgarry" }?.value, "Salammagari")
        XCTAssertEqual(pairs.first { $0.key == "para keet" }?.value, "parakeet")
    }

    func testStringTableStopsAtNextHeaderAndIgnoresComments() {
        let doc = ConfigDocument(text: """
            [dictionary.replacements]
            # a comment
            "a" = "b"

            [other]
            "c" = "d"
            """)
        let pairs = doc.stringTable("dictionary.replacements")
        XCTAssertEqual(pairs.map(\.key), ["a"])  // not "c" from [other]
    }

    func testStringTableMissingSectionIsEmpty() {
        XCTAssertTrue(
            ConfigDocument(text: "[dictionary]\n").stringTable("dictionary.replacements").isEmpty)
    }
}
