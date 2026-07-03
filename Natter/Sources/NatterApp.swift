import SwiftUI

@main
struct NatterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = HubModel()
    @StateObject private var settings = SettingsModel()
    @StateObject private var reinserter = ReinsertController()
    @StateObject private var engine = NativeEngine.shared
    @StateObject private var telemetry = TelemetryModel()

    var body: some Scene {
        // A single Window (not WindowGroup): the Hub. The AppDelegate keeps it
        // closed on login-item launches and drops the Dock icon when it closes.
        Window("Natter", id: HubWindow.id) {
            RootView()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(reinserter)
                .environmentObject(engine)
                .environmentObject(telemetry)
                .frame(minWidth: 920, minHeight: 600)
                .onAppear { model.reload() }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            // The dictation engine owns the global hotkey; the Hub just refreshes.
            CommandGroup(after: .toolbar) {
                Button("Reload History") { model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(engine)
        } label: {
            MenuBarIcon(status: engine.status)
        }
        .menuBarExtraStyle(.menu)
    }
}
