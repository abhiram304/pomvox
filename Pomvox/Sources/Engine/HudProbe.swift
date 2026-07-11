import CoreGraphics
import Foundation

/// Post-show self-check for the HUD pill. "The HUD never appeared" reports are
/// undiagnosable without ground truth about what the window server actually
/// displayed — this asks CGWindowList whether a pill-sized window of ours is on
/// screen ~0.3 s after `show()`. The decision is pure (`hudPillFound`) so it is
/// unit-tested; only the collector touches the window server.
struct HudWindowInfo: Equatable {
    var ownerPID: Int
    var size: CGSize
    var alpha: Double
    var layer: Int
}

/// Does *windows* contain an on-screen, non-transparent window owned by *pid*
/// whose size matches the HUD pill (within *tolerance* pts for rounding)?
func hudPillFound(windows: [HudWindowInfo], pid: Int,
                  pillSize: CGSize, tolerance: CGFloat = 2.0) -> Bool {
    windows.contains { w in
        w.ownerPID == pid && w.alpha > 0.01
            && abs(w.size.width - pillSize.width) <= tolerance
            && abs(w.size.height - pillSize.height) <= tolerance
    }
}

/// What the post-show probe should do with its result. The initial probe may
/// heal (rebuild the panel — a fresh window-server window orders in when a
/// wedged one won't, proven live 2026-07-11); the post-heal verification probe
/// only reports, so one show() can never rebuild more than once.
enum HudProbeAction: Equatable {
    case none              // pill on screen — nothing to do
    case healAndRecheck    // miss on the original panel — rebuild + verify
    case reportHealFailed  // miss on the REBUILT panel — log/telemetry only
}

func hudProbeAction(pillVisible: Bool, isPostHealCheck: Bool) -> HudProbeAction {
    if pillVisible { return .none }
    return isPostHealCheck ? .reportHealFailed : .healAndRecheck
}

enum HudProbe {
    /// Snapshot of all on-screen windows (any process). `optionOnScreenOnly`
    /// already excludes ordered-out and fully-hidden windows.
    static func onScreenWindows() -> [HudWindowInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return raw.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            return HudWindowInfo(
                ownerPID: pid,
                size: CGSize(width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0),
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1.0,
                layer: info[kCGWindowLayer as String] as? Int ?? 0)
        }
    }
}
