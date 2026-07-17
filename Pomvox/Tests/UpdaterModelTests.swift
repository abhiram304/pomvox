import XCTest
@testable import Pomvox

final class UpdaterModelTests: XCTestCase {

    func testFeedOverrideReadsEnvVar() {
        XCTAssertEqual(UpdaterModel.feedOverride(env: ["POMVOX_UPDATE_FEED": "http://localhost:8000/a.xml"]),
                       "http://localhost:8000/a.xml")
        XCTAssertNil(UpdaterModel.feedOverride(env: [:]))
    }

    func testFeedOverrideAcceptsAllLoopbackHosts() {
        XCTAssertEqual(UpdaterModel.feedOverride(env: ["POMVOX_UPDATE_FEED": "http://127.0.0.1:8000/a.xml"]),
                       "http://127.0.0.1:8000/a.xml")
        XCTAssertEqual(UpdaterModel.feedOverride(env: ["POMVOX_UPDATE_FEED": "http://[::1]:8000/a.xml"]),
                       "http://[::1]:8000/a.xml")
    }

    // Finding 4: a signed-downgrade vector — POMVOX_UPDATE_FEED must never
    // redirect a Release build to an attacker-controlled feed.
    func testFeedOverrideRejectsNonLoopbackHosts() {
        XCTAssertNil(UpdaterModel.feedOverride(env: ["POMVOX_UPDATE_FEED": "https://evil.example/appcast.xml"]))
    }

    func testFeedOverrideRejectsUnparsableGarbage() {
        XCTAssertNil(UpdaterModel.feedOverride(env: ["POMVOX_UPDATE_FEED": "not-a-url"]))
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
        m.noteUpdateCycleFinished(succeeded: true)          // delegate: cycle over
        m.showUpdaterError(err) {}                          // later SCHEDULED failure
        XCTAssertEqual(m.state, .idle)                      // must stay silent
    }

