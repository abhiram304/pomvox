import XCTest
@testable import Pomvox

/// Opt-in, anonymous usage telemetry (native app only). The brief's hard rule —
/// "never send transcripts, audio, file paths, emails, or any free text" — is
/// enforced *structurally* (a typed scalar props allowlist) and pinned here:
/// every prop is validated-or-dropped, the JSON body carries only allowlisted
/// keys, and the client no-ops unless consent is on AND an endpoint is set.
/// Pure logic is the bulk of this; the URLSession send is the thin shell, tested
/// through an injected sender (no real network).
final class TelemetryTests: XCTestCase {

    // MARK: - install_id (UserDefaults-backed, anonymous, stable per install)

    private func freshDefaults() -> UserDefaults {
        let name = "telemetry.tests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testInstallIDGeneratedOnceAndStable() {
        var store = TelemetryStore(defaults: freshDefaults())
        let first = store.installID()
        let second = store.installID()
        XCTAssertEqual(first, second, "install_id must be stable across calls")
        XCTAssertNotNil(UUID(uuidString: first), "install_id must be a UUID v4")
    }

    func testInstallIDPersistsAcrossStoreInstances() {
        let defaults = freshDefaults()
        var a = TelemetryStore(defaults: defaults)
        let id = a.installID()
        var b = TelemetryStore(defaults: defaults)
        XCTAssertEqual(b.installID(), id)
    }

    func testConsentDefaultsOffAndUnprompted() {
        let store = TelemetryStore(defaults: freshDefaults())
        XCTAssertFalse(store.enabled, "telemetry is off until the user chooses")
        XCTAssertFalse(store.prompted, "the one-time prompt has not been shown yet")
    }

    func testConsentPersists() {
        let defaults = freshDefaults()
        var a = TelemetryStore(defaults: defaults)
        a.enabled = true
        a.prompted = true
        let b = TelemetryStore(defaults: defaults)
        XCTAssertTrue(b.enabled)
        XCTAssertTrue(b.prompted)
    }

    // MARK: - prop sanitization (validate-or-drop; never reject the batch)

    func testSttModelReducedToBasenameAndValidated() {
        XCTAssertEqual(TelemetrySanitizer.sttModel("mlx-community/parakeet-tdt-0.6b-v3"),
                       "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(TelemetrySanitizer.sttModel("parakeet-tdt-0.6b-v3"),
                       "parakeet-tdt-0.6b-v3")
    }

    func testSttModelDroppedWhenItCannotMatchAllowlist() {
        // Spaces / unexpected chars in the basename → drop rather than send.
        XCTAssertNil(TelemetrySanitizer.sttModel("some model name"))
        XCTAssertNil(TelemetrySanitizer.sttModel(""))
        XCTAssertNil(TelemetrySanitizer.sttModel("a/"))
        XCTAssertNil(TelemetrySanitizer.sttModel(String(repeating: "x", count: 65)))
    }

    func testDurationClampedToContractRange() {
        XCTAssertEqual(TelemetrySanitizer.durationMs(1234), 1234)
        XCTAssertEqual(TelemetrySanitizer.durationMs(-5), 0)
        XCTAssertEqual(TelemetrySanitizer.durationMs(99_999_999), 86_400_000)
    }

    func testCleanupStatusAllowlist() {
        for s in ["ok", "timeout", "rejected", "error", "off"] {
            XCTAssertEqual(TelemetrySanitizer.cleanupStatus(s), s)
        }
        XCTAssertNil(TelemetrySanitizer.cleanupStatus("weird"))
    }

    func testErrorCodeEnumShapedOnly() {
        XCTAssertEqual(TelemetrySanitizer.errorCode("model_load_failed"), "model_load_failed")
        XCTAssertNil(TelemetrySanitizer.errorCode("Has Spaces"))
        XCTAssertNil(TelemetrySanitizer.errorCode("UPPER"))
        XCTAssertNil(TelemetrySanitizer.errorCode(String(repeating: "a", count: 41)))
    }

    func testCleanDropsInvalidPropsButKeepsValidOnes() {
        var props = TelemetryProps()
        props.durationMs = 1234
        props.sttModel = "mlx-community/parakeet-tdt-0.6b-v3"
        props.cleanupStatus = "bogus"
        props.errorCode = "Bad Code"
        let cleaned = TelemetrySanitizer.clean(props)
        XCTAssertEqual(cleaned.durationMs, 1234)
        XCTAssertEqual(cleaned.sttModel, "parakeet-tdt-0.6b-v3")
        XCTAssertNil(cleaned.cleanupStatus)
        XCTAssertNil(cleaned.errorCode)
    }

