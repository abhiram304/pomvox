import Foundation

/// Verifies that the compiled CoreML STT graph actually persists across launches
/// (item 1). FluidAudio compiles the Parakeet model to a `.mlmodelc` bundle on
/// first load; that compile is the ~37 s cold-start cost, and it should happen
/// once and be reused thereafter. If the artifact is missing or its fingerprint
/// changes every launch, we are re-paying the compile — this surfaces that in
/// the log and in (anonymous, numeric) telemetry as a cache hit/miss.
///
/// FluidAudio owns where it writes the compiled bundle, so we probe a set of
/// known cache roots for a matching `.mlmodelc` rather than assume one path.
/// The pure pieces (candidate roots, the model→token match, the fingerprint
/// digest, and the hit/changed decision) are unit-tested; the disk scan and the
/// UserDefaults record are the thin shell.
enum CompiledModelCache {

    /// A compiled-artifact fingerprint: enough to tell "same bundle as last
    /// launch" from "recompiled" without hashing gigabytes. Path identifies the
    /// bundle, mtime moves when it's recompiled, bytes catch a rebuild in place.
    struct Fingerprint: Equatable, Sendable {
        let path: String
        let modifiedAt: Double   // epoch seconds
        let bytes: Int64

        /// A short, stable digest for logs — never contains a transcript or any
        /// user content, only the artifact's own metadata.
        var digest: String {
            let material = "\(path)|\(Int(modifiedAt))|\(bytes)"
            return String(format: "%016llx", UInt64(bitPattern: Int64(Self.fnv1a(material))))
        }

        /// FNV-1a over the material string — a tiny, dependency-free hash purely
        /// for a human-readable fingerprint in the log.
        static func fnv1a(_ s: String) -> Int64 {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in s.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            return Int64(bitPattern: hash)
        }
    }

    /// The outcome of a probe, folded into `ColdStartTimings`/telemetry and the
    /// engine log.
    struct Probe: Equatable, Sendable {
        /// The artifact on disk right now (nil = none found; a compile is due).
        let current: Fingerprint?
        /// The artifact recorded at the end of the previous launch, if any.
        let previous: Fingerprint?

        /// A compiled artifact existed on disk *before* this launch loaded it —
        /// i.e. the compile cache is present and should be reused.
        var hit: Bool { current != nil && previous != nil }

        /// The artifact differs from last launch — a recompile happened (or the
        /// bundle moved), which is exactly the "cache not persisting" signal.
        var changed: Bool {
            guard let current, let previous else { return false }
            return current != previous
        }

        func logLine(model: String) -> String {
            guard let current else {
                return "coreml cache: MISS for \(model) — no compiled .mlmodelc on disk (compile due)"
            }
            let state = previous == nil ? "first-seen"
                : (changed ? "CHANGED since last launch (recompiled?)" : "unchanged since last launch")
            let when = Date(timeIntervalSince1970: current.modifiedAt)
            return String(
                format: "coreml cache: HIT for %@ — %@ digest=%@ mtime=%@ size=%lldB path=%@",
                model, state, current.digest,
                ISO8601DateFormatter().string(from: when), current.bytes, current.path)
        }
    }

    // MARK: - Pure logic (unit-tested)

    /// Cache roots FluidAudio / CoreML may write the compiled bundle under. Order
    /// is search order; the first matching `.mlmodelc` (newest) wins.
    static func candidateRoots(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.cache/huggingface/hub",
            "\(home)/Library/Application Support/FluidAudio",
            "\(home)/Library/Caches/FluidAudio",
            "\(home)/Library/Application Support/com.fluidinference.FluidAudio",
        ]
    }

    /// The lowercased token a compiled bundle's path must contain to belong to
    /// this STT model — the version suffix, which FluidAudio keeps in the path.
    static func matchToken(for model: SttModel) -> String {
        switch model {
        case .parakeetV2: return "v2"
        case .parakeetV3: return "v3"
        }
    }

    /// Whether a `.mlmodelc` path belongs to `model`: Parakeet family + version.
    static func pathMatches(_ path: String, model: SttModel) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix(".mlmodelc") && p.contains("parakeet") && p.contains(matchToken(for: model))
    }

    // MARK: - Persistence (UserDefaults; anonymous metadata only)

    private static func key(for model: SttModel) -> String {
        "coreml.compiled.fingerprint.\(model.rawValue)"
    }

    static func storedFingerprint(
        for model: SttModel, defaults: UserDefaults = .standard
    ) -> Fingerprint? {
        guard let dict = defaults.dictionary(forKey: key(for: model)),
              let path = dict["path"] as? String,
              let modifiedAt = dict["modifiedAt"] as? Double,
              let bytes = (dict["bytes"] as? NSNumber)?.int64Value else { return nil }
        return Fingerprint(path: path, modifiedAt: modifiedAt, bytes: bytes)
    }

    static func record(_ fp: Fingerprint, for model: SttModel, defaults: UserDefaults = .standard) {
        defaults.set(
            ["path": fp.path, "modifiedAt": fp.modifiedAt, "bytes": NSNumber(value: fp.bytes)],
            forKey: key(for: model))
    }

    // MARK: - Disk scan (thin shell)

    /// Locate the newest compiled `.mlmodelc` bundle for `model`, or nil if the
    /// model hasn't been compiled yet.
    static func locate(model: SttModel, home: String = NSHomeDirectory()) -> Fingerprint? {
        let fm = FileManager.default
        var best: Fingerprint?
        for root in candidateRoots(home: home) {
            guard let e = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e {
                let path = url.path
                guard pathMatches(path, model: model) else { continue }
                // A .mlmodelc is a directory bundle; don't descend into it.
                e.skipDescendants()
                let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let mtime = attrs?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let bytes = bundleSize(path)
                let fp = Fingerprint(path: path, modifiedAt: mtime, bytes: bytes)
                if best == nil || fp.modifiedAt > best!.modifiedAt { best = fp }
            }
        }
        return best
    }

    private static func bundleSize(_ path: String) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    /// Probe the on-disk state against what the last launch recorded. Reads the
    /// current artifact and the stored fingerprint; does not mutate anything.
    static func probe(model: SttModel, defaults: UserDefaults = .standard) -> Probe {
        Probe(current: locate(model: model), previous: storedFingerprint(for: model, defaults: defaults))
    }
}
