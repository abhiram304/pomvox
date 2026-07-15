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
