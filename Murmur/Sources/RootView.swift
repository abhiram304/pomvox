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
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .home:     HomeView(goToHistory: { selection = .history })
        case .history:  HistoryView()
        case .settings: ComingSoonView(item: .settings)
        case .setup:    ComingSoonView(item: .setup)
        }
    }
}

/// Settings/Setup land in later milestones (M2/M7); the shell shows their place
/// honestly rather than faking panes.
struct ComingSoonView: View {
    let item: NavItem
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.muted)
            Text(item.title).font(Typo.display(22))
            Text(item == .settings
                 ? "Models, hotkeys, voice, and privacy — arriving next."
                 : "Permission checklist and the dictation self-test — arriving with the native engine.")
                .font(Typo.ui(13)).foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
