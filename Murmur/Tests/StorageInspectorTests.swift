import XCTest
@testable import Murmur

/// The pure parts of the Privacy pane's storage report: size formatting, home
/// collapsing, and the artifact list. Live byte counts are filesystem-dependent
/// and verified in the on-device walkthrough, not here.
final class StorageInspectorTests: XCTestCase {
    func testHumanSizeZeroReadsEmpty() {
        XCTAssertEqual(StorageInspector.humanSize(0), "empty")
        XCTAssertEqual(StorageInspector.humanSize(-5), "empty")
    }

    func testHumanSizeFormatsBytes() {
        // ByteCountFormatter(.file) is decimal-ish; just assert it's non-empty
        // and unit-bearing rather than pinning a locale-specific string.
        XCTAssertTrue(StorageInspector.humanSize(2_000_000).contains("MB"))
    }

    func testCollapseHome() {
        let home = NSHomeDirectory()
        XCTAssertEqual(StorageInspector.collapseHome(home + "/.murmur/history.db"),
                       "~/.murmur/history.db")
        XCTAssertEqual(StorageInspector.collapseHome("/tmp/elsewhere"), "/tmp/elsewhere")
    }

    func testArtifactsCoverHistoryConfigAndModels() {
        let items = StorageInspector.artifacts(dbPath: "/x/history.db", configPath: "/x/config.toml")
        let labels = items.map(\.label)
        XCTAssertTrue(labels.contains("Dictation history"))
        XCTAssertTrue(labels.contains("Settings"))
        XCTAssertTrue(labels.contains("Downloaded models"))

        // History size counts the WAL siblings so the number isn't misleadingly low.
        let history = items.first { $0.label == "Dictation history" }!
        XCTAssertEqual(history.paths, ["/x/history.db", "/x/history.db-wal", "/x/history.db-shm"])
        // Models are flagged a directory (recursive size) and not wiped.
        XCTAssertTrue(items.first { $0.label == "Downloaded models" }!.isDir)
    }
}
