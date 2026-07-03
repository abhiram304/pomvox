import AppKit
import ServiceManagement
import SwiftUI

/// The status item (M7a): Pomvox's resident face once the Hub window closes.
/// `.menu` style — a static menu, no timers, no run-loop cost; the icon is
/// driven purely by the engine's @Published status.
struct MenuBarIcon: View {
    let status: NativeEngine.Status

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("Pomvox — \(shortStatus)")
    }

    private var symbol: String {
        switch status {
        case .recording, .transcribing: "mic.fill"
        case .blocked, .failed:         "waveform.badge.exclamationmark"
        default:                        "waveform"
        }
    }

    private var shortStatus: String {
        switch status {
        case .off:          "engine off"
        case .preparing:    "preparing"
        case .ready:        "ready"
        case .recording:    "recording"
        case .transcribing: "transcribing"
        case .blocked:      "blocked"
        case .failed:       "needs attention"
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var engine: NativeEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        Button("Open Hub…") { openHub() }
        if needsAttention {
            Button("Open Setup…") {
                openHub()
                NotificationCenter.default.post(name: .pomvoxShowSetup, object: nil)
            }
        }
        Divider()
        Toggle("Use the native engine", isOn: engineBinding)
        Divider()
        Button("Quit Pomvox") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Same live-control semantics as the Settings toggle (user-initiated, so
    /// the interactive arm path with its permission prompt is right here).
    private var engineBinding: Binding<Bool> {
        Binding(
            get: { engine.isArmed },
            set: { on in
                if on { Task { await engine.arm() } } else { engine.disarm() }
            })
    }

    private func openHub() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: HubWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var needsAttention: Bool {
        switch engine.status {
        case .blocked, .failed: true
        default: false
        }
    }

    private var statusLine: String {
        switch engine.status {
        case .off:          "Engine off"
        case .preparing:    "Preparing the speech model…"
        case .ready:        "Ready — hold Fn to dictate"
        case .recording:    "Recording…"
        case .transcribing: "Transcribing…"
        case .blocked:      "Blocked — another engine is running"
        case .failed:       "Needs attention — open Setup"
        }
    }
}

extension Notification.Name {
    /// Deep link from the menu bar into the Hub's Setup pane.
    static let pomvoxShowSetup = Notification.Name("app.pomvox.showSetup")
}

/// Launch-at-login via SMAppService — the service's status is the source of
/// truth (no config key). Registration follows the app's code identity, so it
/// must be exercised from the stable `~/Applications` copy, not DerivedData.
@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled

    var binding: Binding<Bool> {
        Binding(get: { self.enabled }, set: { self.set($0) })
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("login-item: %@ failed: %@",
                  on ? "register" : "unregister", String(describing: error))
        }
        refresh()
    }

    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
    }
}
