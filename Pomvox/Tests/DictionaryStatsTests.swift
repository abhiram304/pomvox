import XCTest
@testable import Pomvox

final class DictionaryStatsTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = NSTemporaryDirectory() + "dict-stats-\(UUID().uuidString).json"
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testRecordIncrementsAndStampsLastFired() {
        let store = DictionaryStatsStore(path: path)
        store.record(["r1", "r2"], at: 100)
        store.record(["r1"], at: 200)
        XCTAssertEqual(store.stats(for: "r1"), DictionaryRuleStats(count: 2, lastFired: 200))
        XCTAssertEqual(store.stats(for: "r2"), DictionaryRuleStats(count: 1, lastFired: 100))
        XCTAssertNil(store.stats(for: "never"))
    }

    func testPersistsAcrossInstances() {
        DictionaryStatsStore(path: path).record(["r1"], at: 5)
        XCTAssertEqual(DictionaryStatsStore(path: path).stats(for: "r1")?.count, 1)
    }

    func testCorruptFileResetsHarmlessly() throws {
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        let store = DictionaryStatsStore(path: path)
        XCTAssertNil(store.stats(for: "r1"))
        store.record(["r1"], at: 1)   // and writes cleanly after
        XCTAssertEqual(DictionaryStatsStore(path: path).stats(for: "r1")?.count, 1)
    }

    func testRecordEmptyIsNoOp() {
        let store = DictionaryStatsStore(path: path)
        store.record([], at: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testThreadSafety() {
        let store = DictionaryStatsStore(path: path)
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            store.record(["r\(i % 5)"], at: Double(i))
        }
        let total = store.allStats().values.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, 50)
    }
}
