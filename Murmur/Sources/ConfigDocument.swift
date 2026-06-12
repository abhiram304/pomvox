import Foundation

/// A comment-preserving, surgical editor for `~/.murmur/config.toml`.
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

    init(text: String) {
        lines = text.components(separatedBy: "\n")
    }

    /// Load from disk; a missing/unreadable file is an empty document (the
    /// Hub can still build one from defaults), mirroring HistoryReader.
    static func load(path: String) -> ConfigDocument {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return ConfigDocument(text: text)
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
