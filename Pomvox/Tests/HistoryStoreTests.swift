import XCTest
import SQLite3
@testable import Pomvox

/// Port spec: tests/test_history.py — the native engine's history writer must
/// reproduce HistoryStore's SQL/retention/search math exactly. Same vectors,
/// same names; plus the cross-process contract pins (WAL + user_version=1 +
/// rows readable by HistoryReader) that Python asserts implicitly by being
/// the other side of the file.
final class HistoryStoreTests: XCTestCase {

    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "pomvox-store-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private var dbPath: String { dir + "/history.db" }

    private func store(retentionDays: Int = 7) throws -> HistoryStore {
        try XCTUnwrap(HistoryStore(path: dbPath, retentionDays: retentionDays))
    }

    private func add(_ s: HistoryStore, ts: Double,
                     raw: String = "raw words", final: String = "Final words.",
                     status: String = "ok") {
        s.add(ts: ts, rawText: raw, finalText: final, cleanupStatus: status,
              durationS: 2.5, timingsJson: "{}")
    }

    // MARK: - test_history.py vectors

    func testAddAndListNewestFirst() throws {
        let s = try store()
        add(s, ts: 1000.0, final: "first")
        add(s, ts: 2000.0, final: "second")
        let rows = s.list()
        XCTAssertEqual(rows.map(\.finalText), ["second", "first"])
        XCTAssertEqual(rows[0].rawText, "raw words")
        XCTAssertEqual(rows[0].cleanupStatus, "ok")
    }

    func testSearchMatchesRawAndFinal() throws {
        let s = try store()
        add(s, ts: 1.0, raw: "buy some flour", final: "Buy flour.")
        add(s, ts: 2.0, raw: "unrelated", final: "Unrelated.")
        XCTAssertEqual(s.list(query: "flour").map(\.ts), [1.0])
        XCTAssertFalse(s.list(query: "FLOUR").isEmpty)  // case-insensitive
        XCTAssertTrue(s.list(query: "nothing-matches").isEmpty)
    }

    func testPurgeRemovesRowsOlderThanRetention() throws {
        let s = try store(retentionDays: 7)
        let now = 1_000_000.0
        let week = 7.0 * 86400
        add(s, ts: now - week - 60)  // just past retention
        add(s, ts: now - 3600)       // recent
        s.purge(now: now)
        XCTAssertEqual(s.list().count, 1)
    }

    func testRetentionZeroKeepsNothing() throws {
        let s = try store(retentionDays: 0)
        add(s, ts: 999.0)
        s.purge(now: 1000.0)
        XCTAssertTrue(s.list().isEmpty)
    }

    func testDeleteOneAndDeleteAll() throws {
        let s = try store()
        add(s, ts: 1.0)
        add(s, ts: 2.0)
        let rows = s.list()
        s.delete(id: rows[0].id)
        XCTAssertEqual(s.list().count, 1)
        s.deleteAll()
        XCTAssertTrue(s.list().isEmpty)
    }

    func testListIsBounded() throws {
        let s = try store()
        for i in 0..<250 { add(s, ts: Double(i)) }
        XCTAssertEqual(s.list(limit: 200).count, 200)
    }

    func testDbFileIsUserOnly() throws {
        let s = try store()
        add(s, ts: 1.0)
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: dbPath)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    // MARK: - cross-process contract pins (the M1 freeze)

    func testStampsWalAndUserVersionOne() throws {
        _ = try store()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 1)
        sqlite3_finalize(stmt)
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)).lowercased(), "wal")
        sqlite3_finalize(stmt)
    }

    /// A row the native engine writes must read back through the Hub's reader
    /// with every column intact — the two sides of the same file agree.
    func testRowsReadBackThroughHistoryReader() throws {
        let s = try store()
        s.add(ts: 1234.5, rawText: "hello world", finalText: "Hello, world.",
              cleanupStatus: "ok", appHint: "Notes", durationS: 3.25,
              timingsJson: #"{"stt_finalize": 210.0, "total": 250.0}"#)
        let rows = HistoryReader(path: dbPath).load()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].raw, "hello world")
        XCTAssertEqual(rows[0].final, "Hello, world.")
        XCTAssertEqual(rows[0].cleanupStatus, "ok")
        XCTAssertEqual(rows[0].appHint, "Notes")
        XCTAssertEqual(rows[0].durationSeconds, 3.25)
        XCTAssertEqual(rows[0].timestamp.timeIntervalSince1970, 1234.5, accuracy: 0.001)
    }

    /// Mixed db — Python rows (NULL app_hint/duration_s, today's writer) and
    /// native rows (real values) must aggregate together in the Hub stats:
    /// words/count from every row, the WPM denominator only from timed rows.
    func testMixedPythonAndNativeRowsAggregateInHubStats() throws {
        let s = try store()
        // Python-shaped: _record_history passes neither app_hint nor duration_s.
        s.add(ts: 1000, rawText: "hello there world", finalText: "Hello there, world.",
              cleanupStatus: "ok", timingsJson: "{}")
        // Native-shaped: real duration and app hint.
        s.add(ts: 2000, rawText: "a b c d e", finalText: "a b c d e",
              cleanupStatus: "off", appHint: "Notes", durationS: 6.0,
              timingsJson: #"{"stt_finalize": 200.0, "insert": 30.0, "total": 230.0}"#)
        let reader = HistoryReader(path: dbPath)
        let stats = reader.stats(rows: reader.load())
        XCTAssertEqual(stats.dictationCount, 2)
        XCTAssertEqual(stats.totalWords, 8)        // 3 + 5, untimed rows still count
        XCTAssertEqual(stats.averageWPM, 50)       // 5 words / (6 s / 60) — timed row only
        XCTAssertEqual(stats.secondsSpoken, 6)
    }

    /// The launch-time retention purge must be conservative like
    /// HistoryWriter: purge an existing db, never create one just to purge.
    func testLaunchPurgeNeverCreatesTheDatabase() throws {
        XCTAssertEqual(HistoryStore.purgeExisting(path: dbPath, retentionDays: 7, now: 1000), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbPath))

        let s = try store()
        add(s, ts: 100.0)
        add(s, ts: 999.5)
        s.close()
        // retention 0 keeps nothing — the acceptance demo's setting.
        XCTAssertEqual(HistoryStore.purgeExisting(path: dbPath, retentionDays: 0, now: 1000), 2)
    }

    /// Opening an existing Python-written db must not re-create or alter it —
    /// add() into a foreign schema-compatible file just works.
    func testOpensExistingDatabaseWithoutTouchingSchema() throws {
        var s: HistoryStore? = try store()
        add(s!, ts: 1.0)
        s!.close()
        s = nil
        let again = try XCTUnwrap(HistoryStore(path: dbPath, retentionDays: 7))
        add(again, ts: 2.0)
        XCTAssertEqual(again.list().count, 2)
    }
}
