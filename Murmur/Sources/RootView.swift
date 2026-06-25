import SwiftUI

enum NavItem: String, CaseIterable, Identifiable {
    case home, history, settings, setup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"; case .history: "History"
        case .settings: "Settings"; case .setup: "Setup"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"; case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"; case .setup: "checkmark.shield"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: HubModel
    @State private var selection: NavItem = .home

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 224, ideal: 246, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.pane)
        }
        .navigationTitle("")
        .toolbar(removing: .sidebarToggle)
        // The native engine writes rows in-process now — refresh on each insert.
        .onReceive(
            NotificationCenter.default.publisher(for: .murmurHistoryDidChange)
                .receive(on: RunLoop.main)
        ) { _ in model.reload() }
        // Menu bar "Open Setup…" deep link.
        .onReceive(NotificationCenter.default.publisher(for: .murmurShowSetup)) { _ in
            selection = .setup
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .home:     HomeView(goToHistory: { selection = .history })
        case .history:  HistoryView()
        case .settings: SettingsView()
        case .setup:    SetupView()
        }
    }
}
