import SwiftUI
import AppKit
import ApplicationServices

/// Re-inserting a past dictation means pasting into whatever app you were just
/// using — pasteboard + a synthesized ⌘V. That keystroke needs Accessibility,
/// and the ad-hoc-signed Hub usually doesn't have it (TCC grants live with the
/// Python engine until M7). So we check the grant and degrade honestly rather
/// than firing a paste that silently lands nowhere.
enum ReinsertMode: Equatable {
    case paste     // Accessibility granted — real countdown + synthesized ⌘V
    case copyOnly  // not granted — copy to clipboard, you paste it yourself

    static func decide(trusted: Bool) -> ReinsertMode { trusted ? .paste : .copyOnly }
}

@MainActor
final class ReinsertController: ObservableObject {
    /// What the History overlay is currently showing.
    enum Phase: Equatable {
        case idle
        case countdown(Int)   // seconds left before the synthesized paste
        case copied           // copy-only fallback: prompt the user to paste
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?

    // Community convention (nspasteboard.org): clipboard managers that honor it
    // skip items carrying this type, so re-inserted transcripts don't pile up in
    // clipboard history. Mirrors src/murmur/insert.py.
    private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let keyV: CGKeyCode = 9

    /// Re-insert `text`. Picks the real-paste or copy-only path by the live grant.
    func start(text: String) {
        switch ReinsertMode.decide(trusted: AXIsProcessTrusted()) {
        case .paste:    beginCountdown(text: text)
        case .copyOnly: copyOnly(text: text)
        }
    }

    /// Cancel an in-flight countdown / dismiss the fallback banner.
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func openAccessibilitySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - paste path (granted)

    /// 3-2-1 so focus can leave the Hub and land in your target field — then the
    /// ⌘V posts to whatever is frontmost. Port of app.py:_reinsert + insert.py.
    private func beginCountdown(text: String) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: 3, through: 1, by: -1) {
                self.phase = .countdown(remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { self.phase = .idle; return }
            }
            self.paste(text: text)
            self.phase = .idle
        }
    }

    private func paste(text: String) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let ourChange = stage(pb, text)

        // Flags set explicitly to ⌘ alone so a still-held modifier can't
        // contaminate the synthetic chord.
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        // Restore the prior clipboard, but only if a real user copy hasn't landed
        // in the meantime (changeCount still ours).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let saved, pb.changeCount == ourChange {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }

    @discardableResult
    private func stage(_ pb: NSPasteboard, _ text: String) -> Int {
        pb.declareTypes([.string, concealed], owner: nil)
        pb.setString(text, forType: .string)
        pb.setString("1", forType: concealed)
        return pb.changeCount
    }

    // MARK: - copy-only path (not granted)

    private func copyOnly(text: String) {
        _ = stage(NSPasteboard.general, text)   // concealed, like a real paste would be
        task?.cancel()
        phase = .copied
        // Auto-dismiss the prompt; the clipboard keeps the text either way.
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled, case .copied = self?.phase { self?.phase = .idle }
        }
    }
}
