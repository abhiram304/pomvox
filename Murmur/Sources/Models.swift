import Foundation

/// One dictation, mirroring a row of the Python app's `history` table
/// (history.py): `id, ts, raw_text, final_text, cleanup_status, app_hint,
/// duration_s, timings_json`. The Hub reads these; it never writes them.
struct Dictation: Identifiable, Hashable {
    let id: Int64
    let timestamp: Date
    let raw: String
    let final: String
    let cleanupStatus: String
    let appHint: String?
    let durationSeconds: Double?

    /// Word count of the cleaned text — the unit every stat is built from.
    var wordCount: Int { Self.countWords(final) }

    static func countWords(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

/// One day's dictation volume, for the 30-day activity strip.
struct DayBucket: Identifiable {
    let id: Int          // 0 = oldest shown day, ascending
    let date: Date
    let words: Int
}

/// Everything the Home dashboard summarizes — all computed on this Mac,
/// compared to nobody.
struct HubStats {
    var totalWords: Int = 0
    var dictationCount: Int = 0
    /// Words ÷ minutes spoken, over dictations with a known positive duration.
    var averageWPM: Int = 0
    var activity: [DayBucket] = []

    var spokenHours: Double {
        // derived only for display; activity-independent
        Double(secondsSpoken) / 3600.0
    }
    var secondsSpoken: Int = 0

    static let empty = HubStats()
}