    func testScheduledCheckErrorIsSilentButManualCheckErrorShows() {
        let m = UpdaterModel()
        let err = NSError(domain: "x", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "offline"])
        m.showUpdaterError(err) {}          // scheduled path: silent, back to idle
        XCTAssertEqual(m.state, .idle)
        // Finding 8: checkNow() itself must not arm the manual-check flag —
        // only a real Sparkle user-initiated cycle (showUserInitiatedUpdateCheck)
        // does, since checkNow() can be a no-op call ignored by Sparkle.
        m.showUserInitiatedUpdateCheck(cancellation: {})
        m.showUpdaterError(err) {}
        XCTAssertEqual(m.state, .error(message: "offline"))
    }

    // Finding 10: lastCheckDate must only be stamped when a cycle actually
    // succeeds — a failed cycle stamping "just checked" is misleading.
    func testFailedUpdateCycleLeavesLastCheckDateNil() {
        let m = UpdaterModel()
        XCTAssertNil(m.lastCheckDate)
        m.noteUpdateCycleFinished(succeeded: false)
        XCTAssertNil(m.lastCheckDate)
    }

    func testSucceededUpdateCycleStampsLastCheckDate() {
        let m = UpdaterModel()
        m.noteUpdateCycleFinished(succeeded: true)
        XCTAssertNotNil(m.lastCheckDate)
    }

    func testUpToDateSurvivesSessionDismissal() {
        let m = UpdaterModel()
        m.apply(.checkStarted)
        m.apply(.noUpdateFound)
        m.dismissUpdateInstallation()
        XCTAssertEqual(m.state, .upToDate)
    }

    func testCheckingStillClearsOnSessionDismissal() {
        let m = UpdaterModel()
        m.apply(.checkStarted)
        m.dismissUpdateInstallation()
        XCTAssertEqual(m.state, .idle)
    }

    // Finding 1+7: Sparkle calls ONLY dismissUpdateInstallation() (no error
    // callback) when the user cancels the macOS admin-auth prompt mid-install.
    // Every in-flight banner state must unwind to idle, not stick forever.
    func testDismissUpdateInstallationReturnsToIdleForEveryInFlightState() {
        let notesURL: URL? = nil
        let setups: [(String, (UpdaterModel) -> Void)] = [
            ("downloading", { m in
                m.apply(.checkStarted)
                m.apply(.updateFound(version: "1", releaseNotesURL: notesURL))
                m.apply(.downloadStarted)
            }),
            ("extracting", { m in
                m.apply(.checkStarted)
                m.apply(.updateFound(version: "1", releaseNotesURL: notesURL))
                m.apply(.downloadStarted)
                m.apply(.extractionStarted)
            }),
            ("readyToRelaunch", { m in
                m.apply(.checkStarted)
                m.apply(.updateFound(version: "1", releaseNotesURL: notesURL))
                m.apply(.downloadStarted)
                m.apply(.extractionStarted)
                m.apply(.readyToInstall)
            }),
            ("installing", { m in
                m.apply(.checkStarted)
                m.apply(.updateFound(version: "1", releaseNotesURL: notesURL))
                m.apply(.downloadStarted)
                m.apply(.extractionStarted)
                m.apply(.readyToInstall)
                m.apply(.installStarted)
            }),
        ]
        for (name, setup) in setups {
            let m = UpdaterModel()
            setup(m)
            m.dismissUpdateInstallation()
            XCTAssertEqual(m.state, .idle, name)
        }
    }

    /// .updateAvailable is the one banner Finding 1 keeps: the aborted session
    /// leaves an actionable banner up rather than silently losing the update.
    func testDismissUpdateInstallationKeepsUpdateAvailableBanner() {
        let m = UpdaterModel()
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { _ in }
        m.dismissUpdateInstallation()
        XCTAssertEqual(m.state, .updateAvailable(version: "0.1.12", releaseNotesURL: nil))
    }

    /// The kept banner's Update button must never no-op against a dead Sparkle
    /// session: install() with no live reply kicks off a fresh check, and the
    /// next update-found auto-replies .install without a second click.
    func testInstallResumesDeadSessionByAutoInstallingOnNextUpdateFound() {
        let m = UpdaterModel()
        var replies: [UpdateChoice] = []
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { replies.append($0) }
        m.dismissUpdateInstallation()   // session dies mid-banner: reply nil'd, banner kept
        XCTAssertEqual(m.state, .updateAvailable(version: "0.1.12", releaseNotesURL: nil))

        m.install()   // updater is nil in tests -> checkForUpdates() is a no-op
        XCTAssertTrue(replies.isEmpty, "no live session to reply to yet")

        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { replies.append($0) }
        XCTAssertEqual(replies, [.install], "resume must auto-install, not wait for a 2nd click")
    }

    /// later()/skip() on a fresh banner must not leave a stale resume request
    /// armed for a future, unrelated update-found.
    func testLaterClearsResumeFlagSoNextUpdateFoundWaitsForAClick() {
        let m = UpdaterModel()
        var replies: [UpdateChoice] = []
        m.handleUpdateFound(version: "0.1.12", notesURL: nil) { replies.append($0) }
        m.dismissUpdateInstallation()
        m.install()                 // arms the resume flag
        m.later()                   // user backs out before the resume completes
        replies.removeAll()
        m.handleUpdateFound(version: "0.1.13", notesURL: nil) { replies.append($0) }
        XCTAssertTrue(replies.isEmpty, "later() must have cleared the armed resume")
    }

    /// The relaunch-gate Timer must be invalidated on dismiss — otherwise it
    /// keeps polling after the session is dead and forces .installing behind
    /// the user's back once dictation frees up.
    func testDismissDuringReadyToRelaunchInvalidatesPendingTimer() {
        let m = UpdaterModel()
        m.relaunchPollInterval = 0.05
        m.isDictationBusy = { true }
        var replied: UpdateChoice?
        let neverFires = expectation(description: "relaunch reply must never fire after dismiss")
        neverFires.isInverted = true
        m.handleReadyToRelaunch { choice in
            replied = choice
            neverFires.fulfill()
        }
        XCTAssertEqual(m.state, .readyToRelaunch)
        m.dismissUpdateInstallation()
        XCTAssertEqual(m.state, .idle)
        wait(for: [neverFires], timeout: 0.5)
        XCTAssertNil(replied)
        XCTAssertNotEqual(m.state, .installing)
    }

    func testPomvoxVersionLabelHasVersionAndBuild() {
        // Test bundle → falls back to its own plist values; shape is what matters.
        let label = Bundle.main.pomvoxVersionLabel
        XCTAssertTrue(label.hasPrefix("Pomvox "), label)
        XCTAssertTrue(label.contains("("), label)
        XCTAssertFalse(label.contains("?"), label)  // real values, not the "?" fallback
    }
}
