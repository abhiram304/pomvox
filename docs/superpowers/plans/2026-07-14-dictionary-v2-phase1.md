# Dictionary v2 Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Dictionary v2 Phase 1 from `docs/superpowers/specs/2026-07-14-dictionary-v2-design.md`: a Dictionary page in the Hub (words + many-to-one fixup rules + live test box), add-from-History, a global quick-add hotkey, phonetic variant suggestions, hot-apply without manual re-arm, and per-rule fired stats.

**Architecture:** The dictionary moves from `config.toml`'s `[dictionary]` section to an app-owned `~/.pomvox/dictionary.toml` (parsed/serialized by a new `DictionaryDocument`; `ConfigDocument` stays untouched). A `DictionaryStore` (`@MainActor ObservableObject`) is the single writer; the engine consumes read-only snapshots via a pure `DictionaryLoader` and reloads on a `.pomvoxDictionaryDidChange` notification. Replacement rules hot-apply instantly (they run post-transcription); a words edit rebuilds the cleanup LLM's cached prompt prefixes in the background via a new `CleanupEngine.updateTermsHint` (no full re-arm). Fired-rule stats live in a JSON sidecar, never in the TOML or the frozen history schema.

**Tech Stack:** Swift 5.10, SwiftUI (macOS 14), XCTest, XcodeGen, NSRegularExpression, mlx-swift-lm (variant suggestions only in Task 13).

## Global Constraints

- Working copy is `~/dev/murmur` (NOT the stale `~/Desktop/projects/murmur`). All paths below are relative to `~/dev/murmur`.
- Build needs full Xcode: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in every shell.
- After creating or deleting ANY source file: `cd Pomvox && xcodegen generate` (the .xcodeproj is gitignored; project.yml globs `Sources/` and `Tests/`).
- Test command (fast, one class): `cd Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' -only-testing:PomvoxTests/<ClassName> 2>&1 | tail -20`
- Full suite before each commit: same command without `-only-testing:`.
- Derived data ALWAYS at `/tmp/pomvox-dd` (never inside the repo).
- Tests import with `@testable import Pomvox`.
- Commits: conventional commits (`feat(dictionary): …`), subject ≤ 72 chars, GPG signing is automatic, end body with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Engine contracts that MUST NOT change: replacement matching is whole-word, case-insensitive, longest-source-first; replacement values are literal (never backreferences); the v0.1.8 wipe contract (`dictionary_wiped` classification in `EmptyTranscript.swift`) stays intact; telemetry carries counts/codes only, NEVER text.
- `[dictionary] enabled` in `config.toml` continues to gate the whole feature.
- New user-facing copy says **Pomvox** (never Murmur/Natter).

---

### Task 1: Dictionary data model + TOML document

**Files:**
- Create: `Pomvox/Sources/Engine/DictionaryModel.swift`
- Create: `Pomvox/Sources/Engine/DictionaryDocument.swift`
- Test: `Pomvox/Tests/DictionaryDocumentTests.swift`

**Interfaces:**
- Consumes: nothing (pure foundation).
- Produces: `struct DictionaryRule { var sources: [String]; var target: String; var enabled: Bool; var origin: String; var id: String }`, `struct DictionaryFile { var schema: Int; var words: [String]; var rules: [DictionaryRule] }`, `enum DictionaryParseError: Error, Equatable { case malformed(line: Int, reason: String) }`, `enum DictionaryDocument { static func parse(_ text: String) throws -> DictionaryFile; static func serialize(_ file: DictionaryFile) -> String }`.

- [ ] **Step 1: Write the failing tests**

Create `Pomvox/Tests/DictionaryDocumentTests.swift`:

```swift
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

    func testRuleIDIsStableAndOrderInsensitive() {
        let a = DictionaryRule(sources: ["B", "a"], target: "T", enabled: true, origin: "manual")
        let b = DictionaryRule(sources: ["a", "b"], target: "t", enabled: false, origin: "history")
        XCTAssertEqual(a.id, b.id)  // identity = normalized content, not flags
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd ~/dev/murmur/Pomvox && xcodegen generate && \
xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' \
  -only-testing:PomvoxTests/DictionaryDocumentTests 2>&1 | tail -20
```

Expected: BUILD FAILED — `cannot find 'DictionaryFile' in scope`.

- [ ] **Step 3: Write the model**

Create `Pomvox/Sources/Engine/DictionaryModel.swift`:

```swift
import Foundation

/// One misheard-term fixup: any of `sources` (heard) → `target` (written).
/// `target == ""` is a legal wipe rule (kills a verbal tic — the v0.1.8 wipe
/// contract handles the everything-deleted edge). `origin` records where the
/// rule came from (manual | history | variant; Phase 2 adds suggested/mined:*)
/// so later phases don't need a schema migration.
struct DictionaryRule: Equatable, Identifiable {
    var sources: [String]
    var target: String
    var enabled: Bool = true
    var origin: String = "manual"

    /// Content-derived identity: stable across file rewrites and hand-edits
    /// that only touch flags, used as the stats-sidecar key. Case/order of
    /// sources doesn't change identity; editing sources or target does (the
    /// old stats row is then orphaned — harmless, it just resets the count).
    var id: String {
        target.lowercased() + "→"
            + sources.map { $0.lowercased() }.sorted().joined(separator: "|")
    }
}

/// The parsed shape of `~/.pomvox/dictionary.toml`.
struct DictionaryFile: Equatable {
    var schema: Int = 1
    var words: [String] = []
    var rules: [DictionaryRule] = []
}
```

- [ ] **Step 4: Write the document parser/serializer**

Create `Pomvox/Sources/Engine/DictionaryDocument.swift`:

```swift
import Foundation

/// Parse error carrying the 1-based line for the Dictionary page banner.
enum DictionaryParseError: Error, Equatable {
    case malformed(line: Int, reason: String)
}

/// Reader/writer for the app-owned `dictionary.toml`. Unlike `ConfigDocument`
/// (a surgical scalar editor that must preserve every byte of a user-owned
/// file), this file is app-owned: parse to a model, serialize canonically.
/// Hand-edits are supported; comments outside the emitted header are dropped
/// on the next in-app edit (the header says so). Unknown keys are ignored on
/// parse — a newer Pomvox's file must never brick an older one — and are
/// therefore also dropped on rewrite.
enum DictionaryDocument {

    static let header = """
    # Pomvox dictionary — words the cleanup model should spell your way, and
    # misheard-term fixup rules applied to every transcript.
    # Safe to hand-edit. Pomvox rewrites this file when you edit in the app;
    # comments outside this header are not preserved.
    """

    // MARK: - Parse

    static func parse(_ text: String) throws -> DictionaryFile {
        var file = DictionaryFile()
        // nil = top level; non-nil = accumulating a [[rule]] block.
        var current: DictionaryRule? = nil
        func flush() {
            if let r = current { file.rules.append(r) }
            current = nil
        }
        for (i, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let lineNo = i + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "[[rule]]" {
                flush()
                current = DictionaryRule(sources: [], target: "")
                continue
            }
            if line.hasPrefix("[") {
                throw DictionaryParseError.malformed(line: lineNo, reason: "unknown section \(line)")
            }
            guard let eq = line.firstIndex(of: "=") else {
                throw DictionaryParseError.malformed(line: lineNo, reason: "expected key = value")
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if var rule = current {
                switch key {
                case "sources": rule.sources = try stringArray(value, line: lineNo)
                case "target": rule.target = try string(value, line: lineNo)
                case "enabled": rule.enabled = try bool(value, line: lineNo)
                case "origin": rule.origin = try string(value, line: lineNo)
                default: break  // unknown rule key: ignore (forward compat)
                }
                current = rule
            } else {
                switch key {
                case "schema":
                    guard let n = Int(value) else {
                        throw DictionaryParseError.malformed(line: lineNo, reason: "schema must be an integer")
                    }
                    file.schema = n
                case "words": file.words = try stringArray(value, line: lineNo)
                default: break  // unknown top-level key: ignore
                }
            }
        }
        flush()
        return file
    }

    // MARK: - Serialize (canonical form; round-trip byte-stable)

    static func serialize(_ file: DictionaryFile) -> String {
        var out = header + "\n"
        out += "schema = \(file.schema)\n"
        out += "words = [" + file.words.map(quote).joined(separator: ", ") + "]\n"
        for rule in file.rules {
            out += "\n[[rule]]\n"
            out += "sources = [" + rule.sources.map(quote).joined(separator: ", ") + "]\n"
            out += "target = \(quote(rule.target))\n"
            out += "enabled = \(rule.enabled)\n"
            out += "origin = \(quote(rule.origin))\n"
        }
        return out
    }

    // MARK: - Scalar helpers

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func unquote(_ s: String, line: Int) throws -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else {
            throw DictionaryParseError.malformed(line: line, reason: "expected a quoted string")
        }
        var out = ""
        var escaped = false
        for ch in s.dropFirst().dropLast() {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(ch)   // \" and \\ (and anything else, literally)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func string(_ v: String, line: Int) throws -> String {
        try unquote(v, line: line)
    }

    private static func bool(_ v: String, line: Int) throws -> Bool {
        switch v {
        case "true": return true
        case "false": return false
        default: throw DictionaryParseError.malformed(line: line, reason: "expected true/false")
        }
    }

    /// `["a", "b c"]` on one line → unescaped strings. Splits on top-level
    /// commas only (commas inside quotes don't count).
    private static func stringArray(_ v: String, line: Int) throws -> [String] {
        guard v.hasPrefix("["), v.hasSuffix("]") else {
            throw DictionaryParseError.malformed(line: line, reason: "expected a [\"…\"] array")
        }
        let inner = String(v.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return [] }
        var items: [String] = []
        var depth = ""
        var inString = false
        var escaped = false
        for ch in inner {
            if inString {
                depth.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                depth.append(ch); inString = true
            } else if ch == "," {
                items.append(depth.trimmingCharacters(in: .whitespaces)); depth = ""
            } else {
                depth.append(ch)
            }
        }
        items.append(depth.trimmingCharacters(in: .whitespaces))
        return try items.map { try unquote($0, line: line) }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 2. Expected: `Test Suite 'DictionaryDocumentTests' passed`.

- [ ] **Step 6: Run the full suite, then commit**

```bash
cd ~/dev/murmur/Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' 2>&1 | tail -5
cd ~/dev/murmur && git add Pomvox/Sources/Engine/DictionaryModel.swift Pomvox/Sources/Engine/DictionaryDocument.swift Pomvox/Tests/DictionaryDocumentTests.swift
git commit -m "feat(dictionary): dictionary.toml model + parser/serializer

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Paths + loader with legacy config.toml fallback

