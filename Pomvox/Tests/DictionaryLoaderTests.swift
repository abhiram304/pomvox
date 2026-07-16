import XCTest
@testable import Pomvox

final class DictionaryLoaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dict-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }
    private func write(_ name: String, _ text: String) throws -> String {
        let p = dir.appendingPathComponent(name).path
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    func testLoadsDictionaryTomlWhenPresent() throws {
        let dict = try write("dictionary.toml", """
        words = ["MLX"]
        [[rule]]
        sources = ["em el ex"]
        target = "MLX"
        """)
        let r = DictionaryLoader.load(configPath: dir.appendingPathComponent("none.toml").path,
                                      dictionaryPath: dict)
        XCTAssertEqual(r.file.words, ["MLX"])
        XCTAssertEqual(r.file.rules.count, 1)
        XCTAssertFalse(r.fromLegacy)
        XCTAssertNil(r.parseError)
    }

    func testFallsBackToLegacyConfigSection() throws {
        let cfg = try write("config.toml", """
        [dictionary]
        enabled = true
        words = ["Kubernetes", "Anthropic"]
        [dictionary.replacements]
        "pom box" = "Pomvox"
        """)
        let r = DictionaryLoader.load(configPath: cfg,
                                      dictionaryPath: dir.appendingPathComponent("missing.toml").path)
        XCTAssertTrue(r.fromLegacy)
        XCTAssertEqual(r.file.words, ["Kubernetes", "Anthropic"])
        XCTAssertEqual(r.file.rules, [DictionaryRule(
            sources: ["pom box"], target: "Pomvox", enabled: true, origin: "manual")])
    }

    func testDictionaryTomlWinsOverLegacy() throws {
        let cfg = try write("config.toml", "[dictionary]\nwords = [\"Old\"]\n")
        let dict = try write("dictionary.toml", "words = [\"New\"]\n")
        let r = DictionaryLoader.load(configPath: cfg, dictionaryPath: dict)
        XCTAssertEqual(r.file.words, ["New"])
        XCTAssertFalse(r.fromLegacy)
    }

    func testMalformedFileReportsErrorAndLoadsNothing() throws {
        let dict = try write("dictionary.toml", "words = [broken\n")
        let r = DictionaryLoader.load(configPath: dir.appendingPathComponent("none.toml").path,
                                      dictionaryPath: dict)
        XCTAssertNotNil(r.parseError)
        XCTAssertEqual(r.file, DictionaryFile())   // empty, never a crash
    }

    func testBothMissingIsEmpty() {
        let r = DictionaryLoader.load(configPath: dir.appendingPathComponent("a.toml").path,
                                      dictionaryPath: dir.appendingPathComponent("b.toml").path)
        XCTAssertEqual(r.file, DictionaryFile())
        XCTAssertFalse(r.fromLegacy)
        XCTAssertNil(r.parseError)
    }
}
