import AppKit
import Foundation

/// M7a app bootstrap: Pomvox.app is menu-bar-first now. The delegate decides
/// the window posture at launch, keeps the Dock icon honest (visible only
/// while the Hub window is open), and kicks the launch jobs — the retention
/// purge and, when `[engine] native` is enabled, the silent auto-arm.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// During a login-item launch we suppress the auto-created Hub window for
    /// a beat: SwiftUI (macOS 14) restores it slightly after
    /// `applicationDidFinishLaunching`, so a one-shot close isn't enough.
    private var suppressHubWindowUntil = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.launchedAsLoginItem() {
            NSLog("pomvox-app: login-item launch — menu bar only")
            enterMenuBarOnly()
        }
        watchHubWindowLifecycle()
        bootstrap()
    }

    /// Finder/Dock reopen with no visible window: back to Hub posture and let
    /// SwiftUI restore the window (return true = proceed with default).
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            NSApp.setActivationPolicy(.regular)
        }
        return true
    }

    // MARK: - launch posture

    /// The SMAppService login launch arrives as a kAEOpenApplication Apple
    /// Event tagged keyAELaunchedAsLogInItem — the documented way to tell
    /// "session start" from "the user opened me".
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
    }

    private func enterMenuBarOnly() {
        NSApp.setActivationPolicy(.accessory)
        suppressHubWindowUntil = Date().addingTimeInterval(2)
        closeHubWindows()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.closeHubWindows() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, Date() < self.suppressHubWindowUntil,
                      let window = note.object as? NSWindow, Self.isHubWindow(window)
                else { return }
                window.close()
            }
        }
    }

    private func closeHubWindows() {
        for window in NSApp.windows where Self.isHubWindow(window) {
            window.close()
        }
    }

    /// Dock icon follows the Hub window: closing the last Hub window drops the
    /// app back to a menu-bar resident (the HUD panel doesn't count).
    private func watchHubWindowLifecycle() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let closing = note.object as? NSWindow, Self.isHubWindow(closing) else { return }
                DispatchQueue.main.async {
                    let hubStillOpen = NSApp.windows.contains {
                        Self.isHubWindow($0) && $0.isVisible
                    }
                    if !hubStillOpen { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
    }

    private static func isHubWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(HubWindow.id) == true
    }

    // MARK: - launch jobs

    private func bootstrap() {
        let doc = ConfigDocument.load(path: SettingsModel.defaultPath())

        // Retention purge at launch: Python purges on insert, but a native-only
        // user with the engine off inserts nothing — someone must still purge.
        if doc.bool("history", "enabled") ?? true {
            let retentionDays = doc.int("history", "retention_days") ?? 7
            Task.detached(priority: .utility) {
                HistoryStore.purgeExisting(
                    path: HistoryReader.defaultPath(), retentionDays: retentionDays,
                    now: Date().timeIntervalSince1970)
            }
        }

        // The M7a inversion: `[engine] native` now means "arm on launch", not
        // just "the toggle's persisted value". Silent — at login a missing
        // grant becomes a menu-bar badge routing to Setup, never a dialog.
        if doc.bool("engine", "native") ?? false {
            Task { await NativeEngine.shared.arm(interactive: false) }
        }
    }
}

enum HubWindow {
    /// The Window scene id — also the NSWindow identifier prefix SwiftUI stamps.
    static let id = "hub"
}
