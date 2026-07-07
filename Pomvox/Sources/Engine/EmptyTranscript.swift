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
/// the user must hear about; true no-speech is normal and stays quiet.
enum EmptyTranscriptCause: Equatable {
    case sttFailed(String)     // transcriber threw — the error text (logs only)
    case silentAudio(Double)   // peak dBFS below floor — mic gave (near-)zeros
    case noSpeech(Double)      // audio had energy, just no words — not an error

    /// Anonymous telemetry code (contract: ^[a-z0-9_]{1,40}$); nil = not an error.
    var errorCode: String? {
        switch self {
        case .sttFailed: "stt_failed"
        case .silentAudio: "silent_audio"
        case .noSpeech: nil
        }
    }

    /// HUD error-flash copy; nil = hide silently (today's behavior).
    var hudMessage: String? {
        switch self {
        case .sttFailed: "transcription failed — try again"
        case .silentAudio: "mic captured silence — check your input device"
        case .noSpeech: nil
        }
    }
}

func classifyEmptyTranscript(peakDbfs: Double, sttError: String?,
                             silenceFloorDbfs: Double = -70.0) -> EmptyTranscriptCause {
    if let sttError { return .sttFailed(sttError) }
    if peakDbfs < silenceFloorDbfs { return .silentAudio(peakDbfs) }
    return .noSpeech(peakDbfs)
}
