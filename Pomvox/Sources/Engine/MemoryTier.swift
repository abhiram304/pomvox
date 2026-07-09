import Foundation

/// Memory-aware defaults for low-RAM Macs (e.g. an 8 GB MacBook).
///
/// The armed native engine keeps the Parakeet STT models resident (~600 MB) and,
/// when cleanup is on, also loads the Qwen3 cleanup LLM (~2.3 GB) — ~2.5 GB total.
/// On an 8 GB machine that risks memory pressure and swap, and GPU cleanup is the
/// slowest path there. So on a *fresh install* (no config yet) on a low-memory
/// Mac we default cleanup off: raw on-device dictation (~600 MB) that just works,
/// which the user can turn on in Settings ▸ Models.
///
/// Pure logic (RAM in → decision out) so it's unit-testable and can't regress an
/// existing user: it only ever supplies a *default* for an absent config key.
enum MemoryTier {
    /// Physical-RAM cutoff (bytes) at or below which cleanup is off by default.
    /// An 8 GB Mac reports exactly 8 × 1024³ bytes; the 8.5 GB cutoff catches any
    /// that report marginally under while staying well below the 16 GB tier.
    static let lowMemoryMaxBytes: UInt64 = 8 * 1024 * 1024 * 1024 + 512 * 1024 * 1024

    /// Whether this machine's physical RAM is in the low-memory tier.
    static func isLowMemory(_ physicalMemoryBytes: UInt64) -> Bool {
        physicalMemoryBytes <= lowMemoryMaxBytes
    }

    /// The default for `[cleanup] enabled` when the key is absent.
    ///
    /// - An existing config (`configExists == true`) always defaults to `true` —
    ///   this never changes behavior for a machine that has run Pomvox before.
    /// - A fresh install on a low-memory Mac defaults to `false` (raw dictation).
    /// - A fresh install on a 16 GB+ Mac defaults to `true` (unchanged).
    static func firstRunCleanupDefault(
        configExists: Bool, physicalMemoryBytes: UInt64
    ) -> Bool {
        if configExists { return true }
        return !isLowMemory(physicalMemoryBytes)
    }
}
