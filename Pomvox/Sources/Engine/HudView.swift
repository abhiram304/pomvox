import SwiftUI

/// The HUD's render state, observed by `HudView`. Updated on the main thread by
/// `HudController`. The two-tone split (stable/volatile) is computed by the
/// controller against the previously-displayed draft, mirroring `hud.py`'s
/// `_set_two_tone_draft`; the waveform `bars` are pushed by the controller's
/// 15 Hz sampling timer (only while recording).
@MainActor
final class HudRenderModel: ObservableObject {
    @Published var vm = HudViewModel()
    @Published var bars: [Double] = Array(repeating: 0.0, count: 24)
    @Published var stableDraft = ""
    @Published var volatileDraft = ""
    @Published var showDraft = true
    /// Whether the HUD pill is actually on screen (window occlusion state). The
    /// shimmer's `repeatForever` sweep pauses when this is false so an off-screen
    /// / occluded HUD costs ~0% CPU. `HudController` keeps it in sync from the
    /// panel's occlusion notifications.
    @Published var windowVisible = true
}

/// SwiftUI content of the floating HUD pill. A dumb view over `HudRenderModel` —
/// no `repeatForever` animations; the waveform and silence arc redraw only when
/// their data changes (and that only happens while recording). The pill is always
/// dark (it floats over arbitrary apps), so colors are fixed rather than the
/// appearance-adaptive `Palette` — except the ember recording dot (brand tie).
struct HudView: View {
    @ObservedObject var model: HudRenderModel

    private var vm: HudViewModel { model.vm }

    var body: some View {
        HStack(spacing: 12) {
            if vm.state == "recording" {
                HudWaveform(bars: model.bars)
                    .frame(width: 84, height: 32)
            } else if !glyph.isEmpty {
                Text(glyph)
                    .font(.system(size: 20))
                    .frame(width: 84, height: 32)
            }
            VStack(alignment: .leading, spacing: 4) {
                statusRow
                draftRow
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(width: HudConst.pillSize.width, height: HudConst.pillSize.height)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.85))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Live draft must never land in a screen recording — belt to the panel's
        // sharingType = .none.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            if vm.state == "recording" {
                Circle().fill(Palette.ember).frame(width: 9, height: 9)
            }
            Text(vm.status)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .lineLimit(vm.state == "error" ? 2 : 1)
                .truncationMode(vm.state == "error" ? .tail : .head)
                .multilineTextAlignment(.leading)
            if vm.state == "recording" && vm.endpointFraction > 0.4 {
                HudSilenceArc(fraction: vm.endpointFraction)
                    .frame(width: 16, height: 16)
            }
        }
    }

    @ViewBuilder
    private var draftRow: some View {
        if vm.state == "done" {
            Text(vm.final)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1).truncationMode(.head)
        } else if vm.state == "recording" && model.showDraft {
            // Settled words bright, the newest chunk dimmed — the visible cue
            // that text is streaming, not stuck.
            (Text(model.stableDraft).foregroundColor(.white.opacity(0.92))
                + Text(model.volatileDraft).foregroundColor(.gray))
                .font(.system(size: 13))
                .lineLimit(1).truncationMode(.head)
        } else if vm.placeholder {
            // Cold first inference (item 8): a moving skeleton so the wait reads
            // as "working", not "stuck", while the model spins up. Its sweep is
            // gated on the pill actually being on screen.
            HudShimmerBar(animating: model.windowVisible).frame(width: 180, height: 10)
        } else {
            EmptyView()
        }
    }

    private var glyph: String {
        switch vm.state {
        case "transcribing", "polishing": return "✍️"
        case "done": return "✓"
        case "cancelled": return "✕"
        default: return ""
        }
    }

    private var accessibilityText: String {
        switch vm.state {
        case "recording": return "Recording. \(vm.status)"
        case "done": return "Done. \(vm.final)"
        default: return vm.status
        }
    }
}

/// A shimmering skeleton line shown only during the first (cold) dictation's
/// transcribe/polish wait. It lives for a brief, one-time window per armed
/// session and conveys "working" instead of a frozen label.
///
/// The `repeatForever` sweep is paused whenever the pill isn't actually on
/// screen (`animating == false`), so an occluded / off-screen HUD holds the
/// "~0% CPU when idle" budget — a `repeatForever` animation otherwise keeps
/// redrawing at the display refresh rate. Note the gate is window *occlusion*,
/// not `controlActiveState` (which `Waveform` in the Hub uses): the HUD is a
/// non-activating panel shown *over* the user's active app, so its
/// `controlActiveState` reads `.inactive` during normal dictation — gating on
/// that would suppress the shimmer exactly when it's needed.
private struct HudShimmerBar: View {
    var animating: Bool
    @State private var atEnd = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(
                            colors: [.clear, .white.opacity(0.4), .clear],
                            startPoint: .leading, endPoint: .trailing))
                        .offset(x: (atEnd ? 1 : -1) * w)
                        .animation(
                            animating
                                ? .linear(duration: 1.1).repeatForever(autoreverses: false)
                                : .default,   // settle in place, no repeat, when paused
                            value: atEnd)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .onAppear { atEnd = animating }
        .onChange(of: animating) { _, active in atEnd = active }
    }
}

/// Level bars from `LevelHistory.bars()`. Rounded, centered, white. Static draw
/// per data update — no animation loop.
private struct HudWaveform: View {
    let bars: [Double]

    var body: some View {
        Canvas { context, size in
            guard !bars.isEmpty else { return }
            let bw = size.width / CGFloat(bars.count)
            for (i, v) in bars.enumerated() {
                let h = max(2.0, CGFloat(v) * size.height)
                let rect = CGRect(x: CGFloat(i) * bw + bw * 0.2,
                                  y: (size.height - h) / 2,
                                  width: bw * 0.6, height: h)
                let path = Path(roundedRect: rect, cornerRadius: bw * 0.3)
                context.fill(path, with: .color(.white.opacity(0.9)))
            }
        }
    }
}

/// The VAD auto-stop countdown: an arc that fills as silence accumulates and
/// snaps back the moment speech resumes (the controller pushes `fraction` = 0).
private struct HudSilenceArc: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(1.0, max(0.0, fraction)))
                .stroke(Palette.ember, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
