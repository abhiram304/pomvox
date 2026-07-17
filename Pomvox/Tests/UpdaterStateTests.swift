import XCTest
@testable import Pomvox

final class UpdaterStateTests: XCTestCase {
    private let notes = URL(string: "https://github.com/abhiram304/pomvox/releases/tag/v0.1.12")!

    func testHappyPathReachesRelaunch() {
        var s = UpdaterState.idle
        let events: [UpdaterEvent] = [
            .checkStarted,
            .updateFound(version: "0.1.12", releaseNotesURL: notes),
            .downloadStarted,
            .downloadProgressed(fraction: 0.5),
            .extractionStarted,
            .extractionProgressed(fraction: 0.8),
            .readyToInstall,
            .installStarted,
        ]
        for e in events { s = UpdaterState.reduce(s, e) }
        XCTAssertEqual(s, .installing)
    }

    func testCheckWithNoUpdateIsUpToDate() {
        var s = UpdaterState.reduce(.idle, .checkStarted)
        XCTAssertEqual(s, .checking)
        s = UpdaterState.reduce(s, .noUpdateFound)
        XCTAssertEqual(s, .upToDate)
    }

    func testDismissedReturnsToIdleFromAnyBannerState() {
        let banner: [UpdaterState] = [
            .updateAvailable(version: "0.1.12", releaseNotesURL: nil),
            .downloading(fraction: 0.2), .extracting(fraction: nil),
            .readyToRelaunch, .installing,
        ]
        for s in banner {
            XCTAssertEqual(UpdaterState.reduce(s, .dismissed), .idle, "\(s)")
        }
    }

    func testFailureCarriesMessage() {
        let s = UpdaterState.reduce(.downloading(fraction: 0.9),
                                    .failed(message: "Update couldn't be verified"))
        XCTAssertEqual(s, .error(message: "Update couldn't be verified"))
    }

    func testDownloadProgressWithUnknownLength() {
        let s = UpdaterState.reduce(.downloading(fraction: nil),
                                    .downloadProgressed(fraction: nil))
        XCTAssertEqual(s, .downloading(fraction: nil))
    }

    func testShowsBannerExactlyForInFlightUpdateStates() {
        XCTAssertTrue(UpdaterState.updateAvailable(version: "1", releaseNotesURL: nil).showsBanner)
        XCTAssertTrue(UpdaterState.downloading(fraction: nil).showsBanner)
        XCTAssertTrue(UpdaterState.extracting(fraction: 0.1).showsBanner)
        XCTAssertTrue(UpdaterState.readyToRelaunch.showsBanner)
        XCTAssertTrue(UpdaterState.installing.showsBanner)
        XCTAssertFalse(UpdaterState.idle.showsBanner)
        XCTAssertFalse(UpdaterState.checking.showsBanner)
        XCTAssertFalse(UpdaterState.upToDate.showsBanner)
        XCTAssertFalse(UpdaterState.error(message: "x").showsBanner)
    }
}
