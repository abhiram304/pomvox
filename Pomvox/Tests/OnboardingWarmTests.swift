import XCTest
@testable import Pomvox

/// One-time onboarding warm gate (item 2): warm both models eagerly on the first
/// arm, then fall through to the lazy path on every later launch.
final class OnboardingWarmTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        let name = "onboardingwarm.tests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testFreshInstallWarmsNow() {
        let w = OnboardingWarm(defaults: freshDefaults())
        XCTAssertTrue(w.shouldWarmNow, "a fresh install has never warmed")
    }

    func testAfterMarkingItDoesNotWarmAgain() {
        let defaults = freshDefaults()
        let a = OnboardingWarm(defaults: defaults)
        XCTAssertTrue(a.shouldWarmNow)
        a.markWarmed()
        XCTAssertFalse(a.shouldWarmNow, "same instance no longer warms")
        // The flag persists to a new instance (next launch).
        XCTAssertFalse(OnboardingWarm(defaults: defaults).shouldWarmNow)
    }
}
