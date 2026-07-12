import Foundation

/// A comment-preserving, surgical editor for `~/.pomvox/config.toml`.
///
/// The Hub owns only a handful of scalar keys; it must never disturb the rest
/// of the file. So instead of parsing to a model and re-serializing (which
/// drops comments — toml++/TOMLKit included), this works line-by-line and
/// rewrites *only the value token* of a key it's told to set. Every untouched
/// byte — comments, unknown sections, blank lines, spacing — survives exactly.
///
/// Scope matches our config: flat `[section]` tables of scalar values
/// (string / bool / int / float). It deliberately does not understand arrays,
/// inline tables, or multi-line strings — it preserves any it sees verbatim
/// and only ever reads/writes the simple keys the settings UI owns.
struct ConfigDocument {
    /// Raw file lines. `text.components(separatedBy: "\n")` round-trips exactly:
    /// a trailing newline shows up as a final empty element we preserve.
    private var lines: [String]

    /// Whether `load` read an actual file (vs. defaulting to empty because the
    /// file was missing/unreadable). Captured from the same read that populated
    /// `lines`, so "does a config exist?" is consistent with the loaded content
    /// — callers must not re-`stat` the path separately, which would open a
    /// TOCTOU window against a config written concurrently. `false` for
    /// in-memory documents built via `init(text:)`.
    private(set) var fileExisted = false

    init(text: String) {
        lines = text.components(separatedBy: "\n")
    }

    /// Load from disk; a missing/unreadable file is an empty document (the
    /// Hub can still build one from defaults), mirroring HistoryReader.
    static func load(path: String) -> ConfigDocument {
        let contents = try? String(contentsOfFile: path, encoding: .utf8)
        var doc = ConfigDocument(text: contents ?? "")
        doc.fileExisted = (contents != nil)
        return doc
    }

    func render() -> String { lines.joined(separator: "\n") }