**Files:**
- Create: `Pomvox/Sources/Engine/DictionaryLoader.swift`
- Test: `Pomvox/Tests/DictionaryLoaderTests.swift`

**Interfaces:**
- Consumes: `DictionaryDocument.parse`, `DictionaryFile`, `DictionaryRule` (Task 1); `ConfigDocument` (existing: `.load(path:)`, `.bool(_:_:)`, `.stringArray(_:_:)`, `.stringTable(_:)`).
- Produces: `enum DictionaryPaths { static func dictionaryPath() -> String; static func statsPath() -> String }`, `struct DictionaryLoadResult: Equatable { var file: DictionaryFile; var fromLegacy: Bool; var parseError: String? }`, `enum DictionaryLoader { static func load(configPath: String, dictionaryPath: String) -> DictionaryLoadResult; static func legacyFile(configPath: String) -> DictionaryFile }`.

- [ ] **Step 1: Write the failing tests**

Create `Pomvox/Tests/DictionaryLoaderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

```bash
cd ~/dev/murmur/Pomvox && xcodegen generate && \
xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' \
  -only-testing:PomvoxTests/DictionaryLoaderTests 2>&1 | tail -20
```

Expected: BUILD FAILED — `cannot find 'DictionaryLoader' in scope`.

- [ ] **Step 3: Implement**

Create `Pomvox/Sources/Engine/DictionaryLoader.swift`:

```swift
import Foundation

/// Canonical locations, with env overrides mirroring `POMVOX_CONFIG_PATH`
/// (see `SettingsModel.defaultPath()`) so tests and rigs can redirect them.
enum DictionaryPaths {
    static func dictionaryPath() -> String {
        if let o = ProcessInfo.processInfo.environment["POMVOX_DICTIONARY_PATH"], !o.isEmpty {
            return o
        }
        return NSString(string: "~/.pomvox/dictionary.toml").expandingTildeInPath
    }

    static func statsPath() -> String {
        if let o = ProcessInfo.processInfo.environment["POMVOX_DICTIONARY_STATS_PATH"], !o.isEmpty {
            return o
        }
        return NSString(string: "~/.pomvox/dictionary-stats.json").expandingTildeInPath
    }
}

struct DictionaryLoadResult: Equatable {
    var file: DictionaryFile
    var fromLegacy: Bool
    var parseError: String?
}

/// Read-only resolution of the effective dictionary. Shared by the engine
/// (at arm and on reload) and by `DictionaryStore` (which additionally owns
/// the one-time legacy→file migration write — this loader never writes).
enum DictionaryLoader {

    static func load(configPath: String, dictionaryPath: String) -> DictionaryLoadResult {
        if let text = try? String(contentsOfFile: dictionaryPath, encoding: .utf8) {
            do {
                return DictionaryLoadResult(
                    file: try DictionaryDocument.parse(text), fromLegacy: false, parseError: nil)
            } catch let DictionaryParseError.malformed(line, reason) {
                NSLog("dictionary: %@ line %d: %@ — keeping last-good/empty set",
                      dictionaryPath, line, reason)
                return DictionaryLoadResult(
                    file: DictionaryFile(), fromLegacy: false,
                    parseError: "Line \(line): \(reason)")
            } catch {
                return DictionaryLoadResult(
                    file: DictionaryFile(), fromLegacy: false,
                    parseError: String(describing: error))
            }
        }
        let legacy = legacyFile(configPath: configPath)
        let hasLegacy = !legacy.words.isEmpty || !legacy.rules.isEmpty
        return DictionaryLoadResult(file: legacy, fromLegacy: hasLegacy, parseError: nil)
    }

    /// The pre-v2 `[dictionary]` shape inside config.toml, mapped 1:1 into the
    /// new model (each replacement pair becomes a single-source manual rule).
    static func legacyFile(configPath: String) -> DictionaryFile {
        let doc = ConfigDocument.load(path: configPath)
        let words = doc.stringArray("dictionary", "words") ?? []
        let rules = doc.stringTable("dictionary.replacements").map {
            DictionaryRule(sources: [$0.key], target: $0.value, enabled: true, origin: "manual")
        }
        return DictionaryFile(schema: 1, words: words, rules: rules)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Full suite, commit**

```bash
cd ~/dev/murmur && git add Pomvox/Sources/Engine/DictionaryLoader.swift Pomvox/Tests/DictionaryLoaderTests.swift
git commit -m "feat(dictionary): loader with legacy [dictionary] fallback

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Rules-aware PomvoxDictionary with fired-rule reporting + wipe punctuation fix

**Files:**
- Modify: `Pomvox/Sources/Engine/PomvoxDictionary.swift`
- Test: `Pomvox/Tests/PomvoxDictionaryTests.swift` (extend, keep every existing test green)

**Interfaces:**
- Consumes: `DictionaryFile`, `DictionaryRule` (Task 1).
- Produces (new, existing API preserved): `struct DictionaryApplied: Equatable { let text: String; let fired: [String] }`; `PomvoxDictionary.init(file: DictionaryFile, enabled: Bool)`; `func applyReporting(_ text: String) -> DictionaryApplied` (`apply(_:)` remains and now delegates); free function `func compileRules(_ rules: [DictionaryRule]) -> [CompiledRule]` where `struct CompiledRule { let re: NSRegularExpression; let template: String; let ruleID: String; let isWipe: Bool }`.

- [ ] **Step 1: Write the failing tests (append to PomvoxDictionaryTests.swift)**

```swift
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
```

- [ ] **Step 2: Run to verify the new tests fail**

```bash
cd ~/dev/murmur/Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' \
  -only-testing:PomvoxTests/PomvoxDictionaryTests 2>&1 | tail -20
```

Expected: BUILD FAILED — `PomvoxDictionary` has no `init(file:)`.

- [ ] **Step 3: Implement**

In `Pomvox/Sources/Engine/PomvoxDictionary.swift`, keep `dictionaryPromptHint`, `compileReplacements`, and `substitute` exactly as they are (existing tests pin them). Add below `substitute`:

```swift
/// One compiled rule: the whole-word regex, the literal-escaped template, the
/// owning rule's stable id (for fired-rule reporting), and whether it's a wipe
/// (empty target — those get punctuation-absorbing treatment).
struct CompiledRule {
    let re: NSRegularExpression
    let template: String
    let ruleID: String
    let isWipe: Bool
}

/// Compile enabled rules, expanding many-to-one sources into per-source
/// regexes. Ordering contract unchanged: longest source first across ALL
/// rules, whole-word, case-insensitive, empty sources skipped. Wipe rules
/// additionally absorb one trailing punctuation mark so "um." never leaves
/// a stranded "." (the v0.1.8 rough edge).
func compileRules(_ rules: [DictionaryRule]) -> [CompiledRule] {
    var flat: [(src: String, rule: DictionaryRule)] = []
    for rule in rules where rule.enabled {
        for src in rule.sources { flat.append((src, rule)) }
    }
    var compiled: [CompiledRule] = []
    for (src, rule) in flat.sorted(by: { $0.src.count > $1.src.count }) {
        let stripped = src.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else {
            NSLog("dictionary: ignoring empty replacement key")
            continue
        }
        let isWipe = rule.target.isEmpty
        var pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: stripped) + "(?!\\w)"
        if isWipe { pattern += "[.,!?;:]?" }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else {
            NSLog("dictionary: bad replacement pattern for %@", stripped)
            continue
        }
        compiled.append(CompiledRule(
            re: re,
            template: NSRegularExpression.escapedTemplate(for: rule.target),
            ruleID: rule.id,
            isWipe: isWipe))
    }
    return compiled
}

/// `substitute` with fired-rule reporting and post-wipe tidying. Fired ids are
/// unique, in first-fired order.
func substituteReporting(_ text: String, _ compiled: [CompiledRule]) -> (text: String, fired: [String]) {
    var out = text
    var fired: [String] = []
    var wiped = false
    for c in compiled {
        let range = NSRange(out.startIndex..., in: out)
        guard c.re.numberOfMatches(in: out, options: [], range: range) > 0 else { continue }
        out = c.re.stringByReplacingMatches(
            in: out, options: [], range: range, withTemplate: c.template)
        if !fired.contains(c.ruleID) { fired.append(c.ruleID) }
        if c.isWipe { wiped = true }
    }
    if wiped { out = tidyAfterWipe(out) }
    return (out, fired)
}

/// Collapse the debris a wipe leaves behind: runs of spaces, a space before
/// punctuation, and leading/trailing whitespace. Only runs when a wipe rule
/// fired — non-wipe substitutions never reshape their surroundings.
func tidyAfterWipe(_ text: String) -> String {
    var out = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    out = out.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}
```

Then extend the struct (keep the existing `init(words:replacements:enabled:)` and `apply` for the pinned tests; store `CompiledRule`s):

```swift
struct PomvoxDictionary {
    let hint: String
    private let compiled: [CompiledRule]
    private let enabled: Bool

    /// v2 entry point: build from the parsed dictionary file.
    init(file: DictionaryFile, enabled: Bool = true) {
        self.enabled = enabled
        self.hint = enabled ? dictionaryPromptHint(file.words) : ""
        self.compiled = enabled ? compileRules(file.rules) : []
        if enabled, !self.hint.isEmpty || !self.compiled.isEmpty {
            let termCount = file.words.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            NSLog("dictionary: %d term(s), %d compiled replacement(s)", termCount, self.compiled.count)
        }
    }

    /// Legacy pairs entry point (pre-v2 tests + parity vectors). Each pair maps
    /// to a single-source rule, so both inits share one compile path.
    init(words: [String], replacements: [(String, String)], enabled: Bool = true) {
        self.init(
            file: DictionaryFile(
                words: words,
                rules: replacements.map {
                    DictionaryRule(sources: [$0.0], target: $0.1, enabled: true, origin: "manual")
                }),
            enabled: enabled)
    }

    func apply(_ text: String) -> String { applyReporting(text).text }

