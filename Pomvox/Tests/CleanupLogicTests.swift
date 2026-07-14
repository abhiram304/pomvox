import XCTest

@testable import Pomvox

/// 1:1 port of `tests/test_cleanup.py` — test-vector parity with the
/// Linux-tested Python spec (build_messages, accept_output, run_cleanup,
/// common_prefix_len), not re-derived.
final class CleanupLogicTests: XCTestCase {

    let raw = "um so I think we should uh ship it tomorrow maybe"

    // MARK: - buildMessages

    func testBuildMessagesEmbedsTextAndRules() {
        let msgs = CleanupLogic.buildMessages(text: "hello world", style: "light")
        XCTAssertEqual(msgs[0].role, "system")
        let rules = msgs[0].content.lowercased()
        XCTAssertTrue(rules.contains("filler"))
        XCTAssertTrue(rules.contains("punctuation"))
        XCTAssertTrue(rules.contains("never change the meaning"))
        XCTAssertEqual(msgs.last, ChatMessage(role: "user", content: "hello world"))
    }

    func testBuildMessagesInjectsTermsHint() {
        let hint = "- Keep these terms spelled exactly: Salammagari.\n"
        let system = CleanupLogic.buildMessages(text: "x", style: "polish", termsHint: hint)[0].content
        XCTAssertTrue(system.contains("Salammagari"))
        // The hint sits among the rules, before the final "Output only" line.
        XCTAssertLessThan(system.range(of: "Salammagari")!.lowerBound,
                          system.range(of: "Output only")!.lowerBound)
    }

    func testBuildMessagesTermsHintDefaultsEmpty() {
        let system = CleanupLogic.buildMessages(text: "x", style: "light")[0].content
        XCTAssertFalse(system.contains("{terms}"))  // placeholder fully resolved
    }

    func testBuildMessagesStylesDiffer() {
        let light = CleanupLogic.buildMessages(text: "x", style: "light")[0].content.lowercased()
        let polish = CleanupLogic.buildMessages(text: "x", style: "polish")[0].content.lowercased()
        XCTAssertNotEqual(light, polish)
        XCTAssertTrue(polish.contains("smooth"))
        XCTAssertFalse(light.contains("smooth"))
    }

    func testBuildMessagesHasFewShotPairs() {
        let msgs = CleanupLogic.buildMessages(text: "x", style: "polish")
        let roles = msgs.map(\.role)
        XCTAssertEqual(roles.first, "system")
        XCTAssertEqual(roles.last, "user")
        let assistants = roles.filter { $0 == "assistant" }.count
        XCTAssertGreaterThanOrEqual(assistants, 2)
        // user/assistant examples alternate between system and the final user turn
        let middle = Array(roles[1..<(roles.count - 1)])
        XCTAssertEqual(middle, Array(repeating: ["user", "assistant"], count: assistants).flatMap { $0 })
    }

    // MARK: - acceptOutput

    func testAcceptNormalOutput() {
        let cleaned = "I think we should ship it tomorrow."
        XCTAssertEqual(CleanupLogic.acceptOutput(raw: raw, cleaned: cleaned), cleaned)
    }

    func testAcceptStripsWrappingQuotes() {
        XCTAssertEqual(
            CleanupLogic.acceptOutput(raw: raw, cleaned: "\"I think we should ship it tomorrow.\""),
            "I think we should ship it tomorrow.")
    }

    func testRejectEmpty() {
        XCTAssertNil(CleanupLogic.acceptOutput(raw: raw, cleaned: ""))
        XCTAssertNil(CleanupLogic.acceptOutput(raw: raw, cleaned: "   \n"))
    }

    func testRejectThinkArtifacts() {
        XCTAssertNil(
            CleanupLogic.acceptOutput(raw: raw, cleaned: "<think>hmm</think>Ship it tomorrow, I think."))
    }

    func testRejectRolePrefix() {
        XCTAssertNil(
            CleanupLogic.acceptOutput(raw: raw, cleaned: "assistant: I think we should ship it tomorrow."))
    }

    func testRejectFarTooLong() {
        XCTAssertNil(
            CleanupLogic.acceptOutput(raw: "short text here ok", cleaned: String(repeating: "x", count: 200)))
    }

    func testRejectFarTooShort() {
        XCTAssertNil(CleanupLogic.acceptOutput(raw: raw, cleaned: "ok"))
    }

    func testShortRawSkipsLowerBound() {
        XCTAssertEqual(CleanupLogic.acceptOutput(raw: "ok", cleaned: "OK."), "OK.")
    }

    // MARK: - runCleanup

