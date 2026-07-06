import XCTest
@testable import Pomvox

/// Capture-start failure classification: a Mac with no microphone at all must
/// not be told to "grant Microphone access" (that pane is empty and useless
/// with no device). No-device wins over a missing permission; both win over a
/// generic engine error.
final class AudioCaptureFailureTests: XCTestCase {

    func testNoInputDeviceWinsRegardlessOfPermission() {
        XCTAssertEqual(
            AudioCapture.StartFailure.classify(hasInputDevice: false, permissionGranted: false),
            .noInputDevice)
        XCTAssertEqual(
            AudioCapture.StartFailure.classify(hasInputDevice: false, permissionGranted: true),
            .noInputDevice)
    }

    func testDevicePresentButPermissionDenied() {
        XCTAssertEqual(
            AudioCapture.StartFailure.classify(hasInputDevice: true, permissionGranted: false),
            .permissionDenied)
    }

    func testDevicePresentAndGrantedIsAGenericEngineError() {
        XCTAssertEqual(
            AudioCapture.StartFailure.classify(hasInputDevice: true, permissionGranted: true),
            .engineError)
    }

    func testNoMicrophoneHasItsOwnMessageAndCode() {
        let f = AudioCapture.StartFailure.noInputDevice
        XCTAssertTrue(f.message.lowercased().contains("no microphone"))
        XCTAssertFalse(f.message.lowercased().contains("grant"))  // not a permission nag
        XCTAssertEqual(f.errorCode, "no_microphone")
    }

    func testPermissionDeniedKeepsTheGrantMessageAndCode() {
        let f = AudioCapture.StartFailure.permissionDenied
        XCTAssertTrue(f.message.contains("Microphone"))
        XCTAssertEqual(f.errorCode, "microphone_unavailable")
    }

    func testEveryErrorCodeMatchesTheTelemetryContract() {
        // The wire contract forbids anything but ^[a-z0-9_]{1,40}$.
        for f: AudioCapture.StartFailure in [.noInputDevice, .permissionDenied, .engineError] {
            XCTAssertEqual(TelemetrySanitizer.errorCode(f.errorCode), f.errorCode)
        }
    }
}