    func applyReporting(_ text: String) -> DictionaryApplied {
        guard enabled, !text.isEmpty, !compiled.isEmpty else {
            return DictionaryApplied(text: text, fired: [])
        }
        let (out, fired) = substituteReporting(text, compiled)
        return DictionaryApplied(text: out, fired: fired)
    }
}

struct DictionaryApplied: Equatable {
    let text: String
    let fired: [String]
}
```

Note: the OLD `compileReplacements`/`substitute` free functions stay (their tests are the parity spec), but `PomvoxDictionary` no longer calls them.

**Check before running:** two legacy tests pin behavior the wipe fix intentionally changes only for EMPTY targets — none of the existing tests use empty targets, so all must stay green. If `testSubstituteTreatsValueLiterally` fails you touched `substitute`; revert that.

- [ ] **Step 4: Run PomvoxDictionaryTests — all old + new pass**

Same command as Step 2. Expected: PASS (all existing vectors + 11 new).

- [ ] **Step 5: Full suite, commit**

```bash
cd ~/dev/murmur && git add Pomvox/Sources/Engine/PomvoxDictionary.swift Pomvox/Tests/PomvoxDictionaryTests.swift
git commit -m "feat(dictionary): many-to-one rules, fired reporting, wipe punctuation fix

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Fired-stats sidecar

**Files:**
- Create: `Pomvox/Sources/Engine/DictionaryStats.swift`
- Test: `Pomvox/Tests/DictionaryStatsTests.swift`

**Interfaces:**
- Consumes: `DictionaryPaths.statsPath()` (Task 2).
- Produces: `struct DictionaryRuleStats: Codable, Equatable { var count: Int; var lastFired: Double }`; `final class DictionaryStatsStore` with `init(path: String = DictionaryPaths.statsPath())`, `func record(_ ruleIDs: [String], at ts: Double)`, `func stats(for ruleID: String) -> DictionaryRuleStats?`, `func allStats() -> [String: DictionaryRuleStats]`, `static let shared`; `Notification.Name.pomvoxDictionaryStatsDidChange`.

- [ ] **Step 1: Write the failing tests**

Create `Pomvox/Tests/DictionaryStatsTests.swift`:

```swift
import XCTest
@testable import Pomvox

final class DictionaryStatsTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = NSTemporaryDirectory() + "dict-stats-\(UUID().uuidString).json"
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testRecordIncrementsAndStampsLastFired() {
        let store = DictionaryStatsStore(path: path)
        store.record(["r1", "r2"], at: 100)
        store.record(["r1"], at: 200)
        XCTAssertEqual(store.stats(for: "r1"), DictionaryRuleStats(count: 2, lastFired: 200))
        XCTAssertEqual(store.stats(for: "r2"), DictionaryRuleStats(count: 1, lastFired: 100))
        XCTAssertNil(store.stats(for: "never"))
    }

    func testPersistsAcrossInstances() {
        DictionaryStatsStore(path: path).record(["r1"], at: 5)
        XCTAssertEqual(DictionaryStatsStore(path: path).stats(for: "r1")?.count, 1)
    }

    func testCorruptFileResetsHarmlessly() throws {
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        let store = DictionaryStatsStore(path: path)
        XCTAssertNil(store.stats(for: "r1"))
        store.record(["r1"], at: 1)   // and writes cleanly after
        XCTAssertEqual(DictionaryStatsStore(path: path).stats(for: "r1")?.count, 1)
    }

    func testRecordEmptyIsNoOp() {
        let store = DictionaryStatsStore(path: path)
        store.record([], at: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testThreadSafety() {
        let store = DictionaryStatsStore(path: path)
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            store.record(["r\(i % 5)"], at: Double(i))
        }
        let total = store.allStats().values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, 50)
    }
}
```

- [ ] **Step 2: Run to verify failure** (xcodegen + `-only-testing:PomvoxTests/DictionaryStatsTests`). Expected: BUILD FAILED.

- [ ] **Step 3: Implement**

Create `Pomvox/Sources/Engine/DictionaryStats.swift`:

```swift
import Foundation

struct DictionaryRuleStats: Codable, Equatable {
    var count: Int
    var lastFired: Double   // epoch seconds
}

extension Notification.Name {
    static let pomvoxDictionaryStatsDidChange = Notification.Name("app.pomvox.dictionaryStatsDidChange")
}

/// Per-rule hit counts + last-fired timestamps, in a JSON sidecar so the
/// dictionary.toml stays clean for git. Best-effort: corruption or a lost
/// write only resets counters, never breaks dictation. Lock-guarded — the
/// engine records from its post-paste background task while the page reads
/// on the main actor.
final class DictionaryStatsStore: @unchecked Sendable {
    static let shared = DictionaryStatsStore()

    private let path: String
    private let lock = NSLock()
    private var byRule: [String: DictionaryRuleStats]

    init(path: String = DictionaryPaths.statsPath()) {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let decoded = try? JSONDecoder().decode([String: DictionaryRuleStats].self, from: data) {
            byRule = decoded
        } else {
            byRule = [:]
        }
    }

    func record(_ ruleIDs: [String], at ts: Double = Date().timeIntervalSince1970) {
        guard !ruleIDs.isEmpty else { return }
        lock.lock()
        for id in ruleIDs {
            var s = byRule[id] ?? DictionaryRuleStats(count: 0, lastFired: 0)
            s.count += 1
            s.lastFired = max(s.lastFired, ts)
            byRule[id] = s
        }
        let snapshot = byRule
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        NotificationCenter.default.post(name: .pomvoxDictionaryStatsDidChange, object: nil)
    }

    func stats(for ruleID: String) -> DictionaryRuleStats? {
        lock.lock(); defer { lock.unlock() }
        return byRule[ruleID]
    }

    func allStats() -> [String: DictionaryRuleStats] {
        lock.lock(); defer { lock.unlock() }
        return byRule
    }
}
```

- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Full suite, commit** — `feat(dictionary): fired-rule stats sidecar`.

---

### Task 5: Engine integration — load, report, hot-reload, hint rebuild

**Files:**
- Modify: `Pomvox/Sources/Engine/NativeEngine.swift` (three spots: `loadEngineConfig()` ~line 627, the finish() dictionary application ~line 795–850, and `init`/observer registration)
- Modify: `Pomvox/Sources/Engine/CleanupEngine.swift` (add `updateTermsHint`)
- Modify: `Pomvox/Sources/Engine/EmptyTranscript.swift` (one copy tweak)
- Test: `Pomvox/Tests/EmptyTranscriptTests.swift` (copy assertion), engine changes verified by full suite + on-device (Task 14)

**Interfaces:**
- Consumes: `DictionaryLoader.load`, `DictionaryPaths.dictionaryPath()` (Task 2), `PomvoxDictionary(file:enabled:)`, `applyReporting` (Task 3), `DictionaryStatsStore.shared.record` (Task 4).
- Produces: `NativeEngine.reloadDictionary()` (`@MainActor`); `CleanupEngine.updateTermsHint(_ hint: String) async`; `Notification.Name.pomvoxDictionaryDidChange` and `.pomvoxDictionaryHintApplied` (declared here in NativeEngine.swift's file scope — Task 6's store posts the former, the page listens for the latter).

- [ ] **Step 1: Add the notification names + CleanupEngine method**

In `Pomvox/Sources/Engine/NativeEngine.swift`, near the top (after imports):

```swift
extension Notification.Name {
    /// Posted by DictionaryStore after every save; the engine hot-reloads.
    static let pomvoxDictionaryDidChange = Notification.Name("app.pomvox.dictionaryDidChange")
    /// Posted by the engine when a changed words-hint has been re-baked into
    /// the cleanup prefix caches (drives the page's "applying…" indicator).
    static let pomvoxDictionaryHintApplied = Notification.Name("app.pomvox.dictionaryHintApplied")
}
```

In `Pomvox/Sources/Engine/CleanupEngine.swift`, below `setTermsHint` (line ~80):

```swift
    /// Hot-apply a dictionary words edit: swap the hint and, if the model is
    /// resident, rebuild the per-style prefix caches so the change takes
    /// effect on the next utterance — seconds of background prefill instead
    /// of a full re-arm. When the model isn't loaded this just stores the
    /// hint; the next prepare()/buildPrefixCaches bakes it in.
    func updateTermsHint(_ hint: String) async {
        guard hint != termsHint else { return }
        termsHint = hint
        guard container != nil else { return }
        prefixCaches = [:]
        await buildPrefixCaches()
        NSLog("cleanup: prefix caches rebuilt for new dictionary hint")
    }
```

- [ ] **Step 2: Switch `loadEngineConfig()` to the loader**

In `NativeEngine.swift` find (~line 627):

```swift
        let dictEnabled = doc.bool("dictionary", "enabled") ?? true
        dictionary = PomvoxDictionary(
            words: doc.stringArray("dictionary", "words") ?? [],
            replacements: doc.stringTable("dictionary.replacements").map { ($0.key, $0.value) },
            enabled: dictEnabled)
```

Replace with:

```swift
        let dictEnabled = doc.bool("dictionary", "enabled") ?? true
        let loaded = DictionaryLoader.load(
            configPath: SettingsModel.defaultPath(),
            dictionaryPath: DictionaryPaths.dictionaryPath())
        dictionary = PomvoxDictionary(file: loaded.file, enabled: dictEnabled)
```

(`doc` here already IS the config document loaded from the settings path — check the surrounding function; if it exposes the path it was loaded from, pass that instead of `SettingsModel.defaultPath()` so the `POMVOX_CONFIG_PATH` test override keeps working. Match whatever expression the function used to obtain `doc`.)

- [ ] **Step 3: Fired-rule reporting in the finish path**

In `NativeEngine.swift` finish() Task (~line 795+), find:

```swift
            text = dict.apply(text)
```

Replace with:

```swift
            let applied = dict.applyReporting(text)
            text = applied.text
```

Then, immediately after the paste outcome is known to be non-empty (inside the same Task, right after the `MainActor.run` block returns — the same place the telemetry `if !text.isEmpty` check lives), add:

```swift
            if !applied.fired.isEmpty, !text.isEmpty {
                DictionaryStatsStore.shared.record(applied.fired)
            }
```

- [ ] **Step 4: Hot-reload on notification**

Add to `NativeEngine` (near the other observer registration, or in `init` — follow where `registerSleepWakeObservers` style fits; the observer must live for the engine's lifetime, so `init` is right):

```swift
        NotificationCenter.default.addObserver(
            forName: .pomvoxDictionaryDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadDictionary() }
        }
```

And the method (near `loadEngineConfig`):

```swift
    /// Hot-apply a dictionary edit (posted by DictionaryStore on every save).
    /// Rules take effect on the next utterance immediately (they run post-
    /// transcription). A words change re-bakes the cleanup prompt prefix in
    /// the background; dictation during the rebuild uses the old hint.
    func reloadDictionary() {
        let doc = ConfigDocument.load(path: SettingsModel.defaultPath())
        let dictEnabled = doc.bool("dictionary", "enabled") ?? true
        let loaded = DictionaryLoader.load(
            configPath: SettingsModel.defaultPath(),
            dictionaryPath: DictionaryPaths.dictionaryPath())
        dictionary = PomvoxDictionary(file: loaded.file, enabled: dictEnabled)
        NSLog("dictionary: hot-reloaded (%d rules)", loaded.file.rules.count)
        let hint = dictionary.hint
        if cleanupEnabled, hint != cleanupHint {
            cleanupHint = hint
            Task { [cleanup] in
                await cleanup.updateTermsHint(hint)
                NotificationCenter.default.post(name: .pomvoxDictionaryHintApplied, object: nil)
            }
        } else {
            NotificationCenter.default.post(name: .pomvoxDictionaryHintApplied, object: nil)
        }
    }
```

- [ ] **Step 5: Update the wipe-flash copy**

In `Pomvox/Sources/Engine/EmptyTranscript.swift` the `.dictionaryWiped` HUD message says `"your replacement rules removed every word — check Settings ▸ Dictionary"`. The dictionary now has its own page; change to:

```swift
        case .dictionaryWiped:
            "your replacement rules removed every word — check the Dictionary page"
```

Update the matching assertion in `Pomvox/Tests/EmptyTranscriptTests.swift` (search for `Settings ▸ Dictionary`; if the test only checks non-nil, no change needed).

- [ ] **Step 6: Full suite green, commit**

```bash
cd ~/dev/murmur/Pomvox && xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS' 2>&1 | tail -5
cd ~/dev/murmur && git add -A Pomvox && git commit -m "feat(dictionary): engine hot-reload, fired stats, prefix-cache hint rebuild

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: DictionaryStore (UI-side single writer) + one-time migration

**Files:**
- Create: `Pomvox/Sources/DictionaryStore.swift`
- Test: `Pomvox/Tests/DictionaryStoreTests.swift`

**Interfaces:**
- Consumes: `DictionaryDocument`, `DictionaryLoader`, `DictionaryPaths`, `Notification.Name.pomvoxDictionaryDidChange` / `.pomvoxDictionaryHintApplied` (Tasks 1/2/5).
- Produces: `@MainActor final class DictionaryStore: ObservableObject` with `@Published private(set) var file: DictionaryFile`, `@Published private(set) var parseError: String?`, `@Published private(set) var applyingHint: Bool`, `init(path:configPath:)`, `func addWord(_:)`, `func removeWord(_:)`, `func upsert(_ rule: DictionaryRule, replacingID: String?)`, `func removeRule(id:)`, `func setRuleEnabled(id:_:)`, `func reloadFromDisk()`. Every mutator saves + posts `.pomvoxDictionaryDidChange`.

- [ ] **Step 1: Write the failing tests**

Create `Pomvox/Tests/DictionaryStoreTests.swift`:

```swift
import XCTest
@testable import Pomvox

@MainActor
final class DictionaryStoreTests: XCTestCase {
    private var dir: URL!
    private var dictPath: String { dir.appendingPathComponent("dictionary.toml").path }
    private var cfgPath: String { dir.appendingPathComponent("config.toml").path }

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dict-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMigratesLegacyConfigOnFirstLoad() throws {
        try """
        [dictionary]
        words = ["Kubernetes"]
        [dictionary.replacements]
        "pom box" = "Pomvox"
        """.write(toFile: cfgPath, atomically: true, encoding: .utf8)
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        XCTAssertEqual(store.file.words, ["Kubernetes"])
        XCTAssertEqual(store.file.rules.count, 1)
        // Migration WROTE the new file; config.toml untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dictPath))
        let cfg = try String(contentsOfFile: cfgPath, encoding: .utf8)
        XCTAssertTrue(cfg.contains("pom box"))
    }

    func testAddWordSavesAndDedupes() throws {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        store.addWord("MLX")
        store.addWord("  MLX ")   // dupe after trim
        store.addWord("")
        XCTAssertEqual(store.file.words, ["MLX"])
        let onDisk = try DictionaryDocument.parse(String(contentsOfFile: dictPath, encoding: .utf8))
        XCTAssertEqual(onDisk.words, ["MLX"])
    }

    func testUpsertAndRemoveRule() {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        let r = DictionaryRule(sources: ["pom box"], target: "Pomvox", enabled: true, origin: "manual")
        store.upsert(r, replacingID: nil)
        XCTAssertEqual(store.file.rules, [r])
        var edited = r
        edited.sources = ["pom box", "palm vox"]
        store.upsert(edited, replacingID: r.id)
        XCTAssertEqual(store.file.rules, [edited])
        store.removeRule(id: edited.id)
        XCTAssertEqual(store.file.rules, [])
    }

    func testUpsertDropsEmptySourcesAndDupes() {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        store.upsert(DictionaryRule(sources: [" pom box ", "", "pom box"], target: "Pomvox",
                                    enabled: true, origin: "manual"), replacingID: nil)
        XCTAssertEqual(store.file.rules.first?.sources, ["pom box"])
    }

    func testSetRuleEnabled() {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        let r = DictionaryRule(sources: ["a b"], target: "AB", enabled: true, origin: "manual")
        store.upsert(r, replacingID: nil)
        store.setRuleEnabled(id: r.id, false)
        XCTAssertEqual(store.file.rules.first?.enabled, false)
    }

    func testSavePostsDidChange() {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        let exp = expectation(forNotification: .pomvoxDictionaryDidChange, object: nil)
        store.addWord("Anthropic")
        wait(for: [exp], timeout: 1)
    }

    func testMalformedFileSurfacesParseErrorAndKeepsEditsBlocked() throws {
        try "words = [broken".write(toFile: dictPath, atomically: true, encoding: .utf8)
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        XCTAssertNotNil(store.parseError)
        store.addWord("X")   // must NOT clobber the malformed file
        let raw = try String(contentsOfFile: dictPath, encoding: .utf8)
        XCTAssertTrue(raw.contains("broken"))
    }
}
```

- [ ] **Step 2: Run to verify failure** (`-only-testing:PomvoxTests/DictionaryStoreTests`).

- [ ] **Step 3: Implement**

Create `Pomvox/Sources/DictionaryStore.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Full suite, commit** — `feat(dictionary): DictionaryStore single writer + legacy migration`.

---

### Task 7: Import/export interchange formats

**Files:**
- Create: `Pomvox/Sources/DictionaryInterchange.swift`
- Test: `Pomvox/Tests/DictionaryInterchangeTests.swift`

**Interfaces:**
- Consumes: `DictionaryRule` (Task 1).
- Produces: `enum DictionaryInterchange { static func parseWordList(_ text: String) -> [String]; static func wordList(_ words: [String]) -> String; static func parseRulesCSV(_ text: String) -> [DictionaryRule]; static func rulesCSV(_ rules: [DictionaryRule]) -> String }`. CSV row format: `source1|source2,target` (pipe-separated sources, comma, target; a trailing empty target = wipe rule; `#` lines and blanks skipped in both formats).

- [ ] **Step 1: Write the failing tests**

Create `Pomvox/Tests/DictionaryInterchangeTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement**

Create `Pomvox/Sources/DictionaryInterchange.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Full suite, commit** — `feat(dictionary): plain-text word list + rules CSV interchange`.

---

### Task 8: Phonetic variant generator (heuristics)

**Files:**
- Create: `Pomvox/Sources/Engine/VariantGenerator.swift`
- Test: `Pomvox/Tests/VariantGeneratorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum VariantGenerator { static func heuristicVariants(for term: String) -> [String] }` — likely STT mishearings, deduped, never containing the term itself (case-insensitively; matching is case-insensitive so case-only variants are useless).

- [ ] **Step 1: Write the failing tests**

Create `Pomvox/Tests/VariantGeneratorTests.swift`:

```swift
import XCTest
@testable import Pomvox

final class VariantGeneratorTests: XCTestCase {

    func testCamelCaseSplits() {
        let v = VariantGenerator.heuristicVariants(for: "ChargeBee")
        XCTAssertTrue(v.contains("charge bee"))
    }

    func testAcronymLetterSpacing() {
        let v = VariantGenerator.heuristicVariants(for: "GPT")
        XCTAssertTrue(v.contains("g p t"))
        XCTAssertTrue(v.contains("gpt"))   // smooshed lowercase run-on
    }

    func testHyphenAndSpaceVariants() {
        let v = VariantGenerator.heuristicVariants(for: "parakeet-mlx")
        XCTAssertTrue(v.contains("parakeet mlx"))
    }

    func testDigitBoundarySplit() {
        let v = VariantGenerator.heuristicVariants(for: "Qwen3")
        XCTAssertTrue(v.contains("qwen 3"))
    }

    func testNeverEchoesTheTermItself() {
        for term in ["Pomvox", "GPT", "parakeet-mlx", "plain"] {
            let v = VariantGenerator.heuristicVariants(for: term)
            XCTAssertFalse(v.contains { $0.caseInsensitiveCompare(term) == .orderedSame },
                           "echoed \(term)")
        }
    }

    func testDedupedAndLowercased() {
        let v = VariantGenerator.heuristicVariants(for: "MLX")
        XCTAssertEqual(v.count, Set(v).count)
        XCTAssertTrue(v.allSatisfy { $0 == $0.lowercased() })
    }

    func testPlainLowercaseWordYieldsNothing() {
        // "plain" has no humps, digits, hyphens, or caps: nothing to suggest.
        XCTAssertEqual(VariantGenerator.heuristicVariants(for: "plain"), [])
    }

    func testEmptyAndWhitespaceYieldNothing() {
        XCTAssertEqual(VariantGenerator.heuristicVariants(for: ""), [])
        XCTAssertEqual(VariantGenerator.heuristicVariants(for: "   "), [])
    }
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement**

Create `Pomvox/Sources/Engine/VariantGenerator.swift`:

```swift
import Foundation

/// Deterministic "what might the STT model write instead?" candidates for a
/// dictionary target. These become PRE-CHECKED, EDITABLE chips in the rule
/// editor — never silently added (the VoiceInk lesson). The LLM-backed
/// generator (CleanupEngine.suggestVariants) merges on top when the cleanup
/// model is resident; these heuristics are the always-available floor.
///
/// All variants are lowercase: rule matching is case-insensitive, so a
/// case-only variant would be a no-op, and lowercase reads as "heard text".
enum VariantGenerator {

    static func heuristicVariants(for term: String) -> [String] {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        var out: [String] = []
        func add(_ v: String) {
            let s = v.trimmingCharacters(in: .whitespaces).lowercased()
            guard !s.isEmpty, s.caseInsensitiveCompare(t) != .orderedSame,
                  !out.contains(s) else { return }
            out.append(s)
        }

        // 1. Hump/digit/punctuation split: "ChargeBee" → "charge bee",
        //    "Qwen3" → "qwen 3", "parakeet-mlx" → "parakeet mlx".
        add(splitWords(t).joined(separator: " "))

        // 2. Acronyms (any all-caps run of 2+): "GPT" → "g p t" (letter names
        //    often transcribe spaced) and "gpt" (the smooshed run-on).
        if t.count >= 2, t.allSatisfy({ $0.isUppercase && $0.isLetter }) {
            add(t.map(String.init).joined(separator: " "))
            add(t.lowercased())
        }

        // 3. Hyphen/underscore ↔ space (covered by 1 for mixed terms, but a
        //    lowercase "foo-bar" has no humps, so do it explicitly).
        if t.contains("-") || t.contains("_") {
            add(t.replacingOccurrences(of: "-", with: " ")
                 .replacingOccurrences(of: "_", with: " "))
        }
        return out
    }

    /// Split on case humps, letter↔digit boundaries, and separators.
    /// "ChargeBee" → ["Charge", "Bee"]; "Qwen3" → ["Qwen", "3"].
    private static func splitWords(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        var prev: Character? = nil
        for ch in s {
            if ch == "-" || ch == "_" || ch == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else if let p = prev,
                      (ch.isUppercase && p.isLowercase)
                          || (ch.isNumber && !p.isNumber)
                          || (!ch.isNumber && p.isNumber) {
                if !current.isEmpty { words.append(current); current = "" }
                current.append(ch)
            } else {
                current.append(ch)
            }
            prev = ch
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
```

- [ ] **Step 4: Run tests to verify they pass.**
- [ ] **Step 5: Full suite, commit** — `feat(dictionary): heuristic misheard-variant generator`.

---

### Task 9: Dictionary page — NavItem, words, rules list, test box

**Files:**
- Modify: `Pomvox/Sources/RootView.swift` (NavItem case + detail switch + environment object)
- Modify: `Pomvox/Sources/PomvoxApp.swift` (create the shared `DictionaryStore`, inject via `.environmentObject` — find where `HubModel`/`TelemetryModel` are injected and add alongside)
- Create: `Pomvox/Sources/DictionaryView.swift`
- Test: `Pomvox/Tests/FirstRunRoutingTests.swift` may pin `NavItem.allCases` — run it; update only if it enumerates cases.

**Interfaces:**
- Consumes: `DictionaryStore` (Task 6), `PomvoxDictionary(file:)`/`applyReporting` (Task 3), `DictionaryStatsStore` (Task 4), `DictionaryInterchange` (Task 7), existing design system (`Palette`, `Typo`, `Toolbar`, `Chip` in `Components.swift`/`DesignSystem.swift` — read both files first and match idioms exactly).
- Produces: `NavItem.dictionary`; `struct DictionaryView: View`; `struct FlowLayout: Layout` (reusable chip wrap); notification-driven refresh of stats. The rule-editor sheet is Task 10 — this task wires a placeholder `@State private var editingRule` and sheet presentation point but the sheet body lands in Task 10 (build with a minimal inline editor stub so the page compiles and is demoable).

- [ ] **Step 1: NavItem + routing**

In `Pomvox/Sources/RootView.swift`:

```swift
enum NavItem: String, CaseIterable, Identifiable {
    case home, history, dictionary, settings, setup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"; case .history: "History"
        case .dictionary: "Dictionary"
        case .settings: "Settings"; case .setup: "Setup"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"; case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        case .settings: "gearshape"; case .setup: "checkmark.shield"
        }
    }
}
```

And in the `detail` switch add:

```swift
        case .dictionary: DictionaryView()
```

- [ ] **Step 2: Run the full suite** — `FirstRunRoutingTests` and any `NavItem` pinning tests must still pass (fix enumerations if they assert exact case lists; the firstRun decision logic takes no NavItem input so it should be untouched).

- [ ] **Step 3: Shared store injection**

In `Pomvox/Sources/PomvoxApp.swift`, find where `HubModel()` etc. are constructed as `@StateObject` and injected with `.environmentObject(...)`; add:

```swift
    @StateObject private var dictionary = DictionaryStore()
```

and chain `.environmentObject(dictionary)` wherever the other environment objects are attached.

- [ ] **Step 4: The page**

Create `Pomvox/Sources/DictionaryView.swift`. Follow HistoryView's structure (Toolbar + metaBar + ScrollView) and the design tokens. Complete skeleton (adjust spacing/styling to match neighbors after reading `DesignSystem.swift`):

```swift
import SwiftUI

/// The Dictionary page: words the cleanup model should spell your way,
/// misheard-term fixup rules (many-to-one, per-rule toggle, hit counts), and
/// a live test box that shows exactly what the rules do to any text.
struct DictionaryView: View {
    @EnvironmentObject var store: DictionaryStore
    @State private var newWord = ""
    @State private var editorState: RuleEditorState?   // Task 10 presents the sheet
    @State private var testText = ""
    @State private var stats: [String: DictionaryRuleStats] = DictionaryStatsStore.shared.allStats()

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Dictionary") {
                if store.applyingHint {
                    Chip(text: "Applying…", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if let err = store.parseError { parseErrorBanner(err) }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    wordsSection
                    rulesSection
                    testSection
                }
                .padding(.horizontal, 34).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $editorState) { state in
            RuleEditorSheet(state: state)   // Task 10
        }
        .onReceive(NotificationCenter.default
            .publisher(for: .pomvoxDictionaryStatsDidChange)
            .receive(on: RunLoop.main)) { _ in
            stats = DictionaryStatsStore.shared.allStats()
        }
    }

    // MARK: - Sections

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Words",
                          subtitle: "Pomvox tells the cleanup model to spell these your way.")
            FlowLayout(spacing: 6) {
                ForEach(store.file.words, id: \.self) { word in
                    WordChip(word: word) { store.removeWord(word) }
                }
                TextField("Add a word…", text: $newWord)
                    .textFieldStyle(.plain).font(Typo.ui(12.5))
                    .frame(width: 120)
                    .onSubmit {
                        store.addWord(newWord)
                        newWord = ""
                    }
            }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Fixups",
                              subtitle: "When Pomvox hears the left side, it writes the right side. Always applied — even with cleanup off.")
                Spacer()
                Button {
                    editorState = RuleEditorState(editing: nil)
                } label: {
                    Chip(text: "New rule", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New fixup rule")
            }
            if store.file.rules.isEmpty {
                Text("No rules yet. Add one here, or select a mistake in History and choose “Fix this…”.")
                    .font(Typo.ui(12.5)).foregroundStyle(Palette.muted)
            }
            ForEach(store.file.rules) { rule in
                RuleRow(rule: rule, stats: stats[rule.id],
                        onToggle: { store.setRuleEnabled(id: rule.id, $0) },
                        onEdit: { editorState = RuleEditorState(editing: rule) },
                        onDelete: { store.removeRule(id: rule.id) })
            }
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Try it",
                          subtitle: "Type anything (or paste a transcript) and watch the rules apply.")
            TextField("say something pomvox would mishear…", text: $testText, axis: .vertical)
                .textFieldStyle(.plain).font(Typo.ui(13))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.pane2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hair, lineWidth: 0.5))
            if !testText.isEmpty {
                let applied = PomvoxDictionary(file: store.file).applyReporting(testText)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 11)).foregroundStyle(Palette.ember)
                    Text(applied.text.isEmpty ? "(everything removed)" : applied.text)
                        .font(Typo.ui(13)).foregroundStyle(Palette.ink)
                }
                if !applied.fired.isEmpty {
                    Text("\(applied.fired.count) rule\(applied.fired.count == 1 ? "" : "s") fired")
                        .font(Typo.ui(11)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Typo.display(17)).foregroundStyle(Palette.ink)
            Text(subtitle).font(Typo.ui(12)).foregroundStyle(Palette.muted)
        }
    }

    private func parseErrorBanner(_ err: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13)).foregroundStyle(Palette.ember)
            Text("dictionary.toml couldn’t be read — \(err). Fix the file, then reload. In-app edits are paused so your changes aren’t overwritten.")
                .font(Typo.ui(12.5)).foregroundStyle(Palette.ink)
            Spacer()
            Button("Reload") { store.reloadFromDisk() }
                .buttonStyle(.plain).font(Typo.ui(12.5, .semibold)).foregroundStyle(Palette.ember)
        }
        .padding(.horizontal, 34).padding(.vertical, 11)
        .background(Palette.emberSoft)
    }
}