    final class FakeEngine: CleanupCleaning {
        struct Boom: Error {}
        let result: String?
        let throws_: Bool
        var calls: [(text: String, style: String, timeoutS: Double)] = []

        init(result: String? = nil, throws throws_: Bool = false) {
            self.result = result
            self.throws_ = throws_
        }

        func clean(_ text: String, style: String, timeoutS: Double) async throws -> String? {
            calls.append((text, style, timeoutS))
            if throws_ { throw Boom() }
            return result
        }
    }

    func testRunCleanupOk() async {
        let engine = FakeEngine(result: "The meeting is on Friday.")
        let (out, status) = await runCleanup(
            engine, text: "um the meeting is on tuesday wait no friday", style: "polish", timeoutS: 3.0)
        XCTAssertEqual(out, "The meeting is on Friday.")
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertEqual(engine.calls[0].text, "um the meeting is on tuesday wait no friday")
        XCTAssertEqual(engine.calls[0].style, "polish")
        XCTAssertEqual(engine.calls[0].timeoutS, 3.0)
    }

    func testRunCleanupTimeoutFallsBackToRaw() async {
        let (out, status) = await runCleanup(FakeEngine(result: nil), text: raw, style: "polish", timeoutS: 3.0)
        XCTAssertEqual(out, raw)
        XCTAssertEqual(status, .timeout)
    }

    func testRunCleanupErrorFallsBackToRaw() async {
        let (out, status) = await runCleanup(
            FakeEngine(throws: true), text: raw, style: "light", timeoutS: 3.0)
        XCTAssertEqual(out, raw)
        XCTAssertEqual(status, .error)
    }

    func testRunCleanupRejectedFallsBackToRaw() async {
        let engine = FakeEngine(result: "<think>let me reason</think>")
        let (out, status) = await runCleanup(engine, text: raw, style: "polish", timeoutS: 3.0)
        XCTAssertEqual(out, raw)
        XCTAssertEqual(status, .rejected)
    }

    // MARK: - commonPrefixLen

    func testCommonPrefixLenDiverging() {
        XCTAssertEqual(CleanupLogic.commonPrefixLen([1, 2, 3], [1, 2, 4]), 2)
    }

    func testCommonPrefixLenIdentical() {
        XCTAssertEqual(CleanupLogic.commonPrefixLen([1, 2, 3], [1, 2, 3]), 3)
    }

    func testCommonPrefixLenOneIsPrefixOfOther() {
        XCTAssertEqual(CleanupLogic.commonPrefixLen([1, 2, 3], [1, 2]), 2)
    }

    func testCommonPrefixLenEmpty() {
        XCTAssertEqual(CleanupLogic.commonPrefixLen([], [1, 2]), 0)
    }

    func testCommonPrefixLenNoOverlap() {
        XCTAssertEqual(CleanupLogic.commonPrefixLen([9], [1]), 0)
    }

    // MARK: - self-correction coverage

    func testCorrectionRuleCoversCountRevisions() {
        let rules = CleanupLogic.buildMessages(text: "x", style: "polish")[0].content.lowercased()
        XCTAssertTrue(rules.contains("wait no"))
        XCTAssertTrue(rules.contains("number, or count"))
    }

    func testFewShotIncludesCountRevisionExample() {
        let msgs = CleanupLogic.buildMessages(text: "x", style: "polish")
        var pairs: [(String, String)] = []
        var i = 1
        while i < msgs.count - 1 {
            pairs.append((msgs[i].content, msgs[i + 1].content))
            i += 2
        }
        XCTAssertTrue(pairs.contains { $0.0.contains("four options wait no five") })
    }

    // MARK: - spoken list commands

    func testListRulePresentInBothStyles() {
        for style in ["light", "polish"] {
            let rules = CleanupLogic.buildMessages(text: "x", style: style)[0].content.lowercased()
            XCTAssertTrue(rules.contains("make a list"))
            XCTAssertTrue(rules.contains("list down"))
            XCTAssertTrue(rules.contains("bulleted"))
        }
    }

    func testFewShotIncludesListExample() {
        let msgs = CleanupLogic.buildMessages(text: "x", style: "polish")
        var pairs: [(String, String)] = []
        var i = 1
        while i < msgs.count - 1 {
            pairs.append((msgs[i].content, msgs[i + 1].content))
            i += 2
        }
        let example = pairs.first { $0.0.contains("make a list") }?.1
        XCTAssertNotNil(example)
        // the modelled answer is a real bulleted list, one "- " item per line
        let bullets = (example ?? "").split(separator: "\n").filter { $0.hasPrefix("- ") }.count
        XCTAssertGreaterThanOrEqual(bullets, 3)
    }
}
