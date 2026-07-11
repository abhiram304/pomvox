import CoreGraphics
import Foundation

/// HUD pure logic — faithful port of `src/pomvox/hud.py` (state machine, geometry,
/// truncation, level mapping) plus `uibus.UiEvent` and `stt.split_stable_prefix`.
/// Platform-free and unit-tested; the NSPanel renderer lives in `HudPanel.swift`.
/// The Linux-tested Python `tests/test_hud.py` vectors are reproduced 1:1 in
/// `HudLogicTests.swift` — translated, not re-derived.

// MARK: - Bus events

/// The cross-thread UI event channels (port of `uibus.UiEvent`). Latest-wins per
/// channel; a drain delivers at most one payload per event.
enum UiEvent: CaseIterable {
    case state
    case draft
    case level
    case endpointProgress
    case result
}

/// A single coalesced bus payload. The associated values mirror the Python
/// tuples: STATE/RESULT carry `(name, detail)`, the rest a scalar.
enum HudPayload {
    case state(String, String)
    case draft(String)
    case level(Double)
    case endpointProgress(Double)
    case result(String, String)

    var event: UiEvent {
        switch self {
        case .state: return .state
        case .draft: return .draft
        case .level: return .level
        case .endpointProgress: return .endpointProgress
        case .result: return .result
        }
    }
}

// MARK: - Constants

enum HudConst {
    static let doneFlashS: Double = 1.4
    static let errorFlashS: Double = 2.5
    static let cancelFlashS: Double = 0.8
    static let pillSize = CGSize(width: 420.0, height: 64.0)
    static let margin: Double = 24.0

    /// Marker the engine puts in a `transcribing`/`polishing` state's detail on
    /// the first (cold) dictation after arm, so the HUD shows a shimmer
    /// placeholder while the cold model spins up (item 8) instead of a static
    /// "finishing…" that reads as stuck.
    static let coldStartMark = "cold"

    // dBFS range mapped onto the 0..1 level bars.
    static let levelFloorDbfs: Double = -60.0
    static let levelCeilDbfs: Double = -10.0

    /// Played by the renderer on state *entry* (config-gated). Names are
    /// NSSound system sounds.
    static let stateSounds: [String: String] = [
        "recording": "Tink", "done": "Pop", "error": "Basso",
    ]
}

/// Fixed apply order so a RESULT posted just before a trailing `idle` STATE in
/// the same drain still wins the "done" flash (mirrors `hud._APPLY_ORDER`).
private let applyOrder: [UiEvent] = [.state, .draft, .level, .endpointProgress, .result]

// MARK: - Pure helpers

/// Split *cur* into (stable, new) against the previous draft — the two-tone
/// treatment: settled words bright, the newest chunk dimmed. Revisions to
/// earlier words count as new. Port of `stt.split_stable_prefix`.
func splitStablePrefix(_ prev: String, _ cur: String) -> (stable: String, delta: String) {
    var n = 0
    for (a, b) in zip(prev, cur) {
        if a != b { break }
        n += 1
    }
    let idx = cur.index(cur.startIndex, offsetBy: n)
    return (String(cur[..<idx]), String(cur[idx...]))
}

/// Keep the tail — the newest words must stay visible. Port of `truncate_head`.
func truncateHead(_ text: String, _ maxChars: Int) -> String {
    if text.count <= maxChars { return text }
    return "…" + String(text.suffix(maxChars - 1))
}

/// RMS level of a float32 capture block in dBFS (port of `audio.block_dbfs`),
/// fed to `level01` for the waveform.
func blockDbfs(_ block: [Float]) -> Double {
    guard !block.isEmpty else { return 10 * log10(1e-12) }
    var sumsq = 0.0
    for x in block { sumsq += Double(x) * Double(x) }
    return 10 * log10(sumsq / Double(block.count) + 1e-12)
}

/// Map a dBFS reading onto 0..1 for the level bars. Port of `level01`.
func level01(_ dbfs: Double) -> Double {
    let span = HudConst.levelCeilDbfs - HudConst.levelFloorDbfs
    return min(1.0, max(0.0, (dbfs - HudConst.levelFloorDbfs) / span))
}

/// Pill rect inside *visibleFrame* (origins can be negative on secondary
/// displays — never assume (0, 0)). Port of `pill_frame`.
func pillFrame(
    visibleFrame: (x: Double, y: Double, w: Double, h: Double),
    pillSize: CGSize = HudConst.pillSize,
    margin: Double = HudConst.margin,
    position: String = "bottom-center"
) -> (x: Double, y: Double, w: Double, h: Double) {
    let (vx, vy, vw, vh) = visibleFrame
    let pw = Double(pillSize.width)
    let ph = Double(pillSize.height)
    let x = vx + (vw - pw) / 2
    let y: Double
    switch position {
    case "notch":
        y = vy + vh - ph              // flush under the menu bar
    case "top-center":
        y = vy + vh - ph - margin
    default:
        y = vy + margin
    }
    return (x, y, pw, ph)
}

