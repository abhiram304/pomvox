import Foundation
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

/// In-app updates (design: 2026-07-09-in-app-updates-design). Owns a headless
/// Sparkle `SPUUpdater` driven by a custom `SPUUserDriver` so the UI is native
/// Pomvox (Home banner + Settings), never the stock Sparkle dialog. Auto-checks
/// in the background (launch + every 24 h); installs only when the user clicks
/// Update. Sparkle types stay inside this file — the rest of the app sees only
/// the pure `UpdaterState`.
@MainActor
final class UpdaterModel: ObservableObject {
    /// Shared instance so the AppDelegate can `start()` it at launch (even a
    /// windowless login-item launch) while the Hub UI observes the same object.
    static let shared = UpdaterModel()

    /// The appcast committed on `main` (Maccy/AltTab pattern).
    static let productionFeedURL = "https://raw.githubusercontent.com/abhiram304/pomvox/main/appcast.xml"
    /// Where "download manually" / release-notes links point.
    static let releasesPageURL = URL(string: "https://github.com/abhiram304/pomvox/releases")!
    private static let firstRunConfiguredKey = "updater.firstRunConfigured"

    @Published private(set) var state: UpdaterState = .idle
    @Published private(set) var automaticChecks: Bool = true

    /// The running app's version, for the Settings "current version" row.
    let currentVersion: String
    /// Whether the updater is active. Debug builds are self-signed and fail
    /// Sparkle's code-sign validation, so updates are off there unless a test
    /// feed override is set for state-machine debugging.
    let isEnabled: Bool

    private let feedOverride: String?

    #if canImport(Sparkle)
    private var updater: SPUUpdater?
    private let driver = PomvoxUserDriver()
    private let feedDelegate: UpdaterFeedDelegate
    #endif

    init(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        currentVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let override = environment["POMVOX_UPDATE_FEED"].flatMap { $0.isEmpty ? nil : $0 }
        feedOverride = override
        #if canImport(Sparkle)
        feedDelegate = UpdaterFeedDelegate(feed: override ?? Self.productionFeedURL)
        #if DEBUG
        isEnabled = override != nil   // self-signed Debug can't verify updates
        #else
        isEnabled = true
        #endif
        #else
        isEnabled = false
        #endif
    }

    /// Create + start the updater. Call once at app launch. No-op when disabled.
    func start() {
        guard isEnabled else { return }
        #if canImport(Sparkle)
        driver.onEvent = { [weak self] event in self?.apply(event) }
        driver.onReadyToRelaunch = { [weak self] in self?.installWhenDictationIdle() }

        let updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main,
            userDriver: driver, delegate: feedDelegate)
        // Hardening: drop any stale `setFeedURL:` override in user defaults so a
        // past test feed can never hijack real updates (Sparkle-documented).
        if feedOverride == nil { _ = updater.clearFeedURLFromUserDefaults() }
        do {
            try updater.startUpdater()
        } catch {
            NSLog("updater: failed to start — %@", String(describing: error))
            return
        }
        // First run: enable auto-checks once so Sparkle's own permission prompt
        // never appears (disclosed in Settings + README). Later launches honor
        // the user's toggle instead of overriding it.
        if !UserDefaults.standard.bool(forKey: Self.firstRunConfiguredKey) {
            updater.automaticallyChecksForUpdates = true
            updater.updateCheckInterval = 86_400
            UserDefaults.standard.set(true, forKey: Self.firstRunConfiguredKey)
        }
        automaticChecks = updater.automaticallyChecksForUpdates
        self.updater = updater
        #endif
    }

    /// User-initiated "Check Now".
    func checkNow() {
        #if canImport(Sparkle)
        state = .checking
        updater?.checkForUpdates()
        #endif
    }

    /// User clicked "Update" — begin the download→install→relaunch arc.
    func update() {
        #if canImport(Sparkle)
        driver.chooseInstall()
        #endif
    }

    /// "Later" — dismiss for now; the next scheduled check re-surfaces it.
    func remindLater() {
        #if canImport(Sparkle)
        driver.chooseDismiss()
        #endif
        state = .idle
    }

    /// "Skip this version" — Sparkle won't offer it again until a newer one.
    func skipThisVersion() {
        #if canImport(Sparkle)
        driver.chooseSkip()
        #endif
        state = .idle
    }

    func setAutomaticChecks(_ on: Bool) {
        automaticChecks = on
        #if canImport(Sparkle)
        updater?.automaticallyChecksForUpdates = on
        #endif
    }

    private func apply(_ event: UpdaterEvent) {
        state = state.applying(event)
    }

    /// Dictation safety: relaunch only once any in-flight recording/transcription
    /// has finished, so an update never cuts off words mid-utterance.
    private func installWhenDictationIdle() {
        #if canImport(Sparkle)
        Task { [weak self] in
            while true {
                let busy = NativeEngine.shared.status == .recording
                    || NativeEngine.shared.status == .transcribing
                if !busy { break }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            self?.driver.installNow()
        }
        #endif
    }
}

#if canImport(Sparkle)

/// Feeds Sparkle the appcast URL at runtime (preferred over the deprecated
/// `setFeedURL:`), so a test override via `POMVOX_UPDATE_FEED` works without
/// polluting user defaults. The feed is fixed at init, so this reads safely from
/// whatever context Sparkle calls the delegate on.
final class UpdaterFeedDelegate: NSObject, SPUUpdaterDelegate {
    private let feed: String
    init(feed: String) { self.feed = feed; super.init() }

    func feedURLString(for updater: SPUUpdater) -> String? { feed }
}

/// Maps Sparkle's `SPUUserDriver` callbacks onto pure `UpdaterEvent`s and stashes
/// the choice/relaunch replies so the native UI can drive them. No stock Sparkle
/// UI is ever shown. Method signatures mirror the Sparkle 2.9 protocol exactly.
@MainActor
final class PomvoxUserDriver: NSObject, SPUUserDriver {
    var onEvent: (UpdaterEvent) -> Void = { _ in }
    var onReadyToRelaunch: () -> Void = {}

    private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    private var installReply: ((SPUUserUpdateChoice) -> Void)?

    // MARK: user actions (called by UpdaterModel)

    func chooseInstall() { updateReply?(.install); updateReply = nil }
    func chooseDismiss() { updateReply?(.dismiss); updateReply = nil }
    func chooseSkip() { updateReply?(.skip); updateReply = nil }
    func installNow() { installReply?(.install); installReply = nil }

    // MARK: SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void
    ) {
        // We enable checks explicitly on first run, so this rarely fires; grant
        // update checks, never send a system profile.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        onEvent(.checkStarted)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) {
        updateReply = reply
        onEvent(.updateFound(
            version: appcastItem.displayVersionString,
            releaseNotesURL: appcastItem.releaseNotesURL))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        onEvent(.notFound)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        let ns = error as NSError
        let result = UpdaterErrorClassifier.classify(
            domain: ns.domain, code: ns.code, localizedDescription: ns.localizedDescription)
        onEvent(.failed(message: result.message))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        onEvent(.downloadStarted)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        onEvent(.downloadExpectedLength(expectedContentLength))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        onEvent(.downloadReceived(length))
    }

    func showDownloadDidStartExtractingUpdate() {
        onEvent(.extractionStarted)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        onEvent(.extractionProgress(progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        installReply = reply
        onEvent(.readyToRelaunch)
        onReadyToRelaunch()   // model waits for dictation to finish, then installs
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        onEvent(.installing)
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool, acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismissUpdateInstallation() {
        onEvent(.dismissed)
    }
}

#endif
