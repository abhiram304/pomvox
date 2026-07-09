import FluidAudio
import XCTest
@testable import Pomvox

/// Pure-logic mapping of the `[stt] model` config string to a FluidAudio
/// Parakeet version, with a never-fail fallback to the shipped default.
final class SttModelTests: XCTestCase {

    func testResolvesTheShippedDefaultRepoID() {
        XCTAssertEqual(SttModel.parse("mlx-community/parakeet-tdt-0.6b-v3"), .parakeetV3)
    }

    func testResolvesTheV2RepoID() {
        XCTAssertEqual(SttModel.parse("mlx-community/parakeet-tdt-0.6b-v2"), .parakeetV2)
    }

    func testResolvesABareVersionName() {
        XCTAssertEqual(SttModel.parse("parakeet-v3"), .parakeetV3)
        XCTAssertEqual(SttModel.parse("parakeet-v2"), .parakeetV2)
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(SttModel.parse("Parakeet-TDT-0.6b-V2"), .parakeetV2)
    }

    func testUnknownOrEmptyStringDoesNotParse() {
        XCTAssertNil(SttModel.parse(""))
        XCTAssertNil(SttModel.parse("whisper-large-v3"))          // wrong family
        XCTAssertNil(SttModel.parse("parakeet-tdt-0.6b"))         // no version suffix
        XCTAssertNil(SttModel.parse("mlx-community/Qwen3-4B-4bit"))
    }

    func testResolveNeverFailsAndFallsBackToDefault() {
        XCTAssertEqual(SttModel.resolve(""), .default)
        XCTAssertEqual(SttModel.resolve("something-unknown"), .default)
        XCTAssertEqual(SttModel.default, .parakeetV3)
    }

    func testFluidVersionBridge() {
        // AsrModelVersion isn't Equatable — pattern-match the case instead.
        if case .v2 = SttModel.parakeetV2.fluidVersion {} else { XCTFail("expected .v2") }
        if case .v3 = SttModel.parakeetV3.fluidVersion {} else { XCTFail("expected .v3") }
    }
}
