import Foundation

/// The one state the whole update UI renders from. `UpdaterModel` reduces
/// Sparkle user-driver callbacks into these events; the reducer is pure so
/// the machine is unit-testable with no Sparkle and no network.
enum UpdaterState: Equatable {
    case idle
    case checking
    case updateAvailable(version: String, releaseNotesURL: URL?)
    case downloading(fraction: Double?)   // nil until a content length is known
    case extracting(fraction: Double?)
    case readyToRelaunch
    case installing
    case upToDate
    case error(message: String)
}

enum UpdaterEvent: Equatable {
    case checkStarted
    case updateFound(version: String, releaseNotesURL: URL?)
    case noUpdateFound
    case downloadStarted
    case downloadProgressed(fraction: Double?)
    case extractionStarted
    case extractionProgressed(fraction: Double)
    case readyToInstall
    case installStarted
    case dismissed
    case failed(message: String)
}

extension UpdaterState {
    /// Sparkle sequences its callbacks; each event fully determines the next
    /// state, so this is a mapping rather than a guard table.
    static func reduce(_ state: UpdaterState, _ event: UpdaterEvent) -> UpdaterState {
        switch event {
        case .checkStarted:                return .checking
        case let .updateFound(v, url):     return .updateAvailable(version: v, releaseNotesURL: url)
        case .noUpdateFound:               return .upToDate
        case .downloadStarted:             return .downloading(fraction: nil)
        case let .downloadProgressed(f):   return .downloading(fraction: f)
        case .extractionStarted:           return .extracting(fraction: nil)
        case let .extractionProgressed(f): return .extracting(fraction: f)
        case .readyToInstall:              return .readyToRelaunch
        case .installStarted:              return .installing
        case .dismissed:                   return .idle
        case let .failed(m):               return .error(message: m)
        }
    }

    /// The Home banner shows for everything between "found" and relaunch —
    /// and for nothing else (checking and up-to-date stay quiet on Home).
    var showsBanner: Bool {
        switch self {
        case .updateAvailable, .downloading, .extracting, .readyToRelaunch, .installing:
            return true
        case .idle, .checking, .upToDate, .error:
            return false
        }
    }
}
