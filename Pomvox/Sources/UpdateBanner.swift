import SwiftUI

/// The Home update banner (design §UI surfaces #1). Visible only from
/// "update available" through installing. Offers a single Update click that
/// drives inline progress (downloading % → preparing) through relaunch, plus
/// Later / Skip and a release-notes link. Never a popup.
struct UpdateBanner: View {
    @EnvironmentObject var updater: UpdaterModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20)).foregroundStyle(Palette.ember)

            VStack(alignment: .leading, spacing: 3) {
                Text(updater.state.statusLine)
                    .font(Typo.ui(13.5, .semibold)).foregroundStyle(Palette.ink)
                if case .updateAvailable = updater.state {
                    Link("Release notes", destination: releaseNotesURL)
                        .font(Typo.ui(11.5)).foregroundStyle(Palette.ember)
                } else if let fraction = updater.state.downloadFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear).tint(Palette.ember).frame(width: 180)
                } else if isInProgress {
                    ProgressView().progressViewStyle(.linear).tint(Palette.ember).frame(width: 180)
                }
            }

            Spacer(minLength: 12)

            if case .updateAvailable = updater.state {
                actions
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.ember.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ember.opacity(0.35), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(updater.state.statusLine)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Skip this version") { updater.skipThisVersion() }
                .buttonStyle(.plain).font(Typo.ui(12)).foregroundStyle(Palette.muted)
            Button("Later") { updater.remindLater() }
                .buttonStyle(.plain).font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.inkSoft)
            Button(action: { updater.update() }) {
                Text("Update").font(Typo.ui(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Capsule().fill(Palette.ember))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download and install the update")
        }
    }

    private var isInProgress: Bool {
        switch updater.state {
        case .downloading, .extracting, .readyToRelaunch, .installing: return true
        default: return false
        }
    }

    private var releaseNotesURL: URL {
        updater.state.releaseNotesURL ?? UpdaterModel.releasesPageURL
    }
}