/// Identifiable wrapper so `.sheet(item:)` drives the editor (Task 10 fills in
/// the sheet body; `seedSources`/`referenceTranscript` feed add-from-History).
struct RuleEditorState: Identifiable {
    let id = UUID()
    var editing: DictionaryRule?
    var seedSources: [String] = []
    var referenceTranscript: String? = nil
}

private struct WordChip: View {
    let word: String
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(word).font(Typo.ui(12.5)).foregroundStyle(Palette.ink)
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(word)")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Palette.pane2))
        .overlay(Capsule().stroke(Palette.hair, lineWidth: 0.5))
        .onHover { hovering = $0 }
    }
}

private struct RuleRow: View {
    let rule: DictionaryRule
    let stats: DictionaryRuleStats?
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: onToggle))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel("Enable rule for \(rule.target.isEmpty ? "removal" : rule.target)")
            FlowLayout(spacing: 4) {
                ForEach(rule.sources, id: \.self) { s in
                    Text(s).font(Typo.ui(12))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Palette.pane2))
                }
            }
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Palette.muted)
            if rule.target.isEmpty {
                Chip(text: "removes", systemImage: "scissors")
            } else {
                Text(rule.target).font(Typo.ui(13, .semibold)).foregroundStyle(Palette.ink)
            }
            Spacer()
            if let s = stats {
                Text("×\(s.count)").font(Typo.ui(11)).monospacedDigit().foregroundStyle(Palette.muted)
                    .help("Fired \(s.count) time\(s.count == 1 ? "" : "s"), last \(Date(timeIntervalSince1970: s.lastFired).formatted(.relative(presentation: .named)))")
            }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(Palette.muted)
                .accessibilityLabel("Edit rule")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Palette.muted)
                .accessibilityLabel("Delete rule")
        }
        .padding(.vertical, 7)
        .opacity(rule.enabled ? 1 : 0.55)
    }
}

