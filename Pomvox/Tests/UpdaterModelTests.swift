import XCTest
@testable import Pomvox

final class UpdaterModelTests: XCTestCase {

    func testFeedOverrideReadsEnvVar() {
        XCTAssertEqual(UpdaterModel.feedOverride(env: ["POMVOX_UPDATE_FEED": "http://localhost:8000/a.xml"]),
                       "http://localhost:8000/a.xml")
        XCTAssertNil(UpdaterModel.feedOverride(env: [:]))
    }

    func testDriverEventsDrivePublishedState() {
        let m = UpdaterModel()
        m.apply(.checkStarted)
        XCTAssertEqual(m.state, .checking)
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { _ in }
        XCTAssertEqual(m.state, .updateAvailable(version: "0.1.12", releaseNotesURL: nil))
    }

    func testInstallRepliesInstallAndOnlyOnce() {
        let m = UpdaterModel()
        var replies: [UpdateChoice] = []
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { replies.append($0) }
        m.install()
        m.install()   // second click must not double-reply
        XCTAssertEqual(replies, [.install])
    }

    func testLaterDismissesBannerAndRepliesDismiss() {
        let m = UpdaterModel()
        var replies: [UpdateChoice] = []
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { replies.append($0) }
        m.later()
        XCTAssertEqual(replies, [.dismiss])
        XCTAssertEqual(m.state, .idle)
    }

    func testSkipRepliesSkip() {
        let m = UpdaterModel()
        var replies: [UpdateChoice] = []
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { replies.append($0) }
        m.skip()
        XCTAssertEqual(replies, [.skip])
        XCTAssertEqual(m.state, .idle)
    }

    func testRelaunchWaitsForInFlightDictation() {
        let m = UpdaterModel()
        m.relaunchPollInterval = 0.01
        var busyPolls = 0
        m.isDictationBusy = { busyPolls += 1; return busyPolls < 3 }  // busy twice, then idle
        let done = expectation(description: "reply sent after dictation ends")
        m.handleReadyToRelaunch { choice in
            XCTAssertEqual(choice, .install)
            done.fulfill()
        }
        XCTAssertEqual(m.state, .readyToRelaunch)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(m.state, .installing)
        XCTAssertGreaterThanOrEqual(busyPolls, 3)
    }

    func testRelaunchImmediateWhenIdle() {
        let m = UpdaterModel()
        var replied: UpdateChoice?
        m.isDictationBusy = { false }
        m.handleReadyToRelaunch { replied = $0 }
        XCTAssertEqual(replied, .install)
        XCTAssertEqual(m.state, .installing)
    }

    func testLastCheckedLabel() {
        XCTAssertEqual(UpdaterModel.lastCheckedLabel(nil), "Never checked")
        let label = UpdaterModel.lastCheckedLabel(Date(timeIntervalSinceNow: -3600))
        XCTAssertTrue(label.hasPrefix("Last checked"), label)
    }

    func testFriendlyMessageMapsTranslocationAndVerification() {
        let transloc = NSError(domain: "SUSparkleErrorDomain", code: 1, userInfo:
            [NSLocalizedDescriptionKey: "The update will not be installed because the application is translocated"])
        XCTAssertEqual(UpdaterModel.friendlyMessage(for: transloc),
                       "Move Pomvox to the Applications folder to enable updates.")
        let badSig = NSError(domain: "SUSparkleErrorDomain", code: 2, userInfo:
            [NSLocalizedDescriptionKey: "The update archive failed signature validation"])
        XCTAssertTrue(UpdaterModel.friendlyMessage(for: badSig).contains("couldn't be verified"))
        let offline = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo:
            [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        XCTAssertEqual(UpdaterModel.friendlyMessage(for: offline),
                       "The Internet connection appears to be offline.")
    }

    func testManualCheckFlagResetsAtCycleEndSoLaterScheduledFailureStaysSilent() {
        let m = UpdaterModel()
        let err = NSError(domain: "x", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "offline"])
        m.checkNow()                                        // manual check…
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { _ in }
        m.later()                                           // …ends with Later
        m.noteUpdateCycleFinished()                         // delegate: cycle over
        m.showUpdaterError(err) {}                          // later SCHEDULED failure
        XCTAssertEqual(m.state, .idle)                      // must stay silent
    }

    func testScheduledCheckErrorIsSilentButManualCheckErrorShows() {
        let m = UpdaterModel()
        let err = NSError(domain: "x", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "offline"])
        m.showUpdaterError(err) {}          // scheduled path: silent, back to idle
        XCTAssertEqual(m.state, .idle)
        m.checkNow()                        // marks the next cycle user-initiated
        m.showUpdaterError(err) {}
        XCTAssertEqual(m.state, .error(message: "offline"))
    }

    func testPomvoxVersionLabelHasVersionAndBuild() {
        // Test bundle → falls back to its own plist values; shape is what matters.
        let label = Bundle.main.pomvoxVersionLabel
        XCTAssertTrue(label.hasPrefix("Pomvox "), label)
        XCTAssertTrue(label.contains("("), label)
        XCTAssertFalse(label.contains("?"), label)  // real values, not the "?" fallback
    }
}
