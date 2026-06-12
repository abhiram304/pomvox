import XCTest
@testable import Murmur

/// Mirror of `tests/test_pidfile.py` — the cross-engine mutual-exclusion contract.
final class PidfileTests: XCTestCase {
    let DEAD: Int32 = 999_999  // a pid that won't exist
    var me: Int32 { ProcessInfo.processInfo.processIdentifier }

    private func tempPidfile() -> Pidfile {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-pidfile-\(UUID().uuidString)")
        return Pidfile(url: dir.appendingPathComponent("engine.pid"))
    }

    func testAcquireOnEmptyWritesAndReturnsNil() {
        let pf = tempPidfile()
        XCTAssertNil(pf.acquire("native", pid: me))
        XCTAssertEqual(pf.read(), Pidfile.Owner(pid: me, name: "native"))
    }

    func testAcquireBlockedByLiveOtherHolder() {
        let pf = tempPidfile()
        XCTAssertNil(pf.acquire("python", pid: me))             // our live pid holds it
        let blocker = pf.acquire("native", pid: DEAD)           // a different pid is refused
        XCTAssertEqual(blocker, Pidfile.Owner(pid: me, name: "python"))
        XCTAssertEqual(pf.read(), Pidfile.Owner(pid: me, name: "python"))  // untouched
    }

    func testAcquireOverwritesStaleDeadPid() {
        let pf = tempPidfile()
        _ = pf.acquire("python", pid: DEAD)                     // crashed without releasing
        XCTAssertNil(pf.currentHolder())                        // dead → no live holder
        XCTAssertNil(pf.acquire("native", pid: me))             // claimed cleanly
        XCTAssertEqual(pf.read(), Pidfile.Owner(pid: me, name: "native"))
    }

    func testReleaseOnlyRemovesWhenWeOwnIt() {
        let pf = tempPidfile()
        _ = pf.acquire("python", pid: me)
        pf.release(pid: me)
        XCTAssertNil(pf.read())

        _ = pf.acquire("native", pid: DEAD)
        pf.release(pid: me)                                     // not ours → left alone
        XCTAssertEqual(pf.read(), Pidfile.Owner(pid: DEAD, name: "native"))
    }

    func testReadMissingAndMalformed() {
        let pf = tempPidfile()
        XCTAssertNil(pf.read())
        try? "not-a-pid\nnative\n".write(to: pf.url, atomically: true, encoding: .utf8)
        XCTAssertNil(pf.read())
        XCTAssertNil(pf.currentHolder())
    }
}