/// Minimal wrap layout for chips (macOS 14 `Layout`).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layout(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for i in row.range {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                    proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var range: Range<Int>; var y: CGFloat; var height: CGFloat }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var start = 0, x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(Row(range: start..<i, y: y, height: rowHeight))
                y += rowHeight + spacing
                start = i; x = 0; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        rows.append(Row(range: start..<subviews.count, y: y, height: rowHeight))
        return rows
    }
}
```

Add a temporary stub so the page compiles before Task 10:

```swift
/// Placeholder until Task 10 lands the real editor.
struct RuleEditorSheet: View {
    let state: RuleEditorState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack { Text("Rule editor (Task 10)"); Button("Close") { dismiss() } }
            .padding(30)
    }
}
```

- [ ] **Step 5: Build + suite green; launch and eyeball**

```bash
cd ~/dev/murmur/Pomvox && xcodegen generate && \
xcodebuild -scheme Pomvox -configuration Debug -derivedDataPath /tmp/pomvox-dd build 2>&1 | tail -3
```

Launch `/tmp/pomvox-dd/Build/Products/Debug/Pomvox.app`, open the Hub → Dictionary: add a word, add nothing to rules yet, type in the test box. Words must persist to `~/.pomvox/dictionary.toml`.

- [ ] **Step 6: Commit** — `feat(dictionary): Dictionary page — words, rules, live test box`.

---

### Task 10: Rule editor sheet with variant suggestions + word picker

**Files:**
- Modify: `Pomvox/Sources/DictionaryView.swift` (replace the `RuleEditorSheet` stub)
- Test: pure logic already covered (VariantGenerator, DictionaryStore.upsert); sheet is UI-only.

**Interfaces:**
- Consumes: `RuleEditorState` (Task 9), `VariantGenerator.heuristicVariants` (Task 8), `DictionaryStore.upsert(_:replacingID:)` (Task 6), `PomvoxDictionary` for the in-sheet preview (Task 3).
- Produces: the real `RuleEditorSheet` — target field, source chips, suggested-variant chips (pre-checked, editable), optional tappable-word transcript picker (used by Task 11), live preview line, Save/Cancel.

- [ ] **Step 1: Replace the stub**

```swift
/// Rule editor: target ("what Pomvox should write"), sources ("what it
/// hears"), generated variant suggestions as toggleable chips (visible,
/// consented — never silently added), an optional tappable transcript (the
/// add-from-History path seeds it), and a live preview against sample text.
struct RuleEditorSheet: View {
    let state: RuleEditorState
    @EnvironmentObject var store: DictionaryStore
    @Environment(\.dismiss) private var dismiss

