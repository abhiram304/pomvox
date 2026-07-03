import XCTest
import SQLite3
@testable import Pomvox

/// The Hub's write path: explicit deletes against the same schema the Python
/// engine owns. Each test writes a fixture DB, mutates it through HistoryWriter,
/// and re-reads through HistoryReader to confirm the on-disk effect.
final class HistoryWriterTests: XCTestCase {
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// A 3-row DB matching history.py's schema (with the WAL the engine uses).
    private func makeDB() throws -> String {
        let path = NSTemporaryDirectory() + "pomvox-writer-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        let schema = """
            CREATE TABLE history (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, raw_text TEXT,
              final_text TEXT, cleanup_status TEXT, app_hint TEXT, duration_s REAL, timings_json TEXT);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        for i in 1...3 {
            let sql = "INSERT INTO history (ts,raw_text,final_text,cleanup_status,timings_json)"
                + " VALUES (\(i), 'raw', 'final \(i)', 'ok', '')"
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
        return path
    }

    func testDeleteRemovesOneRow() throws {
        let path = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reader = HistoryReader(path: path)
        let writer = HistoryWriter(path: path)

        let target = reader.load().first { $0.final == "final 2" }!
        XCTAssertTrue(writer.delete(id: target.id))

        let remaining = reader.load().map(\.final)
        XCTAssertEqual(remaining.sorted(), ["final 1", "final 3"])
    }

    func testDeleteAllEmptiesTable() throws {
        let path = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = HistoryWriter(path: path)
        XCTAssertTrue(writer.deleteAll())
        XCTAssertTrue(HistoryReader(path: path).load().isEmpty)
    }

    func testWipeClearsRows() throws {
        let path = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = HistoryWriter(path: path)
        XCTAssertTrue(writer.wipe())
        XCTAssertTrue(HistoryReader(path: path).load().isEmpty)
    }

    func testMissingFileIsNoOpNotCrash() {
        let writer = HistoryWriter(path: NSTemporaryDirectory() + "nope-\(UUID().uuidString).db")
        XCTAssertFalse(writer.delete(id: 1))
        XCTAssertFalse(writer.deleteAll())
        XCTAssertFalse(writer.wipe())
    }

    /// The writer must not create the file (the engine owns creation).
    func testNeverCreatesDatabase() {
        let path = NSTemporaryDirectory() + "absent-\(UUID().uuidString).db"
        _ = HistoryWriter(path: path).deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
