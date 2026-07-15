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
            let rawValue = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let value = try removeTrailingComment(rawValue, line: lineNo)
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

    /// Remove trailing comments (text after # outside of quoted strings) while
    /// preserving # inside quoted strings. Returns trimmed result.
    private static func removeTrailingComment(_ line: String, line lineNo: Int) throws -> String {
        var result = ""
        var inString = false
        var escaped = false
        for ch in line {
            if inString {
                result.append(ch)
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                result.append(ch)
                inString = true
            } else if ch == "#" {
                break  // Start of comment, stop processing
            } else {
                result.append(ch)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
             .replacingOccurrences(of: "\t", with: "\\t")
             .replacingOccurrences(of: "\r", with: "\\r") + "\""
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
                case "r": out.append("\r")
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
