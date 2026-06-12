import SwiftUI

@main
struct MurmurApp: App {
    @StateObject private var model = HubModel()
    @StateObject private var settings = SettingsModel()
    @StateObject private var reinserter = ReinsertController()
    @StateObject private var engine = NativeEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(reinserter)
                .environmentObject(engine)
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
    }
}