    @State private var target = ""
    @State private var sources: [String] = []
    @State private var newSource = ""
    @State private var suggestions: [String] = []       // offered, not yet accepted
    @State private var accepted: Set<String> = []       // checked suggestion chips
    @State private var previewText = ""

    private var isEditing: Bool { state.editing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isEditing ? "Edit fixup" : "New fixup")
                .font(Typo.display(18)).foregroundStyle(Palette.ink)

            VStack(alignment: .leading, spacing: 6) {
                Text("POMVOX SHOULD WRITE").font(Typo.ui(10, .semibold)).tracking(0.6)
                    .foregroundStyle(Palette.muted)
                TextField("e.g. Pomvox — leave empty to remove the heard words", text: $target)
                    .textFieldStyle(.roundedBorder).font(Typo.ui(13))
                    .onChange(of: target) { _, t in refreshSuggestions(for: t) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WHEN IT HEARS").font(Typo.ui(10, .semibold)).tracking(0.6)
                    .foregroundStyle(Palette.muted)
                FlowLayout(spacing: 6) {
                    ForEach(sources, id: \.self) { s in
                        HStack(spacing: 4) {
                            Text(s).font(Typo.ui(12.5))
                            Button { sources.removeAll { $0 == s } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(s)")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Palette.pane2))
                    }
                    TextField("add what it hears…", text: $newSource)
                        .textFieldStyle(.plain).font(Typo.ui(12.5)).frame(width: 140)
                        .onSubmit { addSource(newSource); newSource = "" }
                }
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LIKELY MISHEARINGS — TAP TO INCLUDE")
                        .font(Typo.ui(10, .semibold)).tracking(0.6).foregroundStyle(Palette.muted)
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions, id: \.self) { v in
                            let on = accepted.contains(v)
                            Button {
                                if on { accepted.remove(v) } else { accepted.insert(v) }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 10))
                                    Text(v).font(Typo.ui(12.5))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(on ? Palette.sel : Palette.pane2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(on ? "Exclude" : "Include") variant \(v)")
                        }
                    }
                }
            }

            if let transcript = state.referenceTranscript {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FROM YOUR TRANSCRIPT — TAP THE WORDS IT GOT WRONG")
                        .font(Typo.ui(10, .semibold)).tracking(0.6).foregroundStyle(Palette.muted)
                    FlowLayout(spacing: 4) {
                        ForEach(Array(tokenize(transcript).enumerated()), id: \.offset) { _, word in
                            Button { appendToPendingSource(word) } label: {
                                Text(word).font(Typo.ui(12.5))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Palette.pane2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !newSource.isEmpty {
                        Text("building: “\(newSource)” — press return to add")
                            .font(Typo.ui(11)).foregroundStyle(Palette.muted)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("PREVIEW").font(Typo.ui(10, .semibold)).tracking(0.6)
                    .foregroundStyle(Palette.muted)
                TextField("type a sentence to test this rule…", text: $previewText)
                    .textFieldStyle(.roundedBorder).font(Typo.ui(12.5))
                if !previewText.isEmpty {
                    Text(previewApplied())
                        .font(Typo.ui(12.5)).foregroundStyle(Palette.ember)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add rule") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(effectiveSources().isEmpty)
            }
        }
        .padding(26)
        .frame(width: 480)
        .onAppear {
            if let r = state.editing {
                target = r.target
                sources = r.sources
            } else {
                sources = state.seedSources
            }
            refreshSuggestions(for: target)
        }
    }

    private func addSource(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !sources.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame })
        else { return }
        sources.append(t)
    }

    /// Word-picker taps build a phrase in the pending-source field so
    /// multi-word mishearings ("pom box") are two taps, then return.
    private func appendToPendingSource(_ word: String) {
        newSource = newSource.isEmpty ? word : newSource + " " + word
    }

    private func refreshSuggestions(for term: String) {
        let already = Set(sources.map { $0.lowercased() })
        suggestions = VariantGenerator.heuristicVariants(for: term)
            .filter { !already.contains($0) }
        accepted = Set(suggestions)   // pre-checked, user unchecks noise
    }

    private func effectiveSources() -> [String] {
        sources + suggestions.filter { accepted.contains($0) }
    }

    private func previewApplied() -> String {
        let rule = DictionaryRule(sources: effectiveSources(), target: target,
                                  enabled: true, origin: "manual")
        return PomvoxDictionary(file: DictionaryFile(rules: [rule]))
            .apply(previewText)
    }

    private func save() {
        let origin = state.editing?.origin
            ?? (state.referenceTranscript != nil ? "history"
                : accepted.isEmpty ? "manual" : "variant")
        store.upsert(
            DictionaryRule(sources: effectiveSources(), target: target,
                           enabled: state.editing?.enabled ?? true, origin: origin),
            replacingID: state.editing?.id)
        dismiss()
    }

    private func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }
}
```

- [ ] **Step 2: Build, launch, and exercise**

Rebuild + relaunch (Task 9 Step 5 commands). In the Dictionary page: New rule → type target "ChargeBee" → variant chips appear pre-checked → uncheck one → add a manual source → preview a sentence → Save. Edit the rule; delete it. Then dictate once (or use the test box) to confirm hot-apply: a rule saved while armed must affect the *next* utterance without re-arm — watch `log stream --predicate 'process == "Pomvox"'` for `dictionary: hot-reloaded`.

- [ ] **Step 3: Full suite, commit** — `feat(dictionary): rule editor with consented variant suggestions`.

---

### Task 11: Add-from-History

**Files:**
- Modify: `Pomvox/Sources/Components.swift` (`DictationRow` gains an optional `onFix` action)
- Modify: `Pomvox/Sources/HistoryView.swift` (pass the action, present the editor sheet)

**Interfaces:**
- Consumes: `RuleEditorState(editing:seedSources:referenceTranscript:)` + `RuleEditorSheet` (Tasks 9/10), `Dictation` (`.raw`, `.final` — existing).
- Produces: a "Fix a misheard word" affordance on every History row.

- [ ] **Step 1: Extend DictationRow**

In `Pomvox/Sources/Components.swift`, add to `DictationRow`'s stored properties (after `showDelete`):

```swift
    var onFix: ((Dictation) -> Void)? = nil
