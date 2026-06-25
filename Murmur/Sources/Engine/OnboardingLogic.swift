import Foundation

/// Port of `src/murmur/onboarding.py` `OnboardingFlow` — pure checklist state:
/// probe statuses in, display rows out. The Setup pane renders these rows; the
/// logic is pinned by OnboardingLogicTests (vector parity with
/// tests/test_onboarding.py). No account, no profile quiz — three permission
/// rows with a plain-language *why*.
struct OnboardingFlow {
    /// (key, title, why) — Python's PERMISSIONS tuple, same order.
    static let permissions: [(key: String, title: String, why: String)] = [
        ("microphone", "Microphone", "so Murmur can hear you"),
        ("input_monitoring", "Input Monitoring", "so the hotkey works in every app"),
        ("accessibility", "Accessibility", "so Murmur can type your words for you (⌘V)"),
    ]

    static let relaunchNote = "granted — relaunch Murmur to pick it up"
    static let staleTccHint =
        "Granted but still red? Remove the app from the list in System Settings "
        + "and add it back."
    static let selfTestText = "Murmur works! 🎉"

    struct Row: Equatable {
        let key: String
        let title: String
        let why: String
        let granted: Bool?
        var note: String = ""
    }

    func rows(statuses: [String: Bool?], tapInstalled: Bool) -> [Row] {
        Self.permissions.map { key, title, why in
            let granted = statuses[key] ?? nil
            var note = ""
            if key == "input_monitoring", granted == true, !tapInstalled {
                // The grant landed but CGEventTapCreate still fails: macOS
                // does not extend Input Monitoring to a running process.
                note = Self.relaunchNote
            }
            return Row(key: key, title: title, why: why, granted: granted, note: note)
        }
    }

    func complete(statuses: [String: Bool?], tapInstalled: Bool) -> Bool {
        tapInstalled && Self.permissions.allSatisfy { statuses[$0.key] ?? nil == true }
    }
}
