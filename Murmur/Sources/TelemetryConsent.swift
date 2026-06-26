import SwiftUI

/// Observable wrapper over `TelemetryStore` for the consent UI — the first-run
/// sheet and the Privacy-pane toggle both drive this, so they always agree.
/// Honest by construction: off until the user chooses, the choice is honored,
/// and turning it off stops all sending immediately (the client re-reads consent
/// from UserDefaults on every flush).
@MainActor
final class TelemetryModel: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var prompted: Bool
    private var store: TelemetryStore

    init(store: TelemetryStore = TelemetryStore()) {
        self.store = store
        self.enabled = store.enabled
        self.prompted = store.prompted
    }

    /// The one-time first-run prompt is owed until the user has answered it.
    var needsConsentPrompt: Bool { !prompted }

    /// Privacy-pane toggle binding — persists + emits on change.
    var binding: Binding<Bool> {
        Binding(get: { self.enabled }, set: { self.setEnabled($0) })
    }

    /// First-run answer: record the choice and that the prompt was shown.
    func resolveConsent(enable: Bool) {
        prompted = true
        store.prompted = true
        setEnabled(enable)
    }

    private func setEnabled(_ on: Bool) {
        guard on != store.enabled else { return }
        store.enabled = on
        enabled = on
        // Record the change only when turning ON (an off→event would itself be a
        // send the user just declined). The gate handles the off case: no send.
        if on { TelemetryClient.shared.emit(.settingChanged) }
    }
}

/// The exact, plain-language "here's what we send" disclosure — shared by the
/// first-run sheet and the Privacy pane so the two can never drift apart.
enum TelemetryCopy {
    static let headline = "Help improve Murmur?"
    static let blurb =
        "Murmur can send anonymous, content-free usage stats so the maintainer "
        + "can see how it's used and what's breaking. It's optional and off "
        + "unless you turn it on."

    static let sends: [String] = [
        "A random install ID — anonymous, not tied to you or your Mac.",
        "App and macOS version, architecture.",
        "That a dictation happened: its duration, which models ran, whether "
            + "cleanup was used and how it finished.",
        "Error codes (a fixed list — never messages or stack traces).",
    ]

    static let neverSends: [String] = [
        "Your voice or any audio — ever.",
        "Any transcript or cleaned-up text — ever.",
        "No account, no name, no email, no file paths, no free text.",
    ]

    static let footer = "Off by default. Change anytime in Settings → Privacy."
}

/// One-time first-run consent sheet. Clear choice, no dark pattern: Enable or
/// Not now, both honored, both dismiss for good.
struct TelemetryConsentSheet: View {
    @EnvironmentObject var telemetry: TelemetryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 20)).foregroundStyle(Palette.ember)
                    Text(TelemetryCopy.headline)
                        .font(Typo.display(22)).foregroundStyle(Palette.ink)
                }
                Text(TelemetryCopy.blurb)
                    .font(Typo.ui(13)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 16) {
                disclosure(title: "What it sends", symbol: "checkmark.circle.fill",
                           tint: Palette.muted, lines: TelemetryCopy.sends)
                disclosure(title: "What it never sends", symbol: "lock.fill",
                           tint: Palette.ember, lines: TelemetryCopy.neverSends)
            }

            Text(TelemetryCopy.footer)
                .font(Typo.ui(11.5)).foregroundStyle(Palette.muted)

            HStack(spacing: 12) {
                Spacer()
                Button("Not now") { answer(false) }
                    .buttonStyle(.plain)
                    .font(Typo.ui(13, .medium)).foregroundStyle(Palette.inkSoft)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Capsule().fill(Palette.pane2))
                Button("Enable") { answer(true) }
                    .buttonStyle(.plain)
                    .font(Typo.ui(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 7)
                    .background(Capsule().fill(Palette.ember))
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(Palette.pane)
    }

    private func disclosure(title: String, symbol: String, tint: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Typo.ui(10.5, .semibold)).tracking(0.5).foregroundStyle(Palette.muted)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(tint)
                        .padding(.top, 2)
                    Text(line).font(Typo.ui(11.5)).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hair, lineWidth: 0.5))
    }

    private func answer(_ enable: Bool) {
        telemetry.resolveConsent(enable: enable)
        dismiss()
    }
}