/// Whether the controller should (re)show the panel for `state`, given the
/// previously presented `prevState`. Shows on the hidden→visible transition AND
/// at the start of a fresh recording even when a prior flash (done/error/
/// cancelled) hasn't auto-hidden yet — without the second clause a quick
/// re-record while the flash lingers is gated out and its HUD never reappears
/// (the panel is meanwhile mid hide-fade; re-showing re-asserts alpha=1 +
/// orderFront, defeating that fade). Continuations (recording→transcribing→
/// polishing) and the flashes themselves keep the existing panel as-is.
func hudShouldShow(state: String, prevState: String) -> Bool {
    if prevState == "hidden" { return true }
    return state == "recording" && prevState != "recording"
}

/// After sleep/wake the panel's window-server window may be wedged (ordering
/// no-ops — the 2026-07-11 incident). Rebuild lazily at the next present, and
/// only while hidden: a visible panel is by definition not wedged, and the
/// show-probe self-heal covers anything that slips through.
func hudShouldRebuildStale(stale: Bool, prevState: String) -> Bool {
    stale && prevState == "hidden"
}

/// Ring buffer of recent mic levels for the waveform bars. Port of `LevelHistory`.
final class LevelHistory {
    private let n: Int
    private var values: [Double]

    init(n: Int = 24) {
        self.n = n
        self.values = [Double](repeating: 0.0, count: n)
    }

    func push(_ level: Double) {
        values.removeFirst()
        values.append(level)
    }

    func bars() -> [Double] { values }

    func reset() { values = [Double](repeating: 0.0, count: n) }
}

// MARK: - View model + state machine

/// Immutable snapshot the renderer draws. Port of `HudViewModel`.
struct HudViewModel: Equatable {
    var state: String = "hidden"   // hidden|recording|transcribing|polishing|done|error|cancelled
    var status: String = ""
    var draft: String = ""
    var final: String = ""
    var level: Double = 0.0
    var endpointFraction: Double = 0.0   // 0..1 progress toward VAD auto-stop
    var hideAt: Double? = nil
    /// The cold-first-dictation shimmer cue (item 8): true while transcribing/
    /// polishing the first utterance after arm, so the renderer animates a
    /// skeleton shimmer instead of a static label.
    var placeholder: Bool = false

    var visible: Bool { state != "hidden" }
}

private let hiddenVM = HudViewModel()

/// Pure: drained bus payloads in, view model out. Hide deadlines are data
/// (`hideAt`); the renderer schedules a `tick` and a stale tick is harmless
/// because it only hides past an unexpired deadline. Port of `HudStateMachine`.
final class HudStateMachine {
    var maxChars: Int
    private(set) var vm = hiddenVM

    init(maxChars: Int = 120) { self.maxChars = maxChars }

    func apply(_ payloads: [UiEvent: HudPayload], now: Double) -> HudViewModel {
        var payloads = payloads
        // A drain carrying both a RESULT and the controller's trailing "idle"
        // STATE: the idle is redundant — RESULT's terminal state owns the hide.
        if payloads[.result] != nil, case let .state(name, _)? = payloads[.state], name == "idle" {
            payloads[.state] = nil
        }
        for event in applyOrder {
            if let payload = payloads[event] {
                one(payload, now: now)
            }
        }
        return vm
    }

    func tick(now: Double) -> HudViewModel {
        if let hideAt = vm.hideAt, now >= hideAt {
            vm = hiddenVM
        }
        return vm
    }

    private func one(_ payload: HudPayload, now: Double) {
        switch payload {
        case let .state(name, detail):
            if name == "recording" {
                vm = HudViewModel(state: "recording", status: detail.isEmpty ? "listening…" : detail)
            } else if (name == "transcribing" || name == "polishing") && vm.visible {
                vm.state = name
                vm.status = "finishing…"
                vm.placeholder = (detail == HudConst.coldStartMark)
                vm.hideAt = nil
            } else if name == "idle" && (vm.state == "recording" || vm.state == "transcribing" || vm.state == "polishing") {
                vm = hiddenVM
            }
            // idle while hidden/done/error: leave the flash (or nothing) alone
        case let .draft(text):
            if vm.state == "recording" { vm.draft = truncateHead(text, maxChars) }
        case let .level(value):
            if vm.state == "recording" { vm.level = value }
        case let .endpointProgress(value):
            if vm.state == "recording" { vm.endpointFraction = value }
        case let .result(status, text):
            // Errors flash from ANY state — a press that can't start (model
            // still downloading, mic dead) must say so; everything else keeps
            // the old gate (a stale ok/cancelled must not flash from hidden).
            guard vm.visible || status == "error" else { return }
            switch status {
            case "ok":
                vm = HudViewModel(state: "done", final: truncateHead(text, maxChars),
                                  hideAt: now + HudConst.doneFlashS)
            case "error":
                vm = HudViewModel(state: "error", status: "⚠️ \(text)",
                                  hideAt: now + HudConst.errorFlashS)
            case "cancelled":
                vm = HudViewModel(state: "cancelled", status: "cancelled",
                                  hideAt: now + HudConst.cancelFlashS)
            default:   // empty utterance — nothing to show
                vm = hiddenVM
            }
        }
    }
}
