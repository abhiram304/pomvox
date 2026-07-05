import CoreGraphics
import Foundation

enum EventTapError: Error {
    /// The tap could not be created — Input Monitoring isn't granted.
    case notPermitted
}

/// Active CGEventTap feeding flagsChanged/keyDown decisions, on a dedicated
/// thread with its own CFRunLoop so it never blocks the SwiftUI run loop. Port
/// of `hotkey.py:EventTap`. The decision closures are called synchronously on
/// the tap thread and must stay fast; the owner (`NativeEngine`) serializes the
/// HotkeyMachine behind them and returns the `Decision` (so swallowed keys are
/// honored). flagsChanged always passes through; keys are swallowed only when
/// the decision says so.
final class EventTap {
    typealias ModifierDecision = (_ keycode: Int, _ isDown: Bool) -> HotkeyMachine.Decision
    typealias KeyDecision = (_ keycode: Int) -> HotkeyMachine.Decision

    private let onModifier: ModifierDecision
    private let onKeyDown: KeyDecision

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    // flagsChanged carries the keycode of the modifier that changed; the
    // matching mask bit tells us whether it went down or up (mirrors hotkey.py).
    private static let modifierMasks: [Int64: CGEventFlags] = [
        63: .maskSecondaryFn,
        58: .maskAlternate, 61: .maskAlternate,
        55: .maskCommand, 54: .maskCommand,
        56: .maskShift, 60: .maskShift,
        59: .maskControl, 62: .maskControl,
    ]

    init(onModifier: @escaping ModifierDecision, onKeyDown: @escaping KeyDecision) {
        self.onModifier = onModifier
        self.onKeyDown = onKeyDown
    }

    /// Create the tap (throws if Input Monitoring isn't granted) and run its
    /// run loop on a dedicated background thread.
    func start() throws {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let me = Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw EventTapError.notPermitted
        }
        self.tap = tap

        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self.source = source
            self.threadRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "app.pomvox.eventtap"
        self.thread = thread
        thread.start()
    }

    /// Force the tap back on. The system disables a session tap across sleep and
    /// the automatic re-enable (via the `.tapDisabledByTimeout` event in
    /// `handle`) isn't reliably delivered on wake, so the owner re-enables it
    /// explicitly from the wake notification. Safe to call if already enabled.
    func reEnable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let rl = threadRunLoop {
            if let source { CFRunLoopRemoveSource(rl, source, .commonModes) }
            CFRunLoopStop(rl)
        }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil; threadRunLoop = nil; thread = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/contended tap; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let decision: HotkeyMachine.Decision
        switch type {
        case .flagsChanged:
            guard let mask = Self.modifierMasks[keycode] else {
                return Unmanaged.passUnretained(event)
            }
            decision = onModifier(Int(keycode), event.flags.contains(mask))
        case .keyDown:
            decision = onKeyDown(Int(keycode))
        default:
            return Unmanaged.passUnretained(event)
        }
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }
}