    // MARK: - JSON shape (exact contract; unknown fields reject the whole batch)

    private let env = TelemetryEnv(
        schemaVersion: 1, installID: "11111111-2222-4333-8444-555555555555",
        appVersion: "0.1.0", osVersion: "macOS 15.7.4", arch: "arm64")

    private func decode(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    func testBatchEnvelopeHasExactlyTheContractKeys() throws {
        let data = try TelemetryEncoder.encodeBatch(
            env: env, events: [TelemetryEvent(event: .appLaunch, ts: 1_730_000_000_000)])
        let obj = decode(data)
        XCTAssertEqual(Set(obj.keys),
                       ["schema_version", "install_id", "app_version", "os_version", "arch", "events"])
        XCTAssertEqual(obj["schema_version"] as? Int, 1)
        XCTAssertEqual(obj["install_id"] as? String, "11111111-2222-4333-8444-555555555555")
        XCTAssertEqual(obj["arch"] as? String, "arm64")
    }

    func testEventWithoutPropsOmitsThePropsKey() throws {
        let data = try TelemetryEncoder.encodeBatch(
            env: env, events: [TelemetryEvent(event: .appLaunch, ts: 1_730_000_000_000)])
        let events = decode(data)["events"] as! [[String: Any]]
        XCTAssertEqual(Set(events[0].keys), ["event", "ts"], "no empty props object")
        XCTAssertEqual(events[0]["event"] as? String, "app_launch")
        XCTAssertEqual(events[0]["ts"] as? Int, 1_730_000_000_000)
    }

    func testDictationEventEmitsOnlyAllowlistedProps() throws {
        var props = TelemetryProps()
        props.durationMs = 1234
        props.sttModel = "parakeet-tdt-0.6b-v3"
        props.cleanup = true
        props.cleanupStatus = "ok"
        let ev = TelemetryEvent(event: .dictationCompleted, ts: 1_730_000_001_000, props: props)
        let data = try TelemetryEncoder.encodeBatch(env: env, events: [ev])
        let events = decode(data)["events"] as! [[String: Any]]
        let p = events[0]["props"] as! [String: Any]
        XCTAssertEqual(Set(p.keys), ["duration_ms", "stt_model", "cleanup", "cleanup_status"])
        XCTAssertEqual(p["duration_ms"] as? Int, 1234)
        XCTAssertEqual(p["cleanup"] as? Bool, true)
        XCTAssertEqual(events[0]["event"] as? String, "dictation_completed")
    }

    func testEncoderSanitizesContentOutOfProps() throws {
        // A model id with a slash must arrive as its basename, never the full path.
        var props = TelemetryProps()
        props.sttModel = "mlx-community/parakeet-tdt-0.6b-v3"
        let ev = TelemetryEvent(event: .dictationCompleted, ts: 1, props: props)
        let data = try TelemetryEncoder.encodeBatch(env: env, events: [ev])
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("mlx-community"),
                       "no file-path-shaped content may reach the wire")
    }

    // MARK: - bounded queue + 50-event chunking

    private func ev(_ ts: Int) -> TelemetryEvent { TelemetryEvent(event: .appLaunch, ts: ts) }

    func testQueueDropsOldestBeyondCap() {
        var q = TelemetryQueue(cap: 3, maxBatch: 50)
        for i in 1...5 { q.enqueue(ev(i)) }
        let batch = q.nextBatch()
        XCTAssertEqual(batch.map(\.ts), [3, 4, 5], "oldest dropped at the cap")
    }

    func testNextBatchCapsAtFiftyAndDrains() {
        var q = TelemetryQueue(cap: 200, maxBatch: 50)
        for i in 1...60 { q.enqueue(ev(i)) }
        XCTAssertEqual(q.nextBatch().count, 50)
        XCTAssertEqual(q.nextBatch().count, 10)
        XCTAssertTrue(q.isEmpty)
    }

    // MARK: - gate

    func testGate() {
        let url = URL(string: "https://example.com")!
        XCTAssertTrue(TelemetryGate.shouldSend(enabled: true, endpoint: url))
        XCTAssertFalse(TelemetryGate.shouldSend(enabled: false, endpoint: url))
        XCTAssertFalse(TelemetryGate.shouldSend(enabled: true, endpoint: nil))
    }

    // MARK: - client (gating / send / retry / drop) with an injected sender

