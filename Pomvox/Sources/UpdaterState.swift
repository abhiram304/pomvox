import Foundation

/// The in-app updater's UI state, distilled from Sparkle's `SPUUserDriver`
/// callbacks into one enum the Home banner and Settings pane render. Sparkle
/// types never appear here — the driver (`Updater.swift`) translates its
/// callbacks into `UpdaterEvent`s and folds them through this pure reducer, so
/// the whole state machine is unit-testable without Sparkle or a network.
enum UpdaterState: Equatable {
    case idle
    case checking
    case updateAvailable(version: String, releaseNotesURL: URL?)
    case downloading(receivedBytes: UInt64, expectedBytes: UInt64?)
    case extracting(progress: Double)
    case readyToRelaunch
    case installing
    case upToDate
    case error(message: String)
}

/// A content-free, Sparkle-free description of what the updater just reported.
/// The driver builds these from Sparkle callbacks; the reducer consumes them.
enum UpdaterEvent: Equatable {
    case checkStarted
    case updateFound(version: String, releaseNotesURL: URL?)
    case notFound
    case downloadStarted
    case downloadExpectedLength(UInt64)
    case downloadReceived(UInt64)
    case extractionStarted
    case extractionProgress(Double)
    case readyToRelaunch
    case installing
    case failed(message: String)
    case dismissed
}

extension UpdaterState {
    /// Fold one event into the next state. Download byte totals accumulate here
    /// (Sparkle reports lengths incrementally), which is exactly why this is a
    /// reducer over prior state rather than a plain mapping.
    func applying(_ event: UpdaterEvent) -> UpdaterState {
        switch event {
        case .checkStarted:
            return .checking
        case let .updateFound(version, url):
            return .updateAvailable(version: version, releaseNotesURL: url)
        case .notFound:
            return .upToDate
        case .downloadStarted:
            return .downloading(receivedBytes: 0, expectedBytes: nil)
        case let .downloadExpectedLength(length):
            if case let .downloading(received, _) = self {
                return .downloading(receivedBytes: received, expectedBytes: length)
            }
            return .downloading(receivedBytes: 0, expectedBytes: length)
        case let .downloadReceived(length):
            if case let .downloading(received, expected) = self {
                return .downloading(receivedBytes: received + length, expectedBytes: expected)
            }
            return .downloading(receivedBytes: length, expectedBytes: nil)
        case .extractionStarted:
            return .extracting(progress: 0)
        case let .extractionProgress(progress):
            return .extracting(progress: progress)
        case .readyToRelaunch:
            return .readyToRelaunch
        case .installing:
            return .installing
        case let .failed(message):
            return .error(message: message)
        case .dismissed:
            return .idle
        }
    }

    /// The Home banner is visible from "update available" through installing —
    /// the whole one-click download→relaunch arc.
    var bannerVisible: Bool {
        switch self {
        case .updateAvailable, .downloading, .extracting, .readyToRelaunch, .installing:
            return true
        case .idle, .checking, .upToDate, .error:
            return false
        }
    }

    /// True while an update check or download/install is actively in flight —
    /// used to disable "Check Now" so a user can't stack checks.
    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .extracting, .readyToRelaunch, .installing:
            return true
        case .idle, .updateAvailable, .upToDate, .error:
            return false
        }
    }

    /// Download progress in 0…1 when the expected length is known, else nil
    /// (indeterminate).
    var downloadFraction: Double? {
        guard case let .downloading(received, expected) = self,
              let expected, expected > 0 else { return nil }
        return min(1.0, Double(received) / Double(expected))
    }

    var availableVersion: String? {
        if case let .updateAvailable(version, _) = self { return version }
        return nil
    }

    var releaseNotesURL: URL? {
        if case let .updateAvailable(_, url) = self { return url }
        return nil
    }

    /// A short status line for the banner / Settings feedback row.
    var statusLine: String {
        switch self {
        case .idle: return ""
        case .checking: return "Checking for updates…"
        case let .updateAvailable(version, _): return "Update available — v\(version)"
        case .downloading:
            if let f = downloadFraction { return "Downloading… \(Int(f * 100))%" }
            return "Downloading…"
        case .extracting: return "Preparing update…"
        case .readyToRelaunch: return "Ready to install…"
        case .installing: return "Installing and relaunching…"
        case .upToDate: return "You're up to date."
        case let .error(message): return message
        }
    }
}
