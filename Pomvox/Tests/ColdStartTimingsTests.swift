import XCTest
@testable import Pomvox

/// The cold-start breakdown (item 3): independent stage spans, mapped to a log
/// line and to anonymous numeric telemetry props. Only measured stages appear —
/// an unmeasured stage must never imply it ran.
final class ColdStartTimingsTests: XCTestCase {

    func testSummaryOnlyIncludesMeasuredStages() {
        var t = ColdStartTimings()
        t.coremlCompileMs = 37_000
        t.coremlCacheHit = false
        let s = t.summary()
        XCTAssertTrue(s.contains("coreml_compile=37000ms"))
        XCTAssertTrue(s.contains("coreml_cache=miss"))
        XCTAssertFalse(s.contains("stt_weight_load"), "unmeasured stage must be absent")
        XCTAssertFalse(s.contains("cleanup_load"))
    }

    func testEmptySummaryIsExplicit() {
        XCTAssertEqual(ColdStartTimings().summary(), "cold-start: nothing measured")
    }

    func testTelemetryPropsRoundAndCarryOnlyMeasuredStages() {
        var t = ColdStartTimings()
        t.sttWeightLoadMs = 1200.6
        t.aneWarmupMs = 299.4
        t.coremlCacheHit = true
        let p = t.telemetryProps()
        XCTAssertEqual(p.sttWeightLoadMs, 1201)
        XCTAssertEqual(p.aneWarmupMs, 299)
        XCTAssertNil(p.coremlCompileMs)
        XCTAssertNil(p.cleanupLoadMs)
        XCTAssertEqual(p.coremlCacheHit, true)
    }

    func testHasMeasurement() {
        XCTAssertFalse(ColdStartTimings().hasMeasurement)
        var only = ColdStartTimings(); only.coremlCacheHit = true
        XCTAssertTrue(only.hasMeasurement, "even a lone cache-hit flag is a measurement")
        var load = ColdStartTimings(); load.cleanupLoadMs = 1500
        XCTAssertTrue(load.hasMeasurement)
    }
}
