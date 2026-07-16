import XCTest
@testable import Pomvox

final class VariantGeneratorTests: XCTestCase {

    func testCamelCaseSplits() {
        let v = VariantGenerator.heuristicVariants(for: "ChargeBee")
        XCTAssertTrue(v.contains("charge bee"))
    }

    func testAcronymLetterSpacing() {
        let v = VariantGenerator.heuristicVariants(for: "GPT")
        XCTAssertTrue(v.contains("g p t"))
    }

    func testHyphenAndSpaceVariants() {
        let v = VariantGenerator.heuristicVariants(for: "parakeet-mlx")
        XCTAssertTrue(v.contains("parakeet mlx"))
    }

    func testDigitBoundarySplit() {
        let v = VariantGenerator.heuristicVariants(for: "Qwen3")
        XCTAssertTrue(v.contains("qwen 3"))
    }

    func testNeverEchoesTheTermItself() {
        for term in ["Pomvox", "GPT", "parakeet-mlx", "plain"] {
            let v = VariantGenerator.heuristicVariants(for: term)
            XCTAssertFalse(v.contains { $0.caseInsensitiveCompare(term) == .orderedSame },
                           "echoed \(term)")
        }
    }

    func testDedupedAndLowercased() {
        let v = VariantGenerator.heuristicVariants(for: "MLX")
        XCTAssertEqual(v.count, Set(v).count)
        XCTAssertTrue(v.allSatisfy { $0 == $0.lowercased() })
    }

    func testPlainLowercaseWordYieldsNothing() {
        // "plain" has no humps, digits, hyphens, or caps: nothing to suggest.
        XCTAssertEqual(VariantGenerator.heuristicVariants(for: "plain"), [])
    }

    func testEmptyAndWhitespaceYieldNothing() {
        XCTAssertEqual(VariantGenerator.heuristicVariants(for: ""), [])
        XCTAssertEqual(VariantGenerator.heuristicVariants(for: "   "), [])
    }
}
