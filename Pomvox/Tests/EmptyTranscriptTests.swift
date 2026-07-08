// Pomvox/Tests/EmptyTranscriptTests.swift
import XCTest
@testable import Pomvox

/// When STT returns "", the user must learn WHY nothing pasted: the transcriber
/// threw (bug), the mic delivered (near-)zeros (the post-sleep dead-stream
/// failure), or there genuinely were no words (normal — stay silent).
final class EmptyTranscriptTests: XCTestCase {

    func testSttErrorWinsOverEverything() {
        let c = classifyEmptyTranscript(rawWasEmpty: true, peakDbfs: -90.0, sttError: "ANE context invalid")
        XCTAssertEqual(c, .sttFailed("ANE context invalid"))
        XCTAssertEqual(c.errorCode, "stt_failed")
        XCTAssertNotNil(c.hudMessage)
    }

    func testNearZeroAudioIsSilentAudio() {
        let c = classifyEmptyTranscript(rawWasEmpty: true, peakDbfs: -80.0, sttError: nil)
        XCTAssertEqual(c, .silentAudio(-80.0))
        XCTAssertEqual(c.errorCode, "silent_audio")
        XCTAssertTrue(c.hudMessage!.lowercased().contains("mic"))
    }

    func testAudibleAudioWithNoWordsStaysQuiet() {
        // Breathing / keyboard noise transcribing to "" is normal — no flash.
        let c = classifyEmptyTranscript(rawWasEmpty: true, peakDbfs: -35.0, sttError: nil)
        XCTAssertEqual(c, .noSpeech(-35.0))
        XCTAssertNil(c.errorCode)
        XCTAssertNil(c.hudMessage)
    }

    // MARK: - dictionary wipe (#59)

    func testNonEmptyRawWipedByPostProcessingIsDictionaryWiped() {
        // STT heard words; cleanup can't return "" (sanitize rejects it), so a
        // wiped result is the replacement rules' doing — say so.
        let c = classifyEmptyTranscript(rawWasEmpty: false, peakDbfs: -30.0, sttError: nil)
        XCTAssertEqual(c, .dictionaryWiped)
        XCTAssertEqual(c.errorCode, "dictionary_wiped")
        XCTAssertTrue(c.hudMessage!.lowercased().contains("replacement"))
    }

    func testWipeWinsOverSilentAudioReading() {
        // A non-empty raw proves the pipeline worked end-to-end; peak level and
        // stt errors are irrelevant once real words existed.
        XCTAssertEqual(
            classifyEmptyTranscript(rawWasEmpty: false, peakDbfs: -90.0, sttError: nil),
            .dictionaryWiped)
    }

    func testEmptyRawKeepsTheExistingThreeWayClassification() {
        XCTAssertEqual(
            classifyEmptyTranscript(rawWasEmpty: true, peakDbfs: -80.0, sttError: nil),
            .silentAudio(-80.0))
        XCTAssertEqual(
            classifyEmptyTranscript(rawWasEmpty: true, peakDbfs: -35.0, sttError: nil),
            .noSpeech(-35.0))
    }

    func testPeakDbfsOfSilenceIsFloor() {
        XCTAssertLessThan(peakDbfs([Float](repeating: 0.0, count: 16000)), -100.0)
    }

    func testPeakDbfsOfFullScale() {
        XCTAssertEqual(peakDbfs([0.0, 1.0, -0.5]), 0.0, accuracy: 0.01)
    }

    func testPeakDbfsOfEmptyBufferIsFloor() {
        XCTAssertLessThan(peakDbfs([]), -100.0)
    }
}
