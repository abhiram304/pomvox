import FluidAudio
import Foundation

/// The `[stt] model` config string resolved to a FluidAudio Parakeet version.
///
/// Parsing is pure logic (string → case) so it's unit-testable and mirrors the
/// Python engine, which hands the same string to `parakeet-mlx`. The FluidAudio
/// bridge (`fluidVersion`) is the only part that touches the loader enum.
///
/// Only the English Parakeet TDT 0.6b family is wired today — the ANE fast path
/// M0 proved (Transcriber). An empty or unrecognized string resolves to
/// `.default` (the shipped v3), so a typo in config.toml degrades to "works
/// with the default model" instead of failing to arm.
enum SttModel: String, CaseIterable, Sendable {
    case parakeetV2
    case parakeetV3

    /// The safe fallback: the shipped default model.
    static let `default` = SttModel.parakeetV3

    /// Resolve a `[stt] model` value to a known model, or `nil` when it names
    /// no wired model (caller falls back to `.default`). Matching is on the
    /// version suffix so both the HF repo id (`mlx-community/parakeet-tdt-0.6b-v3`)
    /// and a bare name resolve; it's case- and separator-insensitive.
    static func parse(_ raw: String) -> SttModel? {
        let s = raw.lowercased()
        guard s.contains("parakeet") else { return nil }
        // v3 before v2 is moot (distinct substrings) but ordered for clarity.
        if s.contains("v3") { return .parakeetV3 }
        if s.contains("v2") { return .parakeetV2 }
        return nil
    }

    /// Resolve a config string to a concrete model, always succeeding — the
    /// never-fail entry point used at arm().
    static func resolve(_ raw: String) -> SttModel {
        parse(raw) ?? .default
    }

    /// FluidAudio's loader enum for this model.
    var fluidVersion: AsrModelVersion {
        switch self {
        case .parakeetV2: return .v2
        case .parakeetV3: return .v3
        }
    }
}
