import XCTest

@testable import Pomvox

/// The M0 `pomvox-bench-llm` benchmark, relocated inside the Xcode app target —
/// mlx-swift's default.metallib is an Xcode build-phase artifact, so this is
/// the supported home for cleanup inference (docs/native-swift-path.md,
/// "Toolchain & packaging"). Gate numbers to match or beat (Python production
/// path, same machine, light style, prefix KV cache): load 3.20 s, warmup
/// 6.98 s, per-utterance 1.20–1.28 / 2.16–2.22 / 4.41–4.73 s, ~21 tok/s decode.
///
/// Skipped unless POMVOX_LLM_BENCH=1 — it loads the real ~2.3 GB model:
///   TEST_RUNNER_POMVOX_LLM_BENCH=1 DEVELOPER_DIR=... xcodebuild test ... \
///     -only-testing:PomvoxTests/CleanupBenchTests
final class CleanupBenchTests: XCTestCase {

    /// The make-fixtures.sh utterances — the same texts the Python baseline's
    /// STT step feeds its cleanup pass (transcripts are near-perfect on the
    /// synthetic voice, so the prompt workload matches).
    static let fixtures: [(name: String, text: String)] = [
        (
            "short_3s",
            "let's meet on Tuesday, wait no, Friday at two pm to review the draft"
        ),
        (
            "medium_8s",
            "um so the three things are uh first do the thing wait no two things "
                + "first do the thing and second ship it. also remind me to email the team about "
                + "the quarterly numbers before the end of the week"
        ),
        (
            "long_15s",
            "okay so here's the plan for the pomvox project. first we benchmark "
                + "the new speech model on the neural engine and compare it against the current "
                + "pipeline. then if the numbers hold up we port the hotkey state machine and the "
                + "endpoint detector, keeping the python tests as the specification. finally we wire "
                + "up the cleanup model and measure the end to end latency against the budget in "
                + "the spec document"
        ),
    ]

    func testBenchAgainstPythonGate() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_LLM_BENCH"] == "1",
            "set TEST_RUNNER_POMVOX_LLM_BENCH=1 to run the cleanup LLM bench")

        let engine = CleanupEngine()
        let t0 = CFAbsoluteTimeGetCurrent()
        await engine.prepare(modelID: "mlx-community/Qwen3-4B-4bit")
        let loaded = await engine.isLoaded
        print(String(format: "bench prepare (load+warmup): %.2fs", CFAbsoluteTimeGetCurrent() - t0))
        try XCTSkipUnless(loaded, "model failed to load — see the cleanup: NSLogs")

        for (name, text) in Self.fixtures {
            var times: [String] = []
            var statuses: [CleanupStatus] = []
            var output = ""
            for _ in 0..<3 {
                let t = CFAbsoluteTimeGetCurrent()
                let (out, status) = await runCleanup(engine, text: text, style: "light", timeoutS: 30.0)
                times.append(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t))
                statuses.append(status)
                output = out
            }
            print("bench clean \(name): \(times)s \(statuses.map(\.rawValue))")
            print("bench output \(name): \(output)")
            XCTAssertTrue(statuses.allSatisfy { $0 == .ok }, "\(name): \(statuses)")
        }
        await engine.unload()
    }

    /// SPEC §5 Phase-3 acceptance, natively: the self-correction utterance must
    /// clean to the SAME output as the Python engine (measured on this machine,
    /// both styles, 2026-06-12 — see the M6 PR), and a forced timeout must
    /// return the raw text untouched (the kill-mid-request criterion: the
    /// deadline abandons generation, runCleanup falls back to raw).
    func testPhase3AcceptanceParityAndTimeoutFallback() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_LLM_BENCH"] == "1",
            "set TEST_RUNNER_POMVOX_LLM_BENCH=1 to run the cleanup LLM acceptance")

        let utterance = "um so the three things are uh first do the thing wait no two things"
            + " first do the thing and second ship it"
        let pythonOutput = "The two things: first, do the thing; second, ship it."

        let engine = CleanupEngine()
        await engine.prepare(modelID: "mlx-community/Qwen3-4B-4bit")
        let loaded = await engine.isLoaded
        try XCTSkipUnless(loaded, "model failed to load — see the cleanup: NSLogs")

        for style in CleanupLogic.styles {
            let (out, status) = await runCleanup(engine, text: utterance, style: style, timeoutS: 10.0)
            XCTAssertEqual(status, .ok, "style \(style)")
            XCTAssertEqual(out, pythonOutput, "style \(style)")
        }

        let (out, status) = await runCleanup(engine, text: utterance, style: "polish", timeoutS: 0.05)
        XCTAssertEqual(status, .timeout)
        XCTAssertEqual(out, utterance, "a timeout must paste the raw transcript, never lose it")
        await engine.unload()
    }
}
