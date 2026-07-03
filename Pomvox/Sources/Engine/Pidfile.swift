import Foundation

/// Pidfile mutual exclusion — one event tap / mic at a time across the native
/// and Python engines. Mirror of `src/pomvox/pidfile.py`; the file format is the
/// cross-engine contract: line 1 = pid, line 2 = owner name ("native" |
/// "python"). The native engine acquires before arming and refuses if a live
/// Python engine already holds it.
struct Pidfile {
    struct Owner: Equatable {
        let pid: Int32
        let name: String
    }

    let url: URL

    static let defaultURL = URL(fileURLWithPath:
        NSString(string: "~/.pomvox/engine.pid").expandingTildeInPath)

    init(url: URL = Pidfile.defaultURL) { self.url = url }

    static func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM  // exists, owned by another user
    }

    func read() -> Owner? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first,
              let pid = Int32(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        let name = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespaces) : ""
        return Owner(pid: pid, name: name)
    }

    /// The live owner, or nil (no file / stale dead pid).
    func currentHolder() -> Owner? {
        guard let owner = read(), Self.pidAlive(owner.pid) else { return nil }
        return owner
    }

    /// Claim for `name`. Returns nil on success, or the live foreign holder that
    /// blocked the claim (the caller then refuses to arm). A live *other* pid
    /// blocks; our own pid or a stale dead pid is overwritten. Atomic write.
    @discardableResult
    func acquire(_ name: String,
                 pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> Owner? {
        if let holder = currentHolder(), holder.pid != pid { return holder }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(pid)\n\(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return nil
    }

    /// Remove the pidfile if this pid still owns it (no-op otherwise).
    func release(pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard let owner = read(), owner.pid == pid else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
