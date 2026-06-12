import AppKit
import ApplicationServices
import Foundation

/// What `paste` did with the transcript.
enum PasteOutcome: Equatable {
    case pasted             // an editable field had focus; ⌘V delivered it there
    case copiedToClipboard  // no editable field focused — left on the clipboard for recovery
}

/// The text-insertion recipe shared by the native engine (fresh dictation) and
/// History re-insert: stage the text on the pasteboard marked concealed,
/// synthesize ⌘V, then restore the prior clipboard. Faithful port of
/// `src/murmur/insert.py` (KEYCODE_V=9, concealed type, changeCount-guarded
/// restore). The synthesized ⌘V needs Accessibility.
///
/// Recovery beyond the Python port: `insert.py` always restores the clipboard,
/// so a dictation with no focused text field is silently lost (the Python app
/// recovers via a "copy last transcript" menu item). The native engine has no
/// menu bar, so instead — when no editable field is focused — it leaves the
/// transcript on the clipboard and reports `.copiedToClipboard` (the HUD shows a
/// "copied to clipboard" flash). The ⌘V is *always* synthesized regardless, so
/// the focus probe can never break the normal paste in apps where AX focus
/// reporting is unreliable.
enum Paster {
    static let keyV: CGKeyCode = 9
    /// nspasteboard.org convention: clipboard managers (Maccy, Paste, Alfred…)
    /// that honor it skip items carrying this type, so dictations don't pile up
    /// in clipboard history.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let restoreDelay: TimeInterval = 0.15

    /// Stage `text` on `pb` marked concealed; return the resulting changeCount.
    /// The restore path deliberately does not re-mark the user's original
    /// clipboard — it wasn't ours to conceal.
    @discardableResult
    static func stage(_ pb: NSPasteboard, _ text: String) -> Int {
        pb.declareTypes([.string, concealedType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setString("1", forType: concealedType)
        return pb.changeCount
    }

    /// Paste `text` at the cursor via a synthesized ⌘V. If an editable field is
    /// focused the previous clipboard is restored after a short delay (unless a
    /// real user copy lands first); otherwise the transcript is left on the
    /// clipboard so it isn't lost. Returns what happened.
    @discardableResult
    static func paste(_ text: String) -> PasteOutcome {
        deliver(text, to: .general, focusedAcceptsText: focusedElementAcceptsText(),
                synthesizePaste: { synthesizeCommandV() },
                scheduleRestore: { body in
                    DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: body)
                })
    }

    /// Testable core: stages the text, runs the (injected) ⌘V, and decides the
    /// clipboard outcome. `scheduleRestore` is invoked only when restoring is
    /// wanted; the restore body is changeCount-guarded so a real user copy wins.
    @discardableResult
    static func deliver(_ text: String, to pb: NSPasteboard, focusedAcceptsText: Bool,
                        synthesizePaste: () -> Void,
                        scheduleRestore: (@escaping () -> Void) -> Void) -> PasteOutcome {
        let saved = pb.string(forType: .string)
        let ourChange = stage(pb, text)
        synthesizePaste()
        guard focusedAcceptsText else {
            // No editable field — keep the (concealed) transcript on the clipboard
            // so it's recoverable rather than silently lost.
            return .copiedToClipboard
        }
        scheduleRestore {
            if let saved, pb.changeCount == ourChange {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
        return .pasted
    }

    /// Synthesize ⌘V. Flags set explicitly to ⌘ alone so a still-held Fn (the PTT
    /// release races the paste) can't contaminate the synthetic chord.
    private static func synthesizeCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Best-effort AX probe: does the system-wide focused element accept text
    /// (settable AXValue, or a text-field/area role)? Needs Accessibility; if the
    /// query fails (untrusted, or an app that doesn't report focus) it returns
    /// false and the caller falls back to leaving the text on the clipboard.
    static func focusedElementAcceptsText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        let element = focused as! AXUIElement

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        var role: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String,
           role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) {
            return true
        }
        return false
    }
}
