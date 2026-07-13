import SwiftUI

/// The explicit low-memory cleanup prompt (item 7). PR #65 silently defaulted
/// transcript cleanup off on ≤ 8 GB Macs, which left those users wondering why a
/// feature was missing. The engine still runs with cleanup off by default there
/// (so a low-memory Mac works out of the box), but instead of writing that
/// choice silently, the Hub shows a one-time prompt that explains the memory
/// tradeoff and lets the user turn it on — with the compact, memory-appropriate
/// model (item 6).

/// Pure decision: whether to show the one-time low-memory cleanup prompt.
enum LowMemoryCleanupDecision {
    /// Show only on a low-memory Mac, only when the user hasn't already made an
    /// explicit `[cleanup] enabled` choice (key absent), and only once (a
    /// per-install "prompted" flag). Answering writes the key, so it never
    /// re-asks.
    static func shouldPrompt(
        isLowMemory: Bool, cleanupKeyPresent: Bool, alreadyPrompted: Bool
    ) -> Bool {
        isLowMemory && !cleanupKeyPresent && !alreadyPrompted
    }
}

/// Observable state behind the prompt: reads the machine's memory tier and the
/// current config, and writes the user's explicit choice to `config.toml`.
@MainActor
final class LowMemoryCleanupModel: ObservableObject {
    static let promptedKey = "cleanup.lowMemPrompted"

    @Published private(set) var needsPrompt: Bool

    /// The compact model we'd switch to when enabling on this Mac (item 6).
    let recommendedModel: String

    private let defaults: UserDefaults
    private let configPath: String

    init(defaults: UserDefaults = .standard,
         configPath: String = SettingsModel.defaultPath(),
         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.defaults = defaults
        self.configPath = configPath
        self.recommendedModel = MemoryTier.firstRunCleanupModel(physicalMemoryBytes: physicalMemory)
        let doc = ConfigDocument.load(path: configPath)
        self.needsPrompt = LowMemoryCleanupDecision.shouldPrompt(
            isLowMemory: MemoryTier.isLowMemory(physicalMemory),
            cleanupKeyPresent: doc.bool("cleanup", "enabled") != nil,
            alreadyPrompted: defaults.bool(forKey: Self.promptedKey))
    }

    /// Turn cleanup on and switch to the compact model for this Mac. Takes effect
    /// on the next engine arm (models are snapshot-at-arm), like any model change.
    func enableCleanup() {
        writeCleanup(enabled: true, model: recommendedModel)
        finish()
    }

    /// Keep cleanup off — but record the explicit choice so we don't re-ask.
    ///
    /// Pin the memory-appropriate (compact) model alongside the off choice, but
    /// only when the user hasn't already chosen a model explicitly. Writing the
    /// off choice *creates* the config file, which flips `loadEngineConfig`'s
    /// "fresh install?" heuristic (`configExists`) to true; without a model key
    /// a later manual enable would fall back to the standard 4B default on this
    /// low-memory Mac, defeating item 6. Seeding compact here preserves that
    /// guarantee, while the `== nil` check never overwrites an explicit choice.
    func keepOff() {
        let existingModel = ConfigDocument.load(path: configPath).string("cleanup", "model")
        writeCleanup(enabled: false, model: existingModel == nil ? recommendedModel : nil)
        finish()
    }

    private func writeCleanup(enabled: Bool, model: String?) {
        var doc = ConfigDocument.load(path: configPath)
        doc.set("cleanup", "enabled", bool: enabled)
        if let model { doc.set("cleanup", "model", string: model) }
        try? doc.write(to: configPath)
    }

    private func finish() {
        defaults.set(true, forKey: Self.promptedKey)
        needsPrompt = false
        // Emitted for BOTH choices on purpose: "Keep it off" and "Enable
        // cleanup" each write an explicit `[cleanup] enabled` key (the whole
        // point of item 7 — replacing the silent default with a recorded user
        // choice), so both are genuine setting changes. The event is anonymous:
        // it signals only that *a* setting changed, never which one or its
        // value, so it can't reveal the user's answer.
        TelemetryClient.shared.emit(.settingChanged)
    }
}

enum LowMemoryCleanupCopy {
    static let headline = "Turn on transcript cleanup?"
    static let blurb =
        "Your Mac has limited memory (8 GB or less). Transcript cleanup runs a small "
        + "language model to fix filler words and punctuation — it adds about 1.4 GB of "
        + "memory while active (we'd use the compact model on your Mac). Dictation works "
        + "great without it, so it's off by default here. Enable it anyway?"
    static let footer = "You can change this anytime in Settings → Models."
}

/// One-time low-memory cleanup choice. Equal-weight buttons, no dark pattern —
/// dictation is fully usable either way.
struct LowMemoryCleanupSheet: View {
    @EnvironmentObject var lowMem: LowMemoryCleanupModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "memorychip")
                    .font(.system(size: 20)).foregroundStyle(Palette.ember)
                Text(LowMemoryCleanupCopy.headline)
                    .font(Typo.display(22)).foregroundStyle(Palette.ink)
            }
            Text(LowMemoryCleanupCopy.blurb)
                .font(Typo.ui(13)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(LowMemoryCleanupCopy.footer)
                .font(Typo.ui(11.5)).foregroundStyle(Palette.muted)

            HStack(spacing: 12) {
                Spacer()
                choiceButton("Keep it off") { lowMem.keepOff(); dismiss() }
                choiceButton("Enable cleanup") { lowMem.enableCleanup(); dismiss() }
            }
        }
        .padding(28)
        .frame(width: 520)
        .background(Palette.pane)
        .interactiveDismissDisabled()   // the choice must be made explicitly
    }

    private func choiceButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Typo.ui(13, .semibold)).foregroundStyle(Palette.ink)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(Capsule().fill(Palette.pane2))
            .overlay(Capsule().stroke(Palette.hair, lineWidth: 0.5))
    }
}
