import XCTest
@testable import Pomvox

/// The in-app updater's pure state machine (design §Testing #1): every driver
/// event folds to the right `UpdaterState`, download progress accumulates, and
/// the banner/busy/version derivations hold — all without Sparkle or a network.
final class UpdaterStateTests: XCTestCase {

    private let notesURL = URL(string: "https://github.com/abhiram304/pomvox/releases/tag/v0.1.11")

    func testCheckStartedGoesToChecking() {
        XCTAssertEqual(UpdaterState.idle.applying(.checkStarted), .checking)
    }

    func testUpdateFoundCarriesVersionAndNotes() {
        let s = UpdaterState.checking.applying(.updateFound(version: "0.1.11", releaseNotesURL: notesURL))
        XCTAssertEqual(s, .updateAvailable(version: "0.1.11", releaseNotesURL: notesURL))
        XCTAssertEqual(s.availableVersion, "0.1.11")
        XCTAssertEqual(s.releaseNotesURL, notesURL)
    }

    func testNotFoundGoesToUpToDate() {
        XCTAssertEqual(UpdaterState.checking.applying(.notFound), .upToDate)
    }

    func testDownloadProgressAccumulates() {
        var s = UpdaterState.idle
            .applying(.downloadStarted)
        XCTAssertEqual(s, .downloading(receivedBytes: 0, expectedBytes: nil))
        XCTAssertNil(s.downloadFraction, "no expected length yet → indeterminate")

        s = s.applying(.downloadExpectedLength(1000))
        s = s.applying(.downloadReceived(250))
        s = s.applying(.downloadReceived(250))
        XCTAssertEqual(s, .downloading(receivedBytes: 500, expectedBytes: 1000))
        XCTAssertEqual(s.downloadFraction, 0.5)
    }

    func testDownloadFractionClampsAtOne() {
        let s = UpdaterState.downloading(receivedBytes: 1200, expectedBytes: 1000)
        XCTAssertEqual(s.downloadFraction, 1.0)
    }

    func testExtractionInstallReadyAndDismiss() {
        XCTAssertEqual(UpdaterState.downloading(receivedBytes: 1, expectedBytes: 1).applying(.extractionStarted),
                       .extracting(progress: 0))
        XCTAssertEqual(UpdaterState.extracting(progress: 0).applying(.extractionProgress(0.7)),
                       .extracting(progress: 0.7))
        XCTAssertEqual(UpdaterState.extracting(progress: 1).applying(.readyToRelaunch), .readyToRelaunch)
        XCTAssertEqual(UpdaterState.readyToRelaunch.applying(.installing), .installing)
        XCTAssertEqual(UpdaterState.updateAvailable(version: "x", releaseNotesURL: nil).applying(.dismissed),
                       .idle)
    }

    func testFailedGoesToError() {
        XCTAssertEqual(UpdaterState.checking.applying(.failed(message: "boom")),
                       .error(message: "boom"))
    }

    func testBannerVisibleFromAvailableThroughInstalling() {
        XCTAssertTrue(UpdaterState.updateAvailable(version: "x", releaseNotesURL: nil).bannerVisible)
        XCTAssertTrue(UpdaterState.downloading(receivedBytes: 0, expectedBytes: nil).bannerVisible)
        XCTAssertTrue(UpdaterState.extracting(progress: 0).bannerVisible)
        XCTAssertTrue(UpdaterState.readyToRelaunch.bannerVisible)
        XCTAssertTrue(UpdaterState.installing.bannerVisible)
        // Not a banner state:
        XCTAssertFalse(UpdaterState.idle.bannerVisible)
        XCTAssertFalse(UpdaterState.checking.bannerVisible)
        XCTAssertFalse(UpdaterState.upToDate.bannerVisible)
        XCTAssertFalse(UpdaterState.error(message: "x").bannerVisible)
    }

    func testIsBusyBlocksReChecks() {
        XCTAssertTrue(UpdaterState.checking.isBusy)
        XCTAssertTrue(UpdaterState.downloading(receivedBytes: 0, expectedBytes: nil).isBusy)
        XCTAssertFalse(UpdaterState.idle.isBusy)
        XCTAssertFalse(UpdaterState.updateAvailable(version: "x", releaseNotesURL: nil).isBusy)
        XCTAssertFalse(UpdaterState.upToDate.isBusy)
    }

    func testStatusLines() {
        XCTAssertEqual(UpdaterState.upToDate.statusLine, "You're up to date.")
        XCTAssertEqual(UpdaterState.updateAvailable(version: "0.1.11", releaseNotesURL: nil).statusLine,
                       "Update available — v0.1.11")
        XCTAssertEqual(UpdaterState.downloading(receivedBytes: 500, expectedBytes: 1000).statusLine,
                       "Downloading… 50%")
    }
}
