// Pomvox/Sources/Engine/EmptyTranscript.swift
import Foundation

/// Peak level of an utterance in dBFS. Distinguishes "the mic delivered
/// (near-)zeros" (dead stream after deep sleep) from "audible audio with no
/// recognizable words" — `blockDbfs` is RMS over a block; for the whole
/// utterance the peak is the honest liveness signal.
func peakDbfs(_ samples: [Float]) -> Double {
    var peak: Float = 0
    for s in samples { peak = max(peak, abs(s)) }
    return 20 * log10(Double(peak) + 1e-12)
}

/// Why did a non-trivial recording transcribe to ""? Ordered by blame:
/// a thrown STT error is a bug; a silent capture is a hardware/driver fault
/// the user must hear about; true no-speech is normal and stays quiet; and a
/// dictionary wipe — raw STT text existed but the user's replacement rules
/// deleted every word — is the user's own doing, not a pipeline fault.
/// (`CleanupLogic.sanitize` rejects an empty LLM output and falls back to
/// raw, so cleanup can never itself turn non-empty raw into "" — only the
/// dictionary replacement pass can do that.)
enum EmptyTranscriptCause: Equatable {
    case sttFailed(String)     // transcriber threw — the error text (logs only)
    case silentAudio(Double)   // peak dBFS below floor — mic gave (near-)zeros
    case noSpeech(Double)      // audio had energy, just no words — not an error
    case dictionaryWiped       // raw had words; the replacement rules deleted them all

    /// Anonymous telemetry code (contract: ^[a-z0-9_]{1,40}$); nil = not an error.
    var errorCode: String? {
        switch self {
        case .sttFailed: "stt_failed"
        case .silentAudio: "silent_audio"
        case .noSpeech: nil
        case .dictionaryWiped: "dictionary_wiped"
        }
    }

    /// HUD error-flash copy; nil = hide silently (today's behavior).
    var hudMessage: String? {
        switch self {
        case .sttFailed: "transcription failed — try again"
        case .silentAudio: "mic captured silence — check your input device"
        case .noSpeech: nil
        case .dictionaryWiped:
            "your replacement rules removed every word — check the Dictionary page"
        }
    }
}

func classifyEmptyTranscript(rawWasEmpty: Bool, peakDbfs: Double, sttError: String?,
                             silenceFloorDbfs: Double = -70.0) -> EmptyTranscriptCause {
    if !rawWasEmpty { return .dictionaryWiped }
    if let sttError { return .sttFailed(sttError) }
    if peakDbfs < silenceFloorDbfs { return .silentAudio(peakDbfs) }
    return .noSpeech(peakDbfs)
}