    /// Atomic write (temp + rename), so the Python watcher never reads a
    /// half-written file mid-save.
    func write(to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        try render().write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Reads

    func string(_ section: String, _ key: String) -> String? {
        guard let t = rawToken(section, key),
              t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 else { return nil }
        return Self.unescape(String(t.dropFirst().dropLast()))
    }

    func bool(_ section: String, _ key: String) -> Bool? {
        switch rawToken(section, key) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    func int(_ section: String, _ key: String) -> Int? {
        rawToken(section, key).flatMap(Int.init)
    }

    func double(_ section: String, _ key: String) -> Double? {
        rawToken(section, key).flatMap(Double.init)
    }

    // MARK: - Read-only array / table helpers
    //
    // The custom dictionary (`[dictionary] words = [...]` and the
    // `[dictionary.replacements]` sub-table) needs shapes the surgical scalar
    // editor doesn't write. These read them (single-line inline array of quoted
    // strings; a table of quoted-string = quoted-string pairs) without changing
    // the write path — the Hub still only ever rewrites scalar values.

    /// An inline array of quoted strings on `key`'s line, e.g. `["a", "b"]`.
    /// `nil` if the key is absent or isn't an array. Single-line only (matches
    /// the dictionary config; a multi-line array reads as nil → defaults).
    func stringArray(_ section: String, _ key: String) -> [String]? {
        guard let i = find(section, key), let eq = lines[i].firstIndex(of: "=") else { return nil }
        var body = String(lines[i][lines[i].index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if let hash = body.firstIndex(of: "#") { body = String(body[..<hash]).trimmingCharacters(in: .whitespaces) }
        guard body.hasPrefix("["), body.hasSuffix("]") else { return nil }
        let inner = String(body.dropFirst().dropLast())
        return Self.splitTopLevelStrings(inner)
    }

    /// All quoted-string key/value pairs under a `[section]` header, in file
    /// order. Quoted keys (`"a b" = "c"`) are unquoted. Comments / blanks /
    /// non-string values are skipped; scanning stops at the next header.
    func stringTable(_ section: String) -> [(key: String, value: String)] {
        guard let header = sectionHeaderIndex(section) else { return [] }
        var out: [(key: String, value: String)] = []
        var i = header + 1
        while i < lines.count {
            if Self.headerName(lines[i]) != nil { break }
            if let pair = Self.stringPair(lines[i]) { out.append(pair) }
            i += 1
        }
        return out
    }

    /// `"key" = "value"` (or bare `key = "value"`) → unquoted pair; nil otherwise.
    private static func stringPair(_ line: String) -> (key: String, value: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#"), !t.hasPrefix("["),
              let eq = line.firstIndex(of: "=") else { return nil }
        let rawKey = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        guard let r = tokenRange(in: line) else { return nil }
        let rawVal = String(line[r])
        guard rawVal.hasPrefix("\""), rawVal.hasSuffix("\""), rawVal.count >= 2 else { return nil }
        let key = unquote(rawKey)
        let value = unescape(String(rawVal.dropFirst().dropLast()))
        return (key, value)
    }

    private static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        return unescape(String(s.dropFirst().dropLast()))
    }

    /// Split `"a", "b"` (the inside of an inline array) into unescaped strings,
    /// respecting quotes so a comma inside a value isn't a separator.
    private static func splitTopLevelStrings(_ inner: String) -> [String] {
        var out: [String] = []
        var i = inner.startIndex
        while i < inner.endIndex {
            while i < inner.endIndex, inner[i] != "\"" { i = inner.index(after: i) }
            guard i < inner.endIndex else { break }
            i = inner.index(after: i)  // past opening quote
            var value = ""             // raw, escapes preserved for one unescape
            while i < inner.endIndex {
                let c = inner[i]
                if c == "\\" {
                    let n = inner.index(after: i)
                    if n < inner.endIndex {
                        value.append(c); value.append(inner[n]); i = inner.index(after: n); continue
                    }
                }
                if c == "\"" { i = inner.index(after: i); break }
                value.append(c)
                i = inner.index(after: i)
            }
            out.append(unescape(value))
        }
        return out
    }

    // MARK: - Writes (typed)

    mutating func set(_ section: String, _ key: String, string value: String) {
        setRaw(section, key, "\"\(Self.escape(value))\"")
    }
    mutating func set(_ section: String, _ key: String, bool value: Bool) {
        setRaw(section, key, value ? "true" : "false")
    }
    mutating func set(_ section: String, _ key: String, int value: Int) {
        setRaw(section, key, String(value))
    }
    mutating func set(_ section: String, _ key: String, double value: Double) {
        setRaw(section, key, Self.tomlFloat(value))
    }

    // MARK: - Surgical write

    private mutating func setRaw(_ section: String, _ key: String, _ rawValue: String) {
        if let i = find(section, key) {
            // Replace only the value token; indent, spacing and any inline
            // comment on this line are left exactly as they were.
            var line = lines[i]
            if let r = Self.tokenRange(in: line) {
                line.replaceSubrange(r, with: rawValue)
                lines[i] = line
                return
            }
        }
        if let header = sectionHeaderIndex(section) {
            lines.insert("\(key) = \(rawValue)", at: keyInsertIndex(afterHeader: header))
            return
        }
        appendSection(section, key, rawValue)
    }

    private mutating func appendSection(_ section: String, _ key: String, _ rawValue: String) {
        let hadTrailingNewline = lines.last == ""
        var body = lines
        if hadTrailingNewline { body.removeLast() }
        // Separate from existing content with one blank line.
        if let last = body.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
            body.append("")
        }
        body.append("[\(section)]")
        body.append("\(key) = \(rawValue)")
        body.append("")  // keep a trailing newline
        lines = body
    }

    // MARK: - Line scanning

    /// Index of the line holding `[section].key`, scanning section by section.
    private func find(_ section: String, _ key: String) -> Int? {
        var current: String?
        for (i, line) in lines.enumerated() {
            if let header = Self.headerName(line) { current = header; continue }
            if current == section, Self.keyName(line) == key { return i }
        }
        return nil
    }

    private func sectionHeaderIndex(_ section: String) -> Int? {
        lines.firstIndex { Self.headerName($0) == section }
    }

    /// Where a new key should go inside an existing section: after the last
    /// content line, before any trailing blanks and the next header.
    private func keyInsertIndex(afterHeader header: Int) -> Int {
        var end = lines.count
        var i = header + 1
        while i < lines.count {
            if Self.headerName(lines[i]) != nil { end = i; break }
            i += 1
        }
        var insert = end
        while insert - 1 > header, lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            insert -= 1
        }
        return insert
    }

    private func rawToken(_ section: String, _ key: String) -> String? {
        guard let i = find(section, key), let r = Self.tokenRange(in: lines[i]) else { return nil }
        return String(lines[i][r])
    }

    /// Section name of a `[name]` header (not `[[array]]`, which we leave alone).
    private static func headerName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), !t.hasPrefix("[["), let close = t.firstIndex(of: "]") else {
            return nil
        }
        return String(t[t.index(after: t.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
    }

    /// Bare key of a `key = value` line (nil for blank / comment / header).
    private static func keyName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#"), !t.hasPrefix("["),
              let eq = line.firstIndex(of: "=") else { return nil }
        return String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
    }

    /// Range of the value token after `=` — the only span `set` ever rewrites.
    /// Reads a quoted string to its closing quote, else a bare token up to
    /// whitespace or an inline `#` comment.
    private static func tokenRange(in line: String) -> Range<String.Index>? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        var idx = line.index(after: eq)
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex else { return idx..<idx }
        let start = idx
        if line[idx] == "\"" {
            idx = line.index(after: idx)
            while idx < line.endIndex {
                let c = line[idx]
                if c == "\\" {
                    idx = line.index(after: idx)
                    if idx < line.endIndex { idx = line.index(after: idx) }
                    continue
                }
                idx = line.index(after: idx)
                if c == "\"" { break }
            }
        } else {
            while idx < line.endIndex, line[idx] != " ", line[idx] != "\t", line[idx] != "#" {
                idx = line.index(after: idx)
            }
        }
        return start..<idx
    }

    // MARK: - Scalar formatting

    private static func tomlFloat(_ v: Double) -> String {
        let s = String(v)
        return (s.contains(".") || s.contains("e") || s.contains("E")) ? s : s + ".0"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\" {
                let n = s.index(after: i)
                if n < s.endIndex {
                    switch s[n] {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    default: out.append(s[n])
                    }
                    i = s.index(after: n)
                    continue
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
