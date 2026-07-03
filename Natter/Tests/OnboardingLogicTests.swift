import XCTest
@testable import Natter

/// Port spec: tests/test_onboarding.py — OnboardingFlow pure logic, the Setup
/// pane is a dumb renderer. Same vectors, same names.
final class OnboardingLogicTests: XCTestCase {

    private let allGranted: [String: Bool?] = [
        "microphone": true, "input_monitoring": true, "accessibility": true,
    ]
    private let flow = OnboardingFlow()

    func testRowsCoverTheThreePermissionsInOrder() {
        let rows = flow.rows(statuses: allGranted, tapInstalled: true)
        XCTAssertEqual(rows.map(\.key), ["microphone", "input_monitoring", "accessibility"])
        XCTAssertTrue(rows.allSatisfy { $0.granted == true })
        XCTAssertTrue(rows.allSatisfy { !$0.why.isEmpty })  // every row explains itself
    }

    func testUnknownProbeStatusPassesThroughAsNil() {
        var statuses = allGranted
        statuses["accessibility"] = Bool?.none
        let rows = flow.rows(statuses: statuses, tapInstalled: true)
        XCTAssertNil(rows[2].granted)
    }

    func testRelaunchNoteWhenGrantedButTapStillDead() {
        // Input Monitoring grants don't reach an already-running process.
        let rows = flow.rows(statuses: allGranted, tapInstalled: false)
        let im = rows[1]
        XCTAssertEqual(im.granted, true)
        XCTAssertTrue(im.note.lowercased().contains("relaunch"))
    }

    func testNoRelaunchNoteWhileSimplyUngranted() {
        var statuses = allGranted
        statuses["input_monitoring"] = false
        let rows = flow.rows(statuses: statuses, tapInstalled: false)
        XCTAssertEqual(rows[1].note, "")
    }

    func testCompleteRequiresAllGrantsAndALiveTap() {
        XCTAssertTrue(flow.complete(statuses: allGranted, tapInstalled: true))
        XCTAssertFalse(flow.complete(statuses: allGranted, tapInstalled: false))
        var micDenied = allGranted
        micDenied["microphone"] = false
        XCTAssertFalse(flow.complete(statuses: micDenied, tapInstalled: true))
        var micUnknown = allGranted
        micUnknown["microphone"] = Bool?.none
        XCTAssertFalse(flow.complete(statuses: micUnknown, tapInstalled: true))
    }
}
