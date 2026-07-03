import Foundation

/// Cross-thread UI event spine — coalesce on any thread, render on the main one.
/// Port of `src/pomvox/uibus.py` (`Coalescer` + `MainThreadBus`): producers (the
/// audio callback, the draft loop, the hotkey path) call `post`, which is a
/// dict assignment plus, at most, one main-thread wake-up per burst. They never
/// block and never touch AppKit/SwiftUI. The main thread drains and renders.

/// Latest-wins mailbox per event type, with a dirty flag. `post` returns true
/// only when a main-thread wake-up must be scheduled, so a burst of N posts
/// costs exactly one dispatch. Port of `uibus.Coalescer`.
final class HudCoalescer {
    private let lock = NSLock()
    private var pending: [UiEvent: HudPayload] = [:]
    private var dirty = false

    func post(_ payload: HudPayload) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending[payload.event] = payload
        let wasDirty = dirty
        dirty = true
        return !wasDirty
    }

    func drain() -> [UiEvent: HudPayload] {
        lock.lock(); defer { lock.unlock() }
        let out = pending
        pending = [:]
        dirty = false
        return out
    }
}

/// Fire-and-forget bridge from worker threads to a main-thread renderer. `render`
/// receives the drained `[UiEvent: HudPayload]` dict on the main thread. Port of
/// `uibus.MainThreadBus` (minus the die-on-exception path — the Swift renderer is
/// non-throwing and the HUD is best-effort; a render failure never reaches the
/// dictation path because posting is decoupled from rendering).
final class HudBus {
    private let coalescer = HudCoalescer()
    private let render: ([UiEvent: HudPayload]) -> Void
    private let schedule: (@escaping () -> Void) -> Void

    /// `schedule` runs its closure on the main thread (default: `DispatchQueue.main.async`);
    /// injectable for tests.
    init(render: @escaping ([UiEvent: HudPayload]) -> Void,
         schedule: @escaping (@escaping () -> Void) -> Void = { fn in DispatchQueue.main.async(execute: fn) }) {
        self.render = render
        self.schedule = schedule
    }

    func post(_ payload: HudPayload) {
        if coalescer.post(payload) {
            schedule { [weak self] in
                guard let self else { return }
                self.render(self.coalescer.drain())
            }
        }
    }
}