    /// Thread-safe spy standing in for the URLSession POST.
    private final class SenderSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _bodies: [Data] = []
        var result: TelemetrySendResult = .success
        var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return _bodies }
        var send: TelemetryClient.Sender {
            { [self] _, data in
                lock.lock(); _bodies.append(data); lock.unlock()
                return result
            }
        }
    }

    private func makeClient(enabled: Bool, endpoint: URL?, spy: SenderSpy) -> TelemetryClient {
        TelemetryClient(endpoint: endpoint, enabled: { enabled }, env: env,
                        now: { 1_730_000_000_000 }, sender: spy.send)
    }

    func testFlushNoOpsWhenDisabled() async {
        let spy = SenderSpy()
        let client = makeClient(enabled: false, endpoint: URL(string: "https://x")!, spy: spy)
        await client.record(TelemetryEvent(event: .appLaunch, ts: 1))
        await client.flush()
        XCTAssertTrue(spy.bodies.isEmpty, "off → nothing sent")
    }

    func testFlushNoOpsWithoutEndpoint() async {
        let spy = SenderSpy()
        let client = makeClient(enabled: true, endpoint: nil, spy: spy)
        await client.record(TelemetryEvent(event: .appLaunch, ts: 1))
        await client.flush()
        XCTAssertTrue(spy.bodies.isEmpty, "no endpoint → no-op")
    }

    func testFlushSendsValidBatchWhenEnabled() async throws {
        let spy = SenderSpy()
        let client = makeClient(enabled: true, endpoint: URL(string: "https://x")!, spy: spy)
        await client.record(TelemetryEvent(event: .appLaunch, ts: 1))
        await client.flush()
        XCTAssertEqual(spy.bodies.count, 1)
        let obj = decode(spy.bodies[0])
        XCTAssertEqual(obj["install_id"] as? String, env.installID)
        XCTAssertEqual((obj["events"] as? [[String: Any]])?.count, 1)
    }

    func testSuccessDrainsTheQueue() async {
        let spy = SenderSpy(); spy.result = .success
        let client = makeClient(enabled: true, endpoint: URL(string: "https://x")!, spy: spy)
        await client.record(TelemetryEvent(event: .appLaunch, ts: 1))
        await client.flush()
        await client.flush()  // second flush has nothing left to send
        XCTAssertEqual(spy.bodies.count, 1)
    }

    func testRetryableFailureKeepsEventsForNextFlush() async {
        let spy = SenderSpy(); spy.result = .retryableFailure
        let client = makeClient(enabled: true, endpoint: URL(string: "https://x")!, spy: spy)
        await client.record(TelemetryEvent(event: .appLaunch, ts: 1))
        await client.flush()
        spy.result = .success
        await client.flush()  // retried — server dedupes, so re-send is safe
        XCTAssertEqual(spy.bodies.count, 2, "retried after a 5xx/network failure")
    }

    func testPermanentFailureDropsTheBatch() async {
        let spy = SenderSpy(); spy.result = .permanentFailure
        let client = makeClient(enabled: true, endpoint: URL(string: "https://x")!, spy: spy)
        await client.record(TelemetryEvent(event: .appLaunch, ts: 1))
        await client.flush()
        spy.result = .success
        await client.flush()  // nothing requeued after a 400 — must not retry
        XCTAssertEqual(spy.bodies.count, 1)
    }

    func testFlushChunksIntoFiftiesAndStaysUnderSizeLimit() async {
        let spy = SenderSpy()
        let client = makeClient(enabled: true, endpoint: URL(string: "https://x")!, spy: spy)
        for i in 1...60 { await client.record(TelemetryEvent(event: .appLaunch, ts: i)) }
        await client.flush()
        XCTAssertEqual(spy.bodies.count, 2, "60 events → 50 + 10")
        for body in spy.bodies { XCTAssertLessThanOrEqual(body.count, 64_000) }
    }

    // MARK: - HTTP status mapping (the only logic in the real sender shell)

    func testStatusMapping() {
        XCTAssertEqual(TelemetryClient.classify(status: 204), .success)
        XCTAssertEqual(TelemetryClient.classify(status: 400), .permanentFailure)
        XCTAssertEqual(TelemetryClient.classify(status: 405), .permanentFailure)
        XCTAssertEqual(TelemetryClient.classify(status: 413), .permanentFailure)
        XCTAssertEqual(TelemetryClient.classify(status: 500), .retryableFailure)
        XCTAssertEqual(TelemetryClient.classify(status: 503), .retryableFailure)
    }

    // MARK: - environment metadata

    func testEnvBuilderShape() {
        let e = TelemetryEnvBuilder.current(installID: "abc")
        XCTAssertEqual(e.schemaVersion, 1)
        XCTAssertEqual(e.installID, "abc")
        XCTAssertTrue(e.osVersion.hasPrefix("macOS "), "got \(e.osVersion)")
        XCTAssertFalse(e.appVersion.isEmpty)
        XCTAssertFalse(e.arch.isEmpty)
    }
}
