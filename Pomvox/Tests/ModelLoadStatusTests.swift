import XCTest
@testable import Pomvox

/// The pure model-download status pieces: percentage formatting, the
/// download→loading phase switch, and the callback-coalescing gate.
final class ModelLoadStatusTests: XCTestCase {

    func testDownloadingShowsARoundedPercent() {
        XCTAssertEqual(
            ModelLoad.line(.speech, fraction: 0.0, downloading: true),
            "Downloading the speech model… 0%")
        XCTAssertEqual(
            ModelLoad.line(.speech, fraction: 0.454, downloading: true),
            "Downloading the speech model… 45%")
        XCTAssertEqual(
            ModelLoad.line(.polish, fraction: 1.0, downloading: true),
            "Downloading the polish model… 100%")
    }

    func testFractionIsClampedToTheValidRange() {
        XCTAssertEqual(
            ModelLoad.line(.speech, fraction: -0.2, downloading: true),
            "Downloading the speech model… 0%")
        XCTAssertEqual(
            ModelLoad.line(.speech, fraction: 1.7, downloading: true),
            "Downloading the speech model… 100%")
    }

    func testNotDownloadingIsIndeterminateLoadingCopy() {
        XCTAssertEqual(
            ModelLoad.line(.speech, fraction: 1.0, downloading: false),
            "Loading the speech model…")
        XCTAssertEqual(
            ModelLoad.line(.polish, fraction: nil, downloading: true),
            "Loading the polish model…")
    }

    func testGateAdmitsOnlyDistinctLines() {
        let gate = LineGate()
        XCTAssertTrue(gate.changed("Downloading the speech model… 0%"))
        XCTAssertFalse(gate.changed("Downloading the speech model… 0%"))  // same → suppressed
        XCTAssertTrue(gate.changed("Downloading the speech model… 1%"))
        XCTAssertTrue(gate.changed("Loading the speech model…"))          // phase change
        XCTAssertFalse(gate.changed("Loading the speech model…"))
    }

    func testGateCollapsesARealisticProgressStream() {
        // Every 0.5% tick over a download should still yield exactly one line
        // per integer percent (101 distinct: 0…100).
        let gate = LineGate()
        var admitted = 0
        for i in 0...200 {
            let f = Double(i) / 200.0
            if gate.changed(ModelLoad.line(.speech, fraction: f, downloading: true)) { admitted += 1 }
        }
        XCTAssertEqual(admitted, 101)
    }
}
