import XCTest
@testable import Pomvox

/// Verifies the CoreML compile-cache probe (item 1): the pure path-matching,
/// fingerprint digest, hit/changed decision, and the UserDefaults round-trip.
/// The disk scan itself is the thin shell and isn't exercised here.
final class CompiledModelCacheTests: XCTestCase {

    func testCandidateRootsIncludeTheHuggingFaceHub() {
        let roots = CompiledModelCache.candidateRoots(home: "/Users/x")
        XCTAssertTrue(roots.contains("/Users/x/.cache/huggingface/hub"))
        XCTAssertFalse(roots.isEmpty)
    }

    func testMatchTokenTracksTheModelVersion() {
        XCTAssertEqual(CompiledModelCache.matchToken(for: .parakeetV2), "v2")
        XCTAssertEqual(CompiledModelCache.matchToken(for: .parakeetV3), "v3")
    }

    func testPathMatchesRequiresFamilyVersionAndBundleSuffix() {
        let v3 = "/Users/x/.cache/huggingface/hub/models--parakeet-tdt-0.6b-v3/Encoder.mlmodelc"
        XCTAssertTrue(CompiledModelCache.pathMatches(v3, model: .parakeetV3))
        XCTAssertFalse(CompiledModelCache.pathMatches(v3, model: .parakeetV2), "wrong version")
        // Not a compiled bundle:
        XCTAssertFalse(CompiledModelCache.pathMatches(
            "/x/parakeet-v3/model.mlpackage", model: .parakeetV3))
        // Wrong family:
        XCTAssertFalse(CompiledModelCache.pathMatches("/x/whisper-v3/a.mlmodelc", model: .parakeetV3))
    }

    func testFingerprintDigestIsStableAndFieldSensitive() {
        let a = CompiledModelCache.Fingerprint(path: "/p", modifiedAt: 100, bytes: 42)
        let b = CompiledModelCache.Fingerprint(path: "/p", modifiedAt: 100, bytes: 42)
        let c = CompiledModelCache.Fingerprint(path: "/p", modifiedAt: 200, bytes: 42)
        XCTAssertEqual(a.digest, b.digest, "same fields → same digest")
        XCTAssertNotEqual(a.digest, c.digest, "a changed mtime must change the digest")
    }

    func testProbeHitAndChangedLogic() {
        let fp1 = CompiledModelCache.Fingerprint(path: "/p", modifiedAt: 100, bytes: 42)
        let fp2 = CompiledModelCache.Fingerprint(path: "/p", modifiedAt: 200, bytes: 42)

        // Nothing on disk, nothing recorded → miss.
        let miss = CompiledModelCache.Probe(current: nil, previous: nil)
        XCTAssertFalse(miss.hit)
        XCTAssertFalse(miss.changed)

        // Compiled now, first ever seen → not a hit yet, not "changed".
        let firstSeen = CompiledModelCache.Probe(current: fp1, previous: nil)
        XCTAssertFalse(firstSeen.hit)
        XCTAssertFalse(firstSeen.changed)

        // Present both launches, identical → hit, unchanged (cache persisted).
        let persisted = CompiledModelCache.Probe(current: fp1, previous: fp1)
        XCTAssertTrue(persisted.hit)
        XCTAssertFalse(persisted.changed)

        // Present both launches but different → hit, changed (recompiled).
        let recompiled = CompiledModelCache.Probe(current: fp2, previous: fp1)
        XCTAssertTrue(recompiled.hit)
        XCTAssertTrue(recompiled.changed)
    }

    func testStoredFingerprintRoundTrips() {
        let name = "coreml.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        XCTAssertNil(CompiledModelCache.storedFingerprint(for: .parakeetV3, defaults: defaults))

        let fp = CompiledModelCache.Fingerprint(path: "/p/Encoder.mlmodelc", modifiedAt: 123.5, bytes: 987)
        CompiledModelCache.record(fp, for: .parakeetV3, defaults: defaults)
        XCTAssertEqual(CompiledModelCache.storedFingerprint(for: .parakeetV3, defaults: defaults), fp)
        // Scoped per model: v2 slot is untouched.
        XCTAssertNil(CompiledModelCache.storedFingerprint(for: .parakeetV2, defaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }
}
