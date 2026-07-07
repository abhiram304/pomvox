#!/bin/bash
# End-to-end HUD check: synthesize an Fn press (needs Accessibility for the
# terminal), hold 2 s, release, and ask the window server whether the 420×64
# pill appeared. Run against a live, armed Pomvox.
set -euo pipefail
swift - <<'EOF'
import CoreGraphics
import Foundation

func fn(_ down: Bool) {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: down)!
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
Thread.sleep(forTimeInterval: 2.0)
let visible = pillOnScreen()
fn(false)
Thread.sleep(forTimeInterval: 1.0)
print(visible ? "PASS: HUD pill visible during recording" : "FAIL: HUD pill NOT visible")
exit(visible ? 0 : 1)
EOF
