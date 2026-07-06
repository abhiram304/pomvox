import Foundation

/// First-run discoverability logic (pure, so it's vector-tested; the views are
/// dumb renderers). Pomvox is a menu-bar app that ships doing nothing until the
/// user grants Microphone, Input Monitoring, and Accessibility — a fresh user
/// with no idea those grants exist would otherwise land on an empty dashboard
/// and give up. These two decisions surface Setup instead.

extension NavItem {
    /// Which pane the Hub opens to. Any missing engine grant → the Setup
    /// checklist (with its plain-language *why* and System Settings deep links);
    /// once all three are in, the normal Home dashboard.
    static func firstRun(allPermissionsGranted: Bool) -> NavItem {
        allPermissionsGranted ? .home : .setup
    }
}

/// Whether the menu bar and sidebar should flag "setup needed." True while any
/// engine grant is still missing, or the engine is actively reporting a problem
/// whose fix path is the Setup pane.
enum SetupNudge {
    static func needed(engineNeedsAttention: Bool, allPermissionsGranted: Bool) -> Bool {
        engineNeedsAttention || !allPermissionsGranted
    }
}
