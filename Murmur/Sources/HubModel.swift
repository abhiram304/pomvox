import SwiftUI

/// Loads the read-only history once and republishes derived stats. A plain
/// `@MainActor ObservableObject` — the heavy lifting lives in `HistoryReader`,
/// which is unit-tested without any UI.
@MainActor
final class HubModel: ObservableObject {
    @Published private(set) var rows: [Dictation] = []
    @Published private(set) var stats: HubStats = .empty
    @Published private(set) var hasDatabase: Bool = false

    private let reader = HistoryReader()

    func reload() {
        hasDatabase = reader.databaseExists
        let loaded = reader.load()
        rows = loaded
        stats = reader.stats(rows: loaded)
    }

    func recent(_ n: Int) -> [Dictation] { Array(rows.prefix(n)) }

    func search(_ query: String) -> [Dictation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.final.lowercased().contains(q) || $0.raw.lowercased().contains(q) }
    }
}
