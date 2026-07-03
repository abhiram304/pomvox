import Foundation
import SQLite3

/// Native port of `src/natter/history.py` `HistoryStore` — with M7a the Swift
/// engine writes the dictation rows itself. Same schema verbatim, same WAL +
/// `user_version=1` contract (M1 freeze: never change without touching both
/// sides in one PR), same 0600-on-create, same retention math. The pidfile
/// guarantees a single *inserting* engine; the Hub keeps reading through its
/// separate read-only connection (`HistoryReader`).
///
/// Writes come from the engine's post-paste background task — strictly off the
/// latency path — and every failure is log-and-continue: history must never
/// cost a word. One connection, serialized by a lock (mirror of Python's).
final class HistoryStore: @unchecked Sendable {
    struct Row: Equatable {
        let id: Int64
        let ts: Double
        let rawText: String
        let finalText: String
        let cleanupStatus: String
        let appHint: String?
        let durationS: Double?
    }

    /// Byte-for-byte the Python `_SCHEMA` (history.py).
    private static let schema = """
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            raw_text TEXT NOT NULL,
            final_text TEXT NOT NULL,
            cleanup_status TEXT NOT NULL,
            app_hint TEXT,             -- NULL until Phase 4 context.py lands
            duration_s REAL,
            timings_json TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_history_ts ON history(ts);
        """

    let path: String
    let retentionDays: Int

    private let db: OpaquePointer
    private let lock = NSLock()
    private var closed = false

    /// nil when the database can't be opened or initialized — callers
    /// log-and-continue (the engine runs without history rather than failing).
    init?(path: String, retentionDays: Int = 7) {
        self.path = path
        self.retentionDays = retentionDays
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: path)

        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        db = handle
        // Wait for a concurrent writer (Python engine, Hub deletes) over failing.
        sqlite3_busy_timeout(db, 2000)
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "PRAGMA user_version=1", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, Self.schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        if !existed {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    deinit { close() }

    func add(ts: Double, rawText: String, finalText: String, cleanupStatus: String,
             appHint: String? = nil, durationS: Double? = nil, timingsJson: String = "") {
        withLock {
            var stmt: OpaquePointer?
            let sql = """
                INSERT INTO history \
                (ts, raw_text, final_text, cleanup_status, app_hint, duration_s, timings_json) \
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logSQLError("add prepare"); return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, ts)
            bindText(stmt, 2, rawText)
            bindText(stmt, 3, finalText)
            bindText(stmt, 4, cleanupStatus)
            if let appHint { bindText(stmt, 5, appHint) } else { sqlite3_bind_null(stmt, 5) }
            if let durationS { sqlite3_bind_double(stmt, 6, durationS) } else { sqlite3_bind_null(stmt, 6) }
            bindText(stmt, 7, timingsJson)
            if sqlite3_step(stmt) != SQLITE_DONE { logSQLError("add step") }
        }
    }

    func list(query: String = "", limit: Int = 200) -> [Row] {
        withLock {
            var sql = """
                SELECT id, ts, raw_text, final_text, cleanup_status, app_hint, duration_s \
                FROM history
                """
            if !query.isEmpty {
                sql += " WHERE raw_text LIKE ? COLLATE NOCASE OR final_text LIKE ? COLLATE NOCASE"
            }
            sql += " ORDER BY ts DESC LIMIT ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                logSQLError("list prepare"); return []
            }
            defer { sqlite3_finalize(stmt) }
            var index: Int32 = 1
            if !query.isEmpty {
                let like = "%\(query)%"
                bindText(stmt, index, like); index += 1
                bindText(stmt, index, like); index += 1
            }
            sqlite3_bind_int(stmt, index, Int32(limit))
            var rows: [Row] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(Row(
                    id: sqlite3_column_int64(stmt, 0),
                    ts: sqlite3_column_double(stmt, 1),
                    rawText: columnText(stmt, 2),
                    finalText: columnText(stmt, 3),
                    cleanupStatus: columnText(stmt, 4),
                    appHint: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : columnText(stmt, 5),
                    durationS: sqlite3_column_type(stmt, 6) == SQLITE_NULL
                        ? nil : sqlite3_column_double(stmt, 6)))
            }
            return rows
        }
    }

    /// Delete rows older than the retention window; returns the count.
    @discardableResult
    func purge(now: Double) -> Int {
        withLock {
            let cutoff = now - Double(retentionDays) * 86400
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM history WHERE ts < ?", -1, &stmt, nil)
                    == SQLITE_OK else {
                logSQLError("purge prepare"); return 0
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, cutoff)
            guard sqlite3_step(stmt) == SQLITE_DONE else { logSQLError("purge step"); return 0 }
            let count = Int(sqlite3_changes(db))
            if count > 0 {
                NSLog("history: purged %d rows past %dd retention", count, retentionDays)
            }
            return count
        }
    }

    func delete(id: Int64) {
        withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM history WHERE id = ?", -1, &stmt, nil)
                    == SQLITE_OK else {
                logSQLError("delete prepare"); return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            if sqlite3_step(stmt) != SQLITE_DONE { logSQLError("delete step") }
        }
    }

    func deleteAll() {
        withLock {
            if sqlite3_exec(db, "DELETE FROM history", nil, nil, nil) != SQLITE_OK {
                logSQLError("deleteAll")
            }
        }
        NSLog("history: cleared")
    }

    func close() {
        withLock {
            guard !closed else { return }
            closed = true
            sqlite3_close(db)
        }
    }

    /// Launch-time retention purge for the native-only user whose engine may
    /// never arm (Python purges on insert; someone must purge when nothing
    /// inserts). Conservative like HistoryWriter: opens an existing file,
    /// never creates one just to purge. Returns the purged-row count.
    @discardableResult
    static func purgeExisting(path: String, retentionDays: Int, now: Double) -> Int {
        guard FileManager.default.fileExists(atPath: path),
              let store = HistoryStore(path: path, retentionDays: retentionDays) else { return 0 }
        defer { store.close() }
        return store.purge(now: now)
    }

    // MARK: - helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private func logSQLError(_ what: String) {
        NSLog("history: %@ failed: %@", what, String(cString: sqlite3_errmsg(db)))
    }
}

extension Notification.Name {
    /// Posted by the native engine after it inserts a dictation row, so the
    /// Hub (same process now) refreshes without polling.
    static let natterHistoryDidChange = Notification.Name("app.natter.historyDidChange")
}