```

In its hover-actions cluster (find where the delete/reinsert buttons render, and match their exact style), add before them:

```swift
                if let onFix {
                    Button { onFix(dictation) } label: {
                        Image(systemName: "character.book.closed")
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help("Fix a misheard word…")
                    .accessibilityLabel("Fix a misheard word from this dictation")
                }
```

- [ ] **Step 2: Wire HistoryView**

In `Pomvox/Sources/HistoryView.swift` add state + sheet:

```swift
    @State private var fixState: RuleEditorState?
```

Change the row construction to:

```swift
                            DictationRow(dictation: d, dateStyle: .calendar, showDelete: true,
                                         onFix: { fixState = RuleEditorState(
                                             editing: nil, seedSources: [],
                                             referenceTranscript: $0.raw) })
```

And attach to the outer VStack:

```swift
        .sheet(item: $fixState) { RuleEditorSheet(state: $0) }
```

- [ ] **Step 3: Build, launch, verify** — hover a History row → book icon → sheet opens with the raw transcript as tappable words → tap "pom" then "box" → return → type target → Save → rule appears on the Dictionary page with `origin = "history"` in the TOML.

- [ ] **Step 4: Full suite, commit** — `feat(dictionary): one-click fixup from History transcripts`.

---

### Task 12: Global quick-add hotkey + floating panel

**Files:**
- Create: `Pomvox/Sources/QuickAdd.swift` (parser + panel + controller + view)
- Modify: `Pomvox/Sources/SettingsStore.swift` (`quickAdd` key, default `""`)
- Modify: `Pomvox/Sources/SettingsView.swift` (row in the Hotkeys pane — read the pane first and copy the existing hotkey-row idiom exactly)
- Modify: `Pomvox/Sources/AppDelegate.swift` (instantiate the controller in `applicationDidFinishLaunching`)
- Test: `Pomvox/Tests/QuickAddHotkeyTests.swift`, extend `Pomvox/Tests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `DictionaryStore` mutators (Task 6) — the panel writes through a store instance it owns (stores converge via file + notifications); `SettingsIO` read/apply pattern (existing).
- Produces: `enum QuickAddHotkey { static func parse(_ s: String) -> (flags: NSEvent.ModifierFlags, keyCode: UInt16)?; static func matches(_ event: NSEvent, _ binding: (flags: NSEvent.ModifierFlags, keyCode: UInt16)) -> Bool }`; `@MainActor final class QuickAddController { init(); func start(binding: String) }`; config key `[hotkey] quick_add` (default `""` = off, restart-required like the other hotkeys).

- [ ] **Step 1: Write the failing parser tests**

Create `Pomvox/Tests/QuickAddHotkeyTests.swift`:

```swift
import XCTest
import AppKit
@testable import Pomvox

final class QuickAddHotkeyTests: XCTestCase {

    func testParsesCmdShiftLetter() throws {
        let b = try XCTUnwrap(QuickAddHotkey.parse("cmd+shift+d"))
        XCTAssertTrue(b.flags.contains(.command))
        XCTAssertTrue(b.flags.contains(.shift))
        XCTAssertEqual(b.keyCode, 2)   // ANSI d
    }

    func testParsesCtrlAltDigit() throws {
        let b = try XCTUnwrap(QuickAddHotkey.parse("ctrl+alt+1"))
        XCTAssertTrue(b.flags.contains(.control))
        XCTAssertTrue(b.flags.contains(.option))
        XCTAssertEqual(b.keyCode, 18)  // ANSI 1
    }

    func testOptionAliases() {
        XCTAssertNotNil(QuickAddHotkey.parse("option+cmd+p"))
        XCTAssertNotNil(QuickAddHotkey.parse("alt+cmd+p"))
    }

    func testRejectsNoModifier() {
        XCTAssertNil(QuickAddHotkey.parse("d"))          // bare key would fire while typing
    }

    func testRejectsUnknownKeyAndEmpty() {
        XCTAssertNil(QuickAddHotkey.parse(""))
        XCTAssertNil(QuickAddHotkey.parse("cmd+µ"))
        XCTAssertNil(QuickAddHotkey.parse("cmd+"))
    }

    func testCaseAndWhitespaceInsensitive() {
        XCTAssertNotNil(QuickAddHotkey.parse(" CMD + Shift + D "))
    }
}
```

Extend `Pomvox/Tests/SettingsStoreTests.swift` — find the round-trip test that writes and re-reads `SettingsValues` and add `quickAdd` coverage following its exact shape; minimally:

```swift
    func testQuickAddHotkeyRoundTrips() {
        var v = SettingsValues.defaults
        XCTAssertEqual(v.quickAdd, "")
        v.quickAdd = "cmd+shift+d"
        var doc = ConfigDocument(text: "")
        SettingsIO.applyAll(v, to: &doc)
        XCTAssertEqual(SettingsIO.read(doc).quickAdd, "cmd+shift+d")
    }
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Settings plumbing**

In `Pomvox/Sources/SettingsStore.swift`:
- `SettingsValues`: add `var quickAdd: String` under the Hotkeys group; add `quickAdd: ""` to `.defaults`.
- `SettingsIO.read`: add `quickAdd: doc.string("hotkey", "quick_add") ?? d.quickAdd,`.
- `SettingsIO.apply`: add `setString("hotkey", "quick_add", v.quickAdd, c?.quickAdd)`.
- `SettingsModel.pendingRestart`: extend the hotkeys comparison to include `values.quickAdd != saved.quickAdd` (fold into the existing array comparison).

In `Pomvox/Sources/SettingsView.swift`, Hotkeys pane: read the existing rows for `ptt`/`toggle` and add a row for "Quick-add to Dictionary" bound to `model.values.quickAdd`, with help text: `"e.g. cmd+shift+d — leave empty to disable. Needs at least one modifier."`. Copy the existing row idiom exactly (control type, labels, validation display).

- [ ] **Step 4: Parser, panel, controller**

Create `Pomvox/Sources/QuickAdd.swift`:

```swift
import AppKit
import SwiftUI

/// `[hotkey] quick_add` parser: "cmd+shift+d" → (modifier flags, ANSI
/// keycode). At least one modifier is required — a bare key would fire on
/// every keystroke of normal typing. Separate from HotkeyMachine on purpose:
/// dictation keys are modifier-state machines on a CGEventTap; this is a
/// plain chord on an NSEvent monitor, active even when the engine is off.
enum QuickAddHotkey {
    private static let modifiers: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "command": .command,
        "shift": .shift,
        "alt": .option, "option": .option, "opt": .option,
        "ctrl": .control, "control": .control,
    ]

    /// ANSI virtual keycodes (HIToolbox Events.h) for letters and digits.
    private static let keycodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
        "8": 28, "9": 25, "0": 29,
    ]

    static func parse(_ s: String) -> (flags: NSEvent.ModifierFlags, keyCode: UInt16)? {
        let parts = s.lowercased().components(separatedBy: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let keyName = parts.last,
              let keyCode = keycodes[keyName] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for mod in parts.dropLast() {
            guard let f = modifiers[mod] else { return nil }
            flags.insert(f)
        }
        guard !flags.isEmpty else { return nil }
        return (flags, keyCode)
    }

    static func matches(_ event: NSEvent,
                        _ binding: (flags: NSEvent.ModifierFlags, keyCode: UInt16)) -> Bool {
        event.keyCode == binding.keyCode
            && event.modifierFlags.intersection([.command, .shift, .option, .control])
                == binding.flags
    }
}

/// Borderless non-activating panel: it takes key status for its text fields
/// without activating Pomvox, so closing it lands focus back in the app the
/// user was in — the whole point of quick-add.
final class QuickAddPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the global/local key monitors and the panel. Constructed once in
/// AppDelegate; inert when the binding is empty or unparseable. The global
/// monitor only delivers events while the app has an input-monitoring grant —
/// the same grant Setup already requires for dictation.
@MainActor
final class QuickAddController {
    private var binding: (flags: NSEvent.ModifierFlags, keyCode: UInt16)?
    private var panel: QuickAddPanel?
    private let store = DictionaryStore()

    func start(bindingString: String) {
        guard !bindingString.isEmpty else { return }
        guard let parsed = QuickAddHotkey.parse(bindingString) else {
            NSLog("quick-add: invalid [hotkey] quick_add %@ — disabled", bindingString)
            return
        }
        binding = parsed
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var swallowed = false
            MainActor.assumeIsolated {
                if let self, let b = self.binding, QuickAddHotkey.matches(event, b) {
                    self.togglePanel(); swallowed = true
                }
            }
            return swallowed ? nil : event
        }
        NSLog("quick-add: armed on %@", bindingString)
    }

    private func handle(_ event: NSEvent) {
        guard let b = binding, QuickAddHotkey.matches(event, b) else { return }
        togglePanel()
    }

    private func togglePanel() {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        let p = panel ?? makePanel()
        panel = p
        p.center()
        p.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> QuickAddPanel {
        let p = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView:
            QuickAddView(store: store, close: { [weak p] in p?.close() }))
        return p
    }
}

/// Word field + optional "misheard as" field. Return saves; word-only goes to
/// the words list, both fields make a fixup rule. Escape closes.
private struct QuickAddView: View {
    @ObservedObject var store: DictionaryStore
    let close: () -> Void
    @State private var word = ""
    @State private var misheard = ""
    @FocusState private var wordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to Pomvox dictionary").font(Typo.ui(13, .semibold)).foregroundStyle(Palette.ink)
            TextField("Word or phrase (how it should be written)", text: $word)
                .textFieldStyle(.roundedBorder).font(Typo.ui(13))
                .focused($wordFocused)
                .onSubmit(save)
            TextField("Misheard as… (optional — makes a fixup rule)", text: $misheard)
                .textFieldStyle(.roundedBorder).font(Typo.ui(13))
                .onSubmit(save)
            HStack {
                Text("↩ save · esc close").font(Typo.ui(10.5)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { wordFocused = true }
        .onExitCommand(perform: close)
    }

    private func save() {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        let heard = misheard.trimmingCharacters(in: .whitespaces)
        if heard.isEmpty {
            store.addWord(w)
        } else {
            store.upsert(DictionaryRule(sources: [heard], target: w,
                                        enabled: true, origin: "manual"),
                         replacingID: nil)
        }
        word = ""; misheard = ""
        close()
    }
}
```

In `Pomvox/Sources/AppDelegate.swift` add a property + start call inside `applicationDidFinishLaunching` (after `bootstrap()`):

```swift
    private let quickAdd = QuickAddController()
```

```swift
        quickAdd.start(bindingString:
            ConfigDocument.load(path: SettingsModel.defaultPath())
                .string("hotkey", "quick_add") ?? "")
```

- [ ] **Step 5: Run parser + settings tests, then full suite.**

- [ ] **Step 6: On-device check** — set `quick_add = "cmd+shift+d"` under `[hotkey]` in `~/.pomvox/config.toml`, relaunch, focus TextEdit, hit the chord: panel appears WITHOUT Pomvox activating (TextEdit's menu bar stays); type a word, return; focus lands back in TextEdit; the word is in the Dictionary page.

- [ ] **Step 7: Commit** — `feat(dictionary): global quick-add hotkey + floating panel`.

---

### Task 13: LLM variant suggestions (merged into the editor)

**Files:**
- Modify: `Pomvox/Sources/Engine/CleanupEngine.swift` (add `suggestVariants`)
- Modify: `Pomvox/Sources/DictionaryView.swift` (`RuleEditorSheet.refreshSuggestions` merges the async results)
- Test: parsing helper only (the actor method needs the 2.3 GB model — on-device verification instead). Create `Pomvox/Tests/VariantParsingTests.swift`.

**Interfaces:**
- Consumes: `CleanupEngine` internals (`container`, `toChat`, generate machinery — mirror `clean()`), `VariantGenerator` (Task 8).
- Produces: `CleanupEngine.suggestVariants(for term: String, timeoutS: Double) async -> [String]`; free function `func parseVariantLines(_ raw: String, term: String) -> [String]` (in VariantGenerator.swift, testable).

- [ ] **Step 1: Write the failing parsing tests**

Create `Pomvox/Tests/VariantParsingTests.swift`:

```swift
import XCTest
@testable import Pomvox

final class VariantParsingTests: XCTestCase {

    func testParsesOnePerLineStrippingBulletsAndNumbers() {
        let raw = "- pom box\n2. palm vox\n* pomm vocks\n"
        XCTAssertEqual(parseVariantLines(raw, term: "Pomvox"),
                       ["pom box", "palm vox", "pomm vocks"])
    }

    func testDropsEchoesBlanksAndLongJunk() {
        let raw = "Pomvox\n\npom box\nthis is a whole explanatory sentence about the word\n"
        XCTAssertEqual(parseVariantLines(raw, term: "Pomvox"), ["pom box"])
    }

    func testLowercasesAndDedupes() {
        XCTAssertEqual(parseVariantLines("Pom Box\npom box\n", term: "Pomvox"), ["pom box"])
    }

