import SwiftUI

/// The quiet, native update affordance on Home. Renders only while an update
/// session is in a banner state — never a popup, never a Sparkle window.
struct UpdateBanner: View {
    @EnvironmentObject var updater: UpdaterModel

    var body: some View {
        if updater.state.showsBanner {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17)).foregroundStyle(Palette.ember)
                content
                Spacer(minLength: 12)
                actions
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair, lineWidth: 0.5))
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case let .updateAvailable(version, notesURL):
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available — v\(version)")
                    .font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
                if let notesURL {
                    Link("Release notes", destination: notesURL)
                        .font(Typo.ui(12)).foregroundStyle(Palette.ember)
                }
            }
        case let .downloading(fraction):
            progressLine("Downloading update…", fraction: fraction)
        case let .extracting(fraction):
            progressLine("Preparing update…", fraction: fraction)
        case .readyToRelaunch:
            Text("Finishing your dictation, then restarting…")
                .font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
        case .installing:
            Text("Restarting to finish the update…")
                .font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        if case .updateAvailable = updater.state {
            HStack(spacing: 10) {
                Button("Skip this version") { updater.skip() }
                    .buttonStyle(.plain)
                    .font(Typo.ui(12)).foregroundStyle(Palette.muted)
                Button("Later") { updater.later() }
                    .buttonStyle(.plain)
                    .font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.inkSoft)
                Button { updater.install() } label: {
                    Text("Update")
                        .font(Typo.ui(12.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Palette.ember))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func progressLine(_ label: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
            if let fraction {
                ProgressView(value: fraction).tint(Palette.ember).frame(maxWidth: 260)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
