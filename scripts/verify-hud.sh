#!/bin/bash
# End-to-end HUD check: synthesize an Fn press (needs Accessibility for the
# terminal), hold 2 s, release, and ask the window server whether the 420×64
# pill appeared. Run against a live, armed Pomvox.
#
# WARNING: posts a real synthetic Fn keypress — any transcribed room audio may
# paste into the frontmost app. Focus a scratch document first.
#
# Exit codes: 0 = PASS, 1 = HUD not visible (or CGEvent failure),
#             2 = SKIP (terminal lacks Accessibility permission).
set -euo pipefail
echo "WARNING: posts a real synthetic Fn keypress — any transcribed room audio may paste into the frontmost app. Focus a scratch document first."
swift - <<'EOF'
import ApplicationServices
import CoreGraphics
import Foundation

guard AXIsProcessTrusted() else {
    print("SKIP: this terminal lacks Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility) — cannot post synthetic keys")
    exit(2)
}

func fn(_ down: Bool) {
    guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down) else {
        print("FAIL: could not create CGEvent")
        exit(1)
    }
    e.type = .flagsChanged
    e.flags = down ? .maskSecondaryFn : []
    e.post(tap: .cgSessionEventTap)
}

func pillOnScreen() -> Bool {
    let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return wins.contains { w in
        guard (w["kCGWindowOwnerName"] as? String) == "Pomvox",
              let b = w["kCGWindowBounds"] as? [String: CGFloat] else { return false }
        return abs((b["Width"] ?? 0) - 420) <= 2 && abs((b["Height"] ?? 0) - 64) <= 2
    }
}

fn(true)
// Probe at 0.9 s: the energy VAD auto-stops a silent capture at ~1.6 s, so a
// 2.0 s probe can land in the pill's fade-out. 0.9 s is safely mid-recording.
Thread.sleep(forTimeInterval: 0.9)
let visible = pillOnScreen()
Thread.sleep(forTimeInterval: 1.1)   // keep the full 2 s hold before releasing Fn
fn(false)
Thread.sleep(forTimeInterval: 1.0)
print(visible ? "PASS: HUD pill visible during recording" : "FAIL: HUD pill NOT visible")
exit(visible ? 0 : 1)
EOF
