import Foundation
import SQLite3

/// Read-only view over the Python app's `~/.murmur/history.db`. A separate
/// process from the dictation engine: it opens the database read-only so it can
/// never block or corrupt the writer, and adds zero latency to the hot path.
///
/// Pure of SwiftUI; unit-tested against fixture databases (point `MURMUR_DB_PATH`
/// at one). Stat definitions are the spec the Python History window must agree
/// with — see MurmurTests.
struct HistoryReader {
    let path: String

    /// Default location, overridable for tests via `MURMUR_DB_PATH`.
    static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["MURMUR_DB_PATH"], !override.isEmpty {
            return override
        }
        return NSString(string: "~/.murmur/history.db").expandingTildeInPath
    }

    init(path: String = HistoryReader.defaultPath()) {
        self.path = path
    }

    var databaseExists: Bool { FileManager.default.fileExists(atPath: path) }

    /// Load every row, newest first. Empty (not an error) when the database is
    /// missing or has no rows — the Hub renders a first-run empty state.
    func load() -> [Dictation] {
        guard databaseExists else { return [] }

        var db: OpaquePointer?
        // READ-ONLY: the engine owns writes; the Hub only ever reads.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        // Don't fight the writer for the WAL: read whatever is committed.
        sqlite3_busy_timeout(db, 200)

        let sql = """
            SELECT id, ts, raw_text, final_text, cleanup_status, app_hint, duration_s
            FROM history ORDER BY ts DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [Dictation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(
                Dictation(
                    id: sqlite3_column_int64(stmt, 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    raw: Self.text(stmt, 2),
                    final: Self.text(stmt, 3),
                    cleanupStatus: Self.text(stmt, 4),
                    appHint: Self.optionalText(stmt, 5),
                    durationSeconds: sqlite3_column_type(stmt, 6) == SQLITE_NULL
                        ? nil : sqlite3_column_double(stmt, 6)
                ))
        }
        return rows
    }

    // MARK: - Stats (the numbers the Home dashboard shows)

    /// `now` is injectable so the 30-day window is deterministic in tests.
    func stats(rows: [Dictation], now: Date = Date(), calendar: Calendar = .current) -> HubStats {
        var s = HubStats()
        s.dictationCount = rows.count
        s.totalWords = rows.reduce(0) { $0 + $1.wordCount }

        // Average WPM = total words ÷ total minutes, over rows with a real
        // duration. (Mean-of-ratios would let a 1-word 0.3s blip dominate.)
        var wordsTimed = 0
        var seconds = 0.0
        for r in rows {
            if let d = r.durationSeconds, d > 0 {
                wordsTimed += r.wordCount
                seconds += d
            }
        }
        s.secondsSpoken = Int(seconds.rounded())
        s.averageWPM = seconds > 0 ? Int((Double(wordsTimed) / (seconds / 60.0)).rounded()) : 0

        s.activity = activity(rows: rows, now: now, calendar: calendar, days: 30)
        return s
    }

    /// Words per day for the last `days` days, oldest→newest, gaps filled with 0.
    func activity(rows: [Dictation], now: Date, calendar: Calendar, days: Int) -> [DayBucket] {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }

        var wordsByDay: [Date: Int] = [:]
        for r in rows {
            let day = calendar.startOfDay(for: r.timestamp)
            if day >= start && day <= today {
                wordsByDay[day, default: 0] += r.wordCount
            }
        }
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return DayBucket(id: offset, date: day, words: wordsByDay[day] ?? 0)
        }
    }

    // MARK: - column helpers

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
    private static func optionalText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL, let c = sqlite3_column_text(stmt, col)
        else { return nil }
        return String(cString: c)
    }
}
