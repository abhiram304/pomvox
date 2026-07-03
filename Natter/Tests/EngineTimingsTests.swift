import XCTest
@testable import Natter

/// Port spec: src/natter/bench.py Timings — per-stage durations, each relative
/// to the previous stamp, plus "total", all ms from t0 = recording stop. The
/// native engine writes these into history.timings_json with Python's exact
/// keys (stt_finalize, cleanup, insert, total) for dashboard parity.
final class EngineTimingsTests: XCTestCase {

    func testStagesAreChainedDeltasPlusTotal() {
        var clock = 1.0
        var t = EngineTimings(clock: { clock })
        t.start()
        clock = 1.21; t.stamp("stt_finalize")
        clock = 1.71; t.stamp("cleanup")
        clock = 1.76; t.stamp("insert")
        let stages = t.stagesMs()
        XCTAssertEqual(stages.map(\.name), ["stt_finalize", "cleanup", "insert", "total"])
        XCTAssertEqual(stages[0].ms, 210, accuracy: 0.001)
        XCTAssertEqual(stages[1].ms, 500, accuracy: 0.001)
        XCTAssertEqual(stages[2].ms, 50, accuracy: 0.001)
        XCTAssertEqual(stages[3].ms, 760, accuracy: 0.001)
    }

    func testNoStampsMeansNoStages() {
        var t = EngineTimings(clock: { 1.0 })
        XCTAssertTrue(t.stagesMs().isEmpty)  // never started
        t.start()
        XCTAssertTrue(t.stagesMs().isEmpty)  // started but nothing stamped
    }

    func testJsonCarriesPythonKeys() throws {
        var clock = 2.0
        var t = EngineTimings(clock: { clock })
        t.start()
        clock = 2.3; t.stamp("stt_finalize")
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(t.json().utf8)) as? [String: Double])
        XCTAssertEqual(parsed["stt_finalize"]!, 300, accuracy: 0.001)
        XCTAssertEqual(parsed["total"]!, 300, accuracy: 0.001)
    }
}
