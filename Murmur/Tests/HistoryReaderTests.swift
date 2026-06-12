import XCTest
import SQLite3
@testable import Murmur

/// Stats parity: the Swift Hub must compute the same numbers the Python
/// HistoryStore would over the same rows. The definitions live in
/// HistoryReader; these fixtures pin them.
///
/// Equivalent Python (reused from src/murmur/history.py rows):
///   total_words = sum(len(r.final_text.split()) for r in rows)
///   count       = len(rows)
///   timed       = [r for r in rows if r.duration_s and r.duration_s > 0]
///   avg_wpm     = round(sum(len(r.final_text.split()) for r in timed)
///                       / (sum(r.duration_s for r in timed) / 60))
final class HistoryReaderTests: XCTestCase {

    /// Fixed clock so the 30-day window and day buckets are deterministic.
    /// 2026-06-11 18:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_781_200_800)
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()

    private struct Row { let final: String; let raw: String; let dur: Double?; let agoSeconds: Double }

    private func fixture() -> [Row] {
        [
            Row(final: "let's meet on friday",        raw: "lets meet on friday",  dur: 6,  agoSeconds: 3600),       // today, 4w
            Row(final: "do the thing and ship it",    raw: "do the thing ship it", dur: 12, agoSeconds: 7200),       // today, 6w
            Row(final: "hello there",                 raw: "hello there",          dur: nil, agoSeconds: 86_400),     // -1d, 2w, untimed
            Row(final: "one two three four five",     raw: "one two three four",   dur: 5,  agoSeconds: 3 * 86_400),  // -3d, 5w
            Row(final: "",                            raw: "uh",                   dur: 2,  agoSeconds: 40 * 86_400), // -40d, 0w, outside window
        ]
    }

    private func makeDB(_ rows: [Row]) throws -> String {
        let path = NSTemporaryDirectory() + "murmur-test-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE history (id INTEGER PRIMARY KEY, ts REAL, raw_text TEXT, final_text TEXT,
              cleanup_status TEXT, app_hint TEXT, duration_s REAL, timings_json TEXT);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        // Bound parameters, not string interpolation — final_text contains
        // apostrophes ("let's") that would otherwise break the SQL.
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let insert = "INSERT INTO history (ts,raw_text,final_text,cleanup_status,app_hint,duration_s,timings_json)"
            + " VALUES (?,?,?,?,NULL,?,'');"
        for r in rows {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, insert, -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970 - r.agoSeconds)
            sqlite3_bind_text(stmt, 2, r.raw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, r.final, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, "ok", -1, SQLITE_TRANSIENT)
            if let d = r.dur { sqlite3_bind_double(stmt, 5, d) } else { sqlite3_bind_null(stmt, 5) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE, "insert failed")
            sqlite3_finalize(stmt)
        }
        return path
    }

    func testStatsMatchExpected() throws {
        let path = try makeDB(fixture())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = HistoryReader(path: path)
        let rows = reader.load()
        XCTAssertEqual(rows.count, 5)
        // newest first
        XCTAssertEqual(rows.first?.final, "let's meet on friday")

        let s = reader.stats(rows: rows, now: now, calendar: utc)
        XCTAssertEqual(s.totalWords, 17)        // 4+6+2+5+0
        XCTAssertEqual(s.dictationCount, 5)
        // wordsTimed = 4+6+5+0 = 15; seconds = 6+12+5+2 = 25 → 15 / (25/60) = 36
        XCTAssertEqual(s.averageWPM, 36)
        XCTAssertEqual(s.secondsSpoken, 25)
    }

    func testActivityBuckets() throws {
        let path = try makeDB(fixture())
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reader = HistoryReader(path: path)
        let s = reader.stats(rows: reader.load(), now: now, calendar: utc)

        XCTAssertEqual(s.activity.count, 30)
        let byOffset = Dictionary(uniqueKeysWithValues: s.activity.map { ($0.id, $0.words) })
        XCTAssertEqual(byOffset[29], 10)   // today: 4 + 6
        XCTAssertEqual(byOffset[28], 2)    // yesterday
        XCTAssertEqual(byOffset[26], 5)    // 3 days ago (offset 29-3)
        XCTAssertEqual(s.activity.map(\.words).reduce(0, +), 17)  // -40d row excluded
    }

    func testMissingDatabaseIsEmptyNotError() {
        let reader = HistoryReader(path: NSTemporaryDirectory() + "does-not-exist.db")
        XCTAssertFalse(reader.databaseExists)
        XCTAssertTrue(reader.load().isEmpty)
        let s = reader.stats(rows: [], now: now, calendar: utc)
        XCTAssertEqual(s.totalWords, 0)
        XCTAssertEqual(s.averageWPM, 0)
    }

    func testWordCount() {
        XCTAssertEqual(Dictation.countWords("one two three"), 3)
        XCTAssertEqual(Dictation.countWords("  spaced   out  "), 2)
        XCTAssertEqual(Dictation.countWords(""), 0)
    }
}
