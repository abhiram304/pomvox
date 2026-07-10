import Foundation

/// Turns a Sparkle update failure into a short, human message + an optional
/// "download manually" affordance — the design's "all failures render as inline
/// UI, never a popup". Kept pure (takes an error's domain/code/description, not
/// a live `NSError`) so the mapping is unit-tested without Sparkle.
enum UpdaterErrorClassifier {

    struct Result: Equatable {
        let message: String
        /// True when we should offer a link to the releases page (verification /
        /// download failures the user can work around by installing manually).
        let offerManualDownload: Bool
    }

    static func classify(domain: String, code: Int, localizedDescription: String) -> Result {
        let text = localizedDescription.lowercased()

        // App is running translocated / not in /Applications — Sparkle can't
        // update in place. Guidance, no manual-download link (moving fixes it).
        if text.contains("translocat")
            || (text.contains("move") && text.contains("applications")) {
            return Result(
                message: "Move Pomvox to your Applications folder to enable updates.",
                offerManualDownload: false)
        }

        // Signature / code-sign / verification failures — refuse and point to a
        // manual download from the releases page.
        if text.contains("verif") || text.contains("signature")
            || text.contains("code sign") || text.contains("codesign") {
            return Result(
                message: "This update couldn't be verified.",
                offerManualDownload: true)
        }

        // Network / reachability — a manual "Check Now" retry, no manual link.
        if text.contains("offline") || text.contains("internet")
            || text.contains("network") || text.contains("connection")
            || text.contains("could not connect") || text.contains("reach") {
            return Result(
                message: "Couldn't reach the update server — check your connection.",
                offerManualDownload: false)
        }

        // Fallback: show Sparkle's own description, offer a manual download.
        let fallback = localizedDescription.isEmpty
            ? "The update couldn't be completed." : localizedDescription
        return Result(message: fallback, offerManualDownload: true)
    }
}
