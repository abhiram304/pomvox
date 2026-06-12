import AppKit
import Foundation

/// The text-insertion recipe shared by the native engine (fresh dictation) and
/// History re-insert: stage the text on the pasteboard marked concealed,
/// synthesize ⌘V, then restore the prior clipboard. Faithful port of
/// `src/murmur/insert.py` (KEYCODE_V=9, concealed type, changeCount-guarded
/// restore). The synthesized ⌘V needs Accessibility.
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

    /// Paste `text` at the cursor via a synthesized ⌘V, then restore the
    /// previous clipboard — but only if a real user copy hasn't landed in the
    /// meantime (changeCount still ours).
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let ourChange = stage(pb, text)

        // Flags set explicitly to ⌘ alone so a still-held Fn (the PTT release
        // races the paste) can't contaminate the synthetic chord.
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            if let saved, pb.changeCount == ourChange {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }
}
