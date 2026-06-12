import Foundation
import SQLite3

/// The Hub's *only* writes to `~/.murmur/history.db`: explicit, user-initiated
/// deletes. Everything else stays read-only (`HistoryReader`). The dictation
/// engine (Python, separate process) owns the schema and all inserts; this opens
/// the same WAL database READ-WRITE only when the user asks to remove rows.
///
/// Deliberately conservative so it can never block or corrupt the concurrent
/// writer: it opens an existing file (never CREATE), leaves `journal_mode` and
/// `user_version` alone (the engine's WAL + v1 contract), runs a single DML
/// statement under a generous busy-timeout, and reports success rather than
/// throwing. Unit-tested against fixture databases (`MURMUR_DB_PATH`).
struct HistoryWriter {
    let path: String

    init(path: String = HistoryReader.defaultPath()) {
        self.path = path
    }

    /// Delete one row by id. Returns false (no-op) if the file is missing or the
    /// write can't be made — history bookkeeping must never crash the Hub.
    @discardableResult
    func delete(id: Int64) -> Bool {
        withWritableDB { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM history WHERE id = ?", -1, &stmt, nil) == SQLITE_OK
            else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    /// Delete every row (History "Delete all"). Leaves the file in place.
    @discardableResult
    func deleteAll() -> Bool {
        withWritableDB { db in sqlite3_exec(db, "DELETE FROM history", nil, nil, nil) == SQLITE_OK }
    }

    /// Privacy wipe: clear all rows, then VACUUM to actually return the freed
    /// pages to the OS so the on-disk size the Privacy pane shows really drops.
    /// VACUUM is best-effort — if the engine holds a lock we keep the delete and
    /// skip the shrink rather than failing the wipe.
    @discardableResult
    func wipe() -> Bool {
        withWritableDB { db in
            let cleared = sqlite3_exec(db, "DELETE FROM history", nil, nil, nil) == SQLITE_OK
            _ = sqlite3_exec(db, "VACUUM", nil, nil, nil)  // best-effort shrink
            return cleared
        }
    }

    // MARK: - connection

    /// Open the existing DB read-write, run `body`, always close. Returns false
    /// when the file is absent or won't open (nothing to delete is success-shaped
    /// for callers, but we report it honestly).
    private func withWritableDB(_ body: (OpaquePointer) -> Bool) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }
        // Wait for the WAL writer rather than failing immediately on a lock.
        sqlite3_busy_timeout(db, 2000)
        return body(db)
    }
}
