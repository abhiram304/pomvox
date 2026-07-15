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
