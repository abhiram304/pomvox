import XCTest
@testable import Pomvox

final class VariantParsingTests: XCTestCase {

    func testParsesOnePerLineStrippingBulletsAndNumbers() {
        let raw = "- pom box\n2. palm vox\n* pomm vocks\n"
        XCTAssertEqual(parseVariantLines(raw, term: "Pomvox"),
                       ["pom box", "palm vox", "pomm vocks"])
    }

    func testDropsEchoesBlanksAndLongJunk() {
        let raw = "Pomvox\n\npom box\nthis is a whole explanatory sentence about the word\n"
        XCTAssertEqual(parseVariantLines(raw, term: "Pomvox"), ["pom box"])
    }

    func testLowercasesAndDedupes() {
        XCTAssertEqual(parseVariantLines("Pom Box\npom box\n", term: "Pomvox"), ["pom box"])
    }

    func testCapsAtSix() {
        let raw = (1...10).map { "variant \($0)" }.joined(separator: "\n")
        XCTAssertEqual(parseVariantLines(raw, term: "X").count, 6)
    }
}
