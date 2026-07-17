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
/// `src/pomvox/insert.py` (KEYCODE_V=9, concealed type, changeCount-guarded
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
///
/// Fidelity beyond the Python port: the restore snapshots every item and
/// flavor (`ClipboardSnapshot`), not just the plain string — `insert.py`'s
/// string-only save meant a copied image or file vanished after a dictation
/// and rich text came back stripped to plain.
enum Paster {
    static let keyV: CGKeyCode = 9
    /// nspasteboard.org convention: clipboard managers (Maccy, Paste, Alfred…)
    /// that honor it skip items carrying this type, so dictations don't pile up
    /// in clipboard history.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// How long to leave the staged transcript on the clipboard before restoring
    /// the user's prior contents. The synthesized ⌘V is asynchronous — the target
    /// app reads the clipboard only when it processes the keystroke on its own
    /// main thread — so this delay must comfortably outlast that handling. At the
    /// old 0.15 s a busy or slow-to-focus app (launching, Electron, system under
    /// load) could still be mid-paste when the restore fired, so it read the
    /// *restored* prior clipboard and pasted the previously-copied text instead of
    /// the transcript. It's off the critical key-up→paste path (the paste is
    /// already posted), and the changeCount guard still lets a real user copy win,
    /// so a longer wait is safe and only widens the recovery window.
    static let restoreDelay: TimeInterval = 0.5

    /// Stage `text` on `pb` marked concealed; return the resulting changeCount.
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
        let saved = snapshot(pb)
        let ourChange = stage(pb, text)
        synthesizePaste()
        guard focusedAcceptsText else {
            // No editable field — keep the (concealed) transcript on the clipboard
            // so it's recoverable rather than silently lost.
            return .copiedToClipboard
        }
        scheduleRestore {
            if !saved.isEmpty, pb.changeCount == ourChange {
                restore(saved, to: pb)
            }
        }
        return .pasted
    }

    /// One clipboard item's full contents, keyed by flavor. A dictation must
    /// give back *whatever* was on the clipboard — an image, files, rich text —
    /// not just a plain string: saving only `string(forType: .string)` meant a
    /// copied screenshot was permanently replaced by the transcript, and a
    /// rich-text copy silently degraded to plain text.
    typealias ClipboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    /// Capture every item and flavor currently on `pb`. Reading resolves any
    /// lazily-promised flavors into memory — that's the point (the promising
    /// app may be gone by restore time) and clipboard items are small compared
    /// to the models this process already holds.
    static func snapshot(_ pb: NSPasteboard) -> ClipboardSnapshot {
        (pb.pasteboardItems ?? []).map { item in
            var flavors: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { flavors[type] = data }
            }
            return flavors
        }
        .filter { !$0.isEmpty }
    }

    /// Write a snapshot back. The restore path deliberately does not re-mark
    /// the user's original clipboard as concealed — it wasn't ours to conceal.
    static func restore(_ saved: ClipboardSnapshot, to pb: NSPasteboard) {
        pb.clearContents()
        pb.writeObjects(saved.map { flavors in
            let item = NSPasteboardItem()
            for (type, data) in flavors { item.setData(data, forType: type) }
            return item
        })
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