    func testCapsAtSix() {
        let raw = (1...10).map { "variant \($0)" }.joined(separator: "\n")
        XCTAssertEqual(parseVariantLines(raw, term: "X").count, 6)
    }
}
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement the parser** (append to `Pomvox/Sources/Engine/VariantGenerator.swift`):

```swift
/// Clean an LLM "list the mishearings" response into chip-ready variants:
/// strip bullets/numbering, lowercase, drop echoes of the term itself, drop
/// anything over 5 words (explanatory prose, not a variant), dedupe, cap at 6.
func parseVariantLines(_ raw: String, term: String) -> [String] {
    var out: [String] = []
    for line in raw.components(separatedBy: "\n") {
        var t = line.trimmingCharacters(in: .whitespaces)
        while let first = t.first, "-*•0123456789. )".contains(first) {
            t.removeFirst()
        }
        t = t.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty,
              t.caseInsensitiveCompare(term) != .orderedSame,
              t.components(separatedBy: " ").count <= 5,
              !out.contains(t) else { continue }
        out.append(t)
        if out.count == 6 { break }
    }
    return out
}
```

- [ ] **Step 4: The actor method**

In `Pomvox/Sources/Engine/CleanupEngine.swift`, after `clean(...)`:

```swift
    /// One-shot "what might the STT model write for ⟨term⟩?" generation for
    /// the rule editor's suggestion chips. nil-equivalent (empty) when the
    /// model isn't resident — the editor's heuristics are the floor and this
    /// is opportunistic garnish; it must never trigger a 2.3 GB load.
    func suggestVariants(for term: String, timeoutS: Double = 8.0) async -> [String] {
        guard let container else { return [] }
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutS
        let raw: String? = try? await container.perform { context in
            let chat: [Chat.Message] = [
                .system("""
                You help a dictation app anticipate speech-to-text errors. \
                Given a word, list up to 5 plausible ways an STT model might \
                mistranscribe it when spoken aloud. One per line, lowercase, \
                no explanations, no numbering.
                """),
                .user(term),
            ]
            let lmInput = try await context.processor.prepare(
                input: UserInput(chat: chat, additionalContext: ["enable_thinking": false]))
            let params = GenerateParameters(maxTokens: 80, temperature: 0.0)
            let stream = try MLXLMCommon.generate(
                input: lmInput, cache: nil, parameters: params, context: context)
            var parts: [String] = []
            for await generation in stream {
                if case .chunk(let piece) = generation {
                    parts.append(piece)
                    if CFAbsoluteTimeGetCurrent() > deadline { return parts.joined() }
                }
            }
            return parts.joined()
        }
        return parseVariantLines(raw ?? "", term: term)
    }
```

**Build note:** `MLXLMCommon.generate(input:cache:parameters:context:)` was called with token arrays in `clean()`; here we pass the prepared `LMInput` directly — check `clean()`'s exact overload if the compiler complains, and mirror it (`LMInput(tokens:)` from `lmInput.text.tokens` if needed).

- [ ] **Step 5: Merge into the editor**

The engine is a singleton (`NativeEngine.shared`, NativeEngine.swift:167) and its `cleanup` actor is `private let cleanup = CleanupEngine()` (line 63). Add an accessor next to that property:

```swift
    /// UI access for the rule editor's variant suggestions — read-only use of
    /// the actor; `cleanup` is a `let`, so this is safe off the main actor.
    nonisolated var variantSuggester: CleanupEngine { cleanup }
```

Then in `RuleEditorSheet.refreshSuggestions(for:)`, after setting the heuristic suggestions, append:

```swift
        let current = target
        Task {
            let llm = await NativeEngine.shared.variantSuggester.suggestVariants(for: current)
            await MainActor.run {
                guard current == target else { return }   // stale — target changed
                let known = Set((sources + suggestions).map { $0.lowercased() })
                let fresh = llm.filter { !known.contains($0) }
                suggestions.append(contentsOf: fresh)
                // LLM extras arrive UNCHECKED — heuristics are pre-checked,
                // model guesses are offered. (accepted is untouched here.)
            }
        }
```

(`nonisolated` stored-`let` access compiles because `CleanupEngine` is an actor reference; if the compiler objects to `private let` + `nonisolated`, make the property `nonisolated(unsafe)` or hop via `await MainActor.run { NativeEngine.shared.variantSuggester }` — smallest fix wins.)

- [ ] **Step 6: Run tests (parser green, suite green); on-device sanity** — with the engine armed and cleanup loaded, type a target in the rule editor: heuristic chips render instantly, LLM chips join ~1–3 s later, unchecked.

- [ ] **Step 7: Commit** — `feat(dictionary): LLM-suggested misheard variants in the rule editor`.

---

### Task 14: Import/export UI, telemetry, docs, on-device verification

**Files:**
- Modify: `Pomvox/Sources/DictionaryView.swift` (import/export buttons in the toolbar area)
- Modify: `Pomvox/Sources/Telemetry.swift` (one event + one prop)
- Modify: `Pomvox/Sources/Engine/NativeEngine.swift` (fired count prop on dictation_completed)
- Modify: `config.example.toml`, `README.md`, `CHANGELOG.md`
- Test: extend `Pomvox/Tests/TelemetryTests.swift` if it pins the event-name list.

- [ ] **Step 1: Import/export buttons**

In `DictionaryView`, next to the "New rule" button, add:

```swift
                Menu {
                    Button("Import words (.txt)…") { importFile(kind: .words) }
                    Button("Import rules (.csv)…") { importFile(kind: .rules) }
                    Divider()
                    Button("Export words (.txt)…") { exportFile(kind: .words) }
                    Button("Export rules (.csv)…") { exportFile(kind: .rules) }
                } label: {
                    Chip(text: "Import / Export", systemImage: "square.and.arrow.up.on.square")
                }
                .menuStyle(.borderlessButton).fixedSize()
```

with the handlers (NSOpenPanel/NSSavePanel; import merges through the store so dedupe is free):

```swift
    private enum InterchangeKind { case words, rules }

    private func importFile(kind: InterchangeKind) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.begin { resp in
            guard resp == .OK, let url = panel.url,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            switch kind {
            case .words: DictionaryInterchange.parseWordList(text).forEach(store.addWord)
            case .rules: DictionaryInterchange.parseRulesCSV(text)
                .forEach { store.upsert($0, replacingID: nil) }
            }
        }
    }

    private func exportFile(kind: InterchangeKind) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = kind == .words ? "pomvox-words.txt" : "pomvox-rules.csv"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            let text = kind == .words
                ? DictionaryInterchange.wordList(store.file.words)
                : DictionaryInterchange.rulesCSV(store.file.rules)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
```

- [ ] **Step 2: Telemetry (counts only, never text)**

In `Pomvox/Sources/Telemetry.swift`:
- `TelemetryEventName`: add `case dictionaryEdited = "dictionary_edited"`.
- `TelemetryProps`: add `var dictionaryFired: Int?` and `var addedVia: String?  // page | history | hotkey | variant — enum-shaped, never content` (follow the sanitizer's field handling — find where existing props are encoded/sanitized and mirror; run `TelemetryTests`).

In `DictionaryStore.save(wordsChanged:)` (after the notification post):

```swift
        TelemetryClient.shared.emit(.dictionaryEdited)
```

In `NativeEngine` finish(), extend the existing `dictationCompleted` props block:

```swift
                props.dictionaryFired = applied.fired.isEmpty ? nil : applied.fired.count
```

- [ ] **Step 3: Docs**

- `config.example.toml`: under the existing `[dictionary]` section add a comment: `# v0.2: words + rules now live in ~/.pomvox/dictionary.toml (auto-migrated on first launch; this section is read only if that file doesn't exist). "enabled" here still gates the feature.`
- `README.md`: refresh the dictionary feature bullet(s) to mention the Dictionary page, live test box, add-from-History, quick-add hotkey, and instant apply.
- `CHANGELOG.md`: add an Unreleased entry listing the Phase 1 features.

- [ ] **Step 4: Full-suite green + on-device verification pass (wiki playbook)**

Per `~/vaults/pomvox-wiki/20 Code Review/Verification Playbook.md` — Debug build, live `/usr/bin/log stream --predicate 'process == "Pomvox"'`:

1. Fresh config with legacy `[dictionary]` section → launch → `dictionary.toml` created with migrated content; log line `dictionary: migrated …`.
2. Arm; dictate "pom box" with a `pom box → Pomvox` rule → pasted text says Pomvox; rule's hit count increments on the page.
3. Add a rule WHILE ARMED → log `dictionary: hot-reloaded` → next utterance already fixed (no re-arm).
4. Add a WORD while armed with cleanup on → "Applying…" chip shows then clears; log `cleanup: prefix caches rebuilt`.
5. Wipe rule "um" → dictate "um hello um" → "hello", no stray punctuation; dictate only "um" → HUD flash "your replacement rules removed every word — check the Dictionary page".
6. Malformed hand-edit of dictionary.toml → page shows the banner with line number; dictation still works (empty/last-good set); Reload after fixing recovers.
7. Quick-add chord from TextEdit (Task 12 Step 6 script).
8. History → Fix this… flow (Task 11 Step 3 script).

- [ ] **Step 5: Commit** — `feat(dictionary): import/export, telemetry counts, docs` — then update the wiki (`30 Design Specs/Spec - Dictionary.md` gets a "superseded by Dictionary v2 Phase 1" pointer; `40 Roadmap` moves Phase 1 to shipped, Phases 2–3 into Next/Later).

---

## Plan self-review notes (already applied)

- **Spec coverage:** data model/storage → Tasks 1/2/6; engine + hot-apply + fired reporting → Tasks 3/4/5; page + test box → Task 9; variants → Tasks 8/13; add-from-History → Tasks 10/11; quick-add → Task 12; import/export + error banner + telemetry + docs → Tasks 6/9/14; wipe-punctuation fix → Task 3; wipe contract preserved → Tasks 3/5 (+ verification 14.4/14.5).
- **Spec deviations (deliberate, reflected in the committed spec):** words hot-apply rebuilds cleanup prefix caches (`updateTermsHint`) instead of a full re-arm — same UX, cheaper; fired rules land in the stats sidecar only (the frozen history schema is not migrated); the rename task from the draft spec is moot (`PomvoxDictionary` already exists in the live repo).
- **Type consistency check:** `DictionaryRule.id` (content-derived) is the key used by `CompiledRule.ruleID`, `DictionaryApplied.fired`, `DictionaryStatsStore`, and `DictionaryStore.upsert(replacingID:)` — one identity everywhere. `RuleEditorState` is shared by page (Task 9), editor (Task 10), and History (Task 11).
