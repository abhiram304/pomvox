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
    @EnvironmentObject var telemetry: TelemetryModel
    @State private var selection: NavItem = .home
    @State private var showConsent = false

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
            NotificationCenter.default.publisher(for: .pomvoxHistoryDidChange)
                .receive(on: RunLoop.main)
        ) { _ in model.reload() }
        // Menu bar "Open Setup…" deep link.
        .onReceive(NotificationCenter.default.publisher(for: .pomvoxShowSetup)) { _ in
            selection = .setup
        }
        // One-time telemetry choice screen (Share / No thanks). Shows on the
        // first manual open of the Hub; a login-item launch suppresses the
        // window, so it defers to the next time the window appears — and the
        // `maySend` gate means nothing sends until the user has chosen "Share".
        .onAppear { showConsent = telemetry.needsConsentPrompt }
        .sheet(isPresented: $showConsent) {
            TelemetryConsentSheet().environmentObject(telemetry)
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
