import XCTest
@testable import Murmur

/// 1:1 port of `tests/test_vad.py` — webrtcvad itself is never involved (M5 is
/// energy-only); the FrameSlicer / frame_dbfs / EndpointDetector / Endpointer
/// vectors carry over verbatim from the Linux-tested Python spec.
final class VadLogicTests: XCTestCase {

    let FRAME_MS = 30   // 480 samples at 16 kHz
    let LOUD = -20.0
    let QUIET = -70.0

    private func det(silenceMs: Int = 600, minSpeechMs: Int = 90,
                     frameMs: Int = 30, energyGateDbfs: Double = -45.0) -> EndpointDetector {
        EndpointDetector(silenceMs: silenceMs, minSpeechMs: minSpeechMs,
                         frameMs: frameMs, energyGateDbfs: energyGateDbfs)
    }

    // MARK: - FrameSlicer

    func testSlicesBlocksIntoFramesWithRemainderCarry() {
        let s = FrameSlicer(frameSamples: 480)
        // 1600-sample block → 3 frames of 480, 160 carried
        let frames = s.add([Float](repeating: 0, count: 1600))
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.count == 480 })
        // next block: 160 carried + 1600 = 1760 → 3 frames, 320 carried
        XCTAssertEqual(s.add([Float](repeating: 0, count: 1600)).count, 3)
    }

    func testFrameSizeIsAConstructorArgument() {
        let s = FrameSlicer(frameSamples: 512)   // the Silero seam
        let frames = s.add([Float](repeating: 0, count: 1600))
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames.allSatisfy { $0.count == 512 })
    }

    func testInt16ConversionClips() {
        let s = FrameSlicer(frameSamples: 4)
        let frames = s.add([2.0, -2.0, 1.0, -1.0])
        XCTAssertEqual(frames[0][0], 32767)
        XCTAssertEqual(frames[0][1], -32767)
    }

    func testResetDropsCarriedSamples() {
        let s = FrameSlicer(frameSamples: 480)
        _ = s.add([Float](repeating: 0, count: 1600))
        s.reset()
        XCTAssertEqual(s.add([Float](repeating: 0, count: 480)).count, 1)
    }

    // MARK: - frame_dbfs

    func testFrameDbfsSilenceVsLoud() {
        let quiet = [Int16](repeating: 0, count: 480)
        let loud = [Int16](repeating: 16000, count: 480)
        XCTAssertLessThan(frameDbfs(quiet), -80)
        XCTAssertGreaterThan(frameDbfs(loud), -10)
    }

    // MARK: - EndpointDetector

    func testSpeechStartNeedsMinConsecutiveVoiced() {
        let d = det()   // 90 ms = 3 frames
        XCTAssertNil(d.feed(voiced: true, energyDbfs: LOUD))
        XCTAssertNil(d.feed(voiced: true, energyDbfs: LOUD))
        XCTAssertEqual(d.feed(voiced: true, energyDbfs: LOUD), .speechStart)
    }

    func testBlipsDoNotStartSpeech() {
        let d = det()
        _ = d.feed(voiced: true, energyDbfs: LOUD)
        _ = d.feed(voiced: false, energyDbfs: QUIET)   // resets the run
        _ = d.feed(voiced: true, energyDbfs: LOUD)
        XCTAssertNil(d.feed(voiced: true, energyDbfs: LOUD))   // only 2 consecutive
    }

    func testEnergyGateVetoesVadVote() {
        // votes voiced but the room is silent: breath/keyboard noise
        let d = det()
        for _ in 0..<10 {
            XCTAssertNil(d.feed(voiced: true, energyDbfs: QUIET))
        }
    }

    func testEndpointAfterSilenceHangover() {
        let d = det()   // 600 ms silence = 20 frames
        for _ in 0..<3 { _ = d.feed(voiced: true, energyDbfs: LOUD) }
        for _ in 0..<19 { XCTAssertNil(d.feed(voiced: false, energyDbfs: QUIET)) }
        XCTAssertEqual(d.feed(voiced: false, energyDbfs: QUIET), .endpoint)
    }

    func testSpeechResumptionSnapsSilenceBack() {
        let d = det()
        for _ in 0..<3 { _ = d.feed(voiced: true, energyDbfs: LOUD) }
        for _ in 0..<15 { _ = d.feed(voiced: false, energyDbfs: QUIET) }
        XCTAssertGreaterThan(d.silenceFraction, 0.5)
        _ = d.feed(voiced: true, energyDbfs: LOUD)   // spoke again
        XCTAssertEqual(d.silenceFraction, 0.0)
    }

    func testFiresOnceThenInertUntilReset() {
        let d = det()
        for _ in 0..<3 { _ = d.feed(voiced: true, energyDbfs: LOUD) }
        for _ in 0..<20 { _ = d.feed(voiced: false, energyDbfs: QUIET) }
        for _ in 0..<30 { XCTAssertNil(d.feed(voiced: false, energyDbfs: QUIET)) }
        d.reset()
        for _ in 0..<2 { _ = d.feed(voiced: true, energyDbfs: LOUD) }
        XCTAssertEqual(d.feed(voiced: true, energyDbfs: LOUD), .speechStart)
    }

    func testNoEndpointBeforeSpeechEverStarted() {
        // hands-free armed but the user never spoke: don't auto-stop
        let d = det()
        for _ in 0..<100 { XCTAssertNil(d.feed(voiced: false, energyDbfs: QUIET)) }
    }

    // MARK: - Endpointer

    final class FakeBackend: VadBackend {
        let frameSamples = 480
        var voiced: Bool
        init(voiced: Bool = true) { self.voiced = voiced }
        func isVoiced(_ frame: [Int16]) -> Bool { voiced }
    }

    private func makeEndpointer(_ backend: VadBackend? = nil, maxSessionS: Double = 600.0) -> Endpointer {
        Endpointer(backend: backend ?? FakeBackend(), detector: det(), maxSessionS: maxSessionS)
    }

    private func loudBlock(_ n: Int = 1600) -> [Float] { [Float](repeating: 0.1, count: n) }
    private func quietBlock(_ n: Int = 1600) -> [Float] { [Float](repeating: 0.0, count: n) }

    func testDisarmedProcessesNothing() {
        let ep = makeEndpointer()
        let (event, frac) = ep.process(loudBlock())
        XCTAssertNil(event)
        XCTAssertNil(frac)
    }

    func testSpeechThenSilenceFiresEndpointOnce() {
        let backend = FakeBackend(voiced: true)
        let ep = makeEndpointer(backend)
        ep.arm(generation: 1)
        _ = ep.process(loudBlock())   // 3 voiced frames → speech start
        backend.voiced = false
        var events: [VadEvent] = []
        for _ in 0..<10 {   // 30 frames of silence ≫ 600 ms hangover
            let (event, _) = ep.process(quietBlock())
            if let event { events.append(event) }
        }
        XCTAssertEqual(events, [.endpoint])
        XCTAssertEqual(ep.generation, 1)
    }

    func testSilenceFractionReportedWhileArmed() {
        let backend = FakeBackend(voiced: true)
        let ep = makeEndpointer(backend)
        ep.arm(generation: 1)
        _ = ep.process(loudBlock())
        backend.voiced = false
        let (_, frac) = ep.process(quietBlock())
        XCTAssertNotNil(frac)
        XCTAssertTrue(0.0 < frac! && frac! < 1.0)
    }

    func testArmResetsStateBetweenSessions() {
        let backend = FakeBackend(voiced: true)
        let ep = makeEndpointer(backend)
        ep.arm(generation: 1)
        _ = ep.process(loudBlock())
        ep.disarm()
        ep.arm(generation: 2)   // stale hangover/carry must not leak in
        backend.voiced = false
        let (event, _) = ep.process(quietBlock())
        XCTAssertNil(event)   // no speech yet in session 2 → no endpoint
        XCTAssertEqual(ep.generation, 2)
    }

    func testSessionCapWarningThenEndpoint() {
        // 1 s cap at 16 kHz = 16000 samples; warning at 90%
        let ep = makeEndpointer(FakeBackend(voiced: true), maxSessionS: 1.0)
        ep.arm(generation: 1)
        var events: [VadEvent] = []
        for _ in 0..<11 {   // 11 × 1600 = 17600 samples > cap
            let (event, _) = ep.process(loudBlock())
            if let event { events.append(event) }
        }
        XCTAssertTrue(events.contains(.capWarning))
        XCTAssertEqual(events.last, .endpoint)
    }
}
