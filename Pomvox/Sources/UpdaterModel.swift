import Foundation
import os
import Sparkle

/// Our own copy of Sparkle's user choice so tests and UI never import Sparkle.
enum UpdateChoice: Equatable { case install, dismiss, skip }

/// Headless Sparkle: owns the SPUUpdater, maps every SPUUserDriver callback
/// onto the pure UpdaterState reducer, and exposes the user actions the Home
/// banner and Settings render. Sparkle never shows a window of its own.
final class UpdaterModel: NSObject, ObservableObject {
    static let shared = UpdaterModel()

    @Published private(set) var state: UpdaterState = .idle
    @Published private(set) var lastCheckDate: Date?

    /// Wired to the engine at app startup (Task 4); tests inject their own.
    var isDictationBusy: () -> Bool = { false }
    /// Poll cadence while waiting out an in-flight dictation before relaunch.
    var relaunchPollInterval: TimeInterval = 0.5

    private let log = Logger(subsystem: "app.pomvox.hub", category: "updater")
    private var updater: SPUUpdater?
    private var updateReply: ((UpdateChoice) -> Void)?
    private var userInitiatedCheck = false
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    /// Release builds: always on. Debug builds: only with POMVOX_UPDATE_FEED
    /// set (state-machine debugging) — otherwise fully inert: no scheduled
    /// checks, no UI surfaces, `start()` is a no-op.
    static var isEnabled: Bool {
        #if DEBUG
        return feedOverride() != nil
        #else
        return true
        #endif
    }

    static func feedOverride(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        env["POMVOX_UPDATE_FEED"]
    }

    /// Maps straight onto Sparkle's persisted setting (SUEnableAutomaticChecks
    /// in defaults). Defaults to true before start() — the Info.plist default.
    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? true }
        set {
            objectWillChange.send()
            updater?.automaticallyChecksForUpdates = newValue
        }
    }

    func start() {
        guard Self.isEnabled, updater == nil else { return }
        let u = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                           userDriver: self, delegate: self)
        // Hardening (Sparkle-documented): a feed URL persisted into defaults
        // must never override the Info.plist feed in production.
        u.clearFeedURLFromUserDefaults()
        do {
            try u.start()
        } catch {
            apply(.failed(message: error.localizedDescription))
            return
        }
        updater = u
        lastCheckDate = u.lastUpdateCheckDate
    }

    func checkNow() {
        userInitiatedCheck = true
        updater?.checkForUpdates()
    }

    // MARK: - user actions (Home banner / Settings)

    func install() { respond(.install) }
    func later()   { respond(.dismiss); apply(.dismissed) }
    func skip()    { respond(.skip);    apply(.dismissed) }

    private func respond(_ choice: UpdateChoice) {
        updateReply?(choice)
        updateReply = nil
    }

    // MARK: - reducer seams (internal: tests drive these without Sparkle)

    func apply(_ event: UpdaterEvent) {
        state = UpdaterState.reduce(state, event)
    }

    func handleUpdateFound(version: String, notesURL: URL?,
                           reply: @escaping (UpdateChoice) -> Void) {
        updateReply = reply
        apply(.updateFound(version: version, releaseNotesURL: notesURL))
    }

    /// Sparkle is ready to swap bundles and relaunch. The user already clicked
    /// Update — the only thing worth waiting for is an in-flight dictation.
    func handleReadyToRelaunch(reply: @escaping (UpdateChoice) -> Void) {
        apply(.readyToInstall)
        guard isDictationBusy() else {
            apply(.installStarted)
            reply(.install)
            return
        }
        Timer.scheduledTimer(withTimeInterval: relaunchPollInterval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if !self.isDictationBusy() {
                timer.invalidate()
                self.apply(.installStarted)
                reply(.install)
            }
        }
    }

    func noteCheckCompleted(date: Date = Date()) {
        lastCheckDate = date
    }

    /// End of a Sparkle update cycle (delegate seam; tests drive it directly).
    /// Resets the manual-check flag: a cycle that ends via update-found →
    /// Later never hits the error/not-found callbacks, and a sticky flag
    /// would misclassify the NEXT scheduled failure as user-initiated.
    func noteUpdateCycleFinished(date: Date = Date()) {
        noteCheckCompleted(date: date)
        userInitiatedCheck = false
    }

    static func lastCheckedLabel(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Never checked" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last checked \(f.localizedString(for: date, relativeTo: now))"
    }

    /// Spec error contract: plain-language copy, never Sparkle jargon.
    static func friendlyMessage(for error: NSError) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if lower.contains("transloc") || lower.contains("quarantine") {
            return "Move Pomvox to the Applications folder to enable updates."
        }
        if lower.contains("signature") || lower.contains("validat") || lower.contains("verif") {
            return "The update couldn't be verified. Download it manually from the releases page."
        }
        return raw
    }
}

// MARK: - Sparkle user driver (thin forwarding; no logic beyond mapping)
//
// NOTE: verify these method signatures against the pinned Sparkle version —
// if the compiler reports missing/renamed requirements, use Xcode's
// "add protocol stubs" fix-it and keep each body a one-line forward onto the
// seams above. The logic lives (tested) in the seams, not here.

extension UpdaterModel: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Never show Sparkle's permission prompt: checks are on by default,
        // no system profile — disclosed in Settings and README instead.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiatedCheck = true
        apply(.checkStarted)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        handleUpdateFound(version: appcastItem.displayVersionString,
                          notesURL: appcastItem.releaseNotesURL ?? appcastItem.infoURL) { choice in
            switch choice {
            case .install: reply(.install)
            case .dismiss: reply(.dismiss)
            case .skip:    reply(.skip)
            }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}          // we link out
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}     // to GitHub

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        apply(.noUpdateFound)
        noteCheckCompleted()
        userInitiatedCheck = false
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        // Spec error contract: a failed SCHEDULED check stays silent (log +
        // retry next interval); a failed manual check or in-flight install
        // renders inline. Never a popup either way.
        if userInitiatedCheck || state.showsBanner {
            apply(.failed(message: Self.friendlyMessage(for: error as NSError)))
        } else {
            log.error("scheduled update check failed: \(error.localizedDescription, privacy: .public)")
            apply(.dismissed)
        }
        userInitiatedCheck = false
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        apply(.downloadStarted)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        let fraction = expectedLength > 0
            ? min(Double(receivedLength) / Double(expectedLength), 1.0) : nil
        apply(.downloadProgressed(fraction: fraction))
    }

    func showDownloadDidStartExtractingUpdate() {
        apply(.extractionStarted)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        apply(.extractionProgressed(fraction: progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        handleReadyToRelaunch { choice in
            reply(choice == .install ? .install : .dismiss)
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        apply(.installStarted)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        // End of a Sparkle session. Keep an unactioned banner and any error
        // visible; clear only transient states (checking / upToDate).
        switch state {
        case .checking, .upToDate: apply(.dismissed)
        default: break
        }
    }
}

// MARK: - Sparkle updater delegate

extension UpdaterModel: SPUUpdaterDelegate {
    /// Test/rig override: POMVOX_UPDATE_FEED wins; nil falls back to the
    /// Info.plist SUFeedURL (production path).
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feedOverride()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        DispatchQueue.main.async { self.noteUpdateCycleFinished() }
    }
}
