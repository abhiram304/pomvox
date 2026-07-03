import Foundation
import SQLite3

/// Read-only view over the Python app's `~/.pomvox/history.db`. A separate
/// process from the dictation engine: it opens the database read-only so it can
/// never block or corrupt the writer, and adds zero latency to the hot path.
///
/// Pure of SwiftUI; unit-tested against fixture databases (point `POMVOX_DB_PATH`
/// at one). Stat definitions are the spec the Python History window must agree
/// with — see PomvoxTests.
struct HistoryReader {
    let path: String

    /// Default location, overridable for tests via `POMVOX_DB_PATH`.
    static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["POMVOX_DB_PATH"], !override.isEmpty {
            return override
        }
        return NSString(string: "~/.pomvox/history.db").expandingTildeInPath
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
        s.streak = streak(rows: rows, now: now, calendar: calendar)
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

    /// The 90-day calendar heatmap, as a week×weekday grid. The last column is
    /// the week containing `now`; columns run oldest→newest left to right, rows
    /// run Sunday→Saturday (or the calendar's `firstWeekday`). Days past today
    /// are present but flagged `inFuture` so the view can leave them blank.
    /// Pure and deterministic given `now`/`calendar` — unit-tested.
    func heatmap(rows: [Dictation], now: Date, calendar: Calendar, weeks: Int = 13) -> [HeatmapCell] {
        let today = calendar.startOfDay(for: now)
        // Weekday offset of `today` within its week (0 = firstWeekday).
        let weekdayOfToday = (calendar.component(.weekday, from: today)
            - calendar.firstWeekday + 7) % 7
        // First cell = start of the leftmost shown week.
        guard let startOfThisWeek = calendar.date(byAdding: .day, value: -weekdayOfToday, to: today),
              let gridStart = calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: startOfThisWeek)
        else { return [] }

        var wordsByDay: [Date: Int] = [:]
        for r in rows {
            let day = calendar.startOfDay(for: r.timestamp)
            if day >= gridStart && day <= today {
                wordsByDay[day, default: 0] += r.wordCount
            }
        }

        var cells: [HeatmapCell] = []
        cells.reserveCapacity(weeks * 7)
        for week in 0..<weeks {
            for weekday in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: gridStart)
                else { continue }
                cells.append(HeatmapCell(
                    id: week * 7 + weekday,
                    date: day,
                    words: wordsByDay[day] ?? 0,
                    week: week,
                    weekday: weekday,
                    inFuture: day > today))
            }
        }
        return cells
    }

    /// Your current streak: consecutive days you dictated, ending today. If today
    /// is still empty we count from yesterday instead, so the streak doesn't
    /// vanish before you've spoken today. 0 if neither today nor yesterday saw
    /// any words. Local framing — no comparison, no leaderboard.
    func streak(rows: [Dictation], now: Date, calendar: Calendar) -> Int {
        var activeDays: Set<Date> = []
        for r in rows where r.wordCount > 0 {
            activeDays.insert(calendar.startOfDay(for: r.timestamp))
        }
        guard !activeDays.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }

        var cursor: Date
        if activeDays.contains(today) {
            cursor = today
        } else if activeDays.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }

        var count = 0
        while activeDays.contains(cursor) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return count
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
