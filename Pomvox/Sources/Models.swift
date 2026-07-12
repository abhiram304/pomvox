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

/// One cell of the 90-day calendar heatmap: a single day placed on a
/// week (column) × weekday (row) grid. `inFuture` days sit past today in the
/// last column and render blank. Pure value type, built by `HistoryReader`.
struct HeatmapCell: Identifiable {
    let id: Int          // week * 7 + weekday, stable across a render
    let date: Date
    let words: Int
    let week: Int        // 0 = oldest shown week (leftmost column)
    let weekday: Int     // 0 = Sunday … 6 = Saturday (calendar-relative)
    let inFuture: Bool    // beyond today — drawn empty, excluded from stats
}

/// Everything the Home dashboard summarizes — all computed on this Mac,
/// compared to nobody.
struct HubStats {
    var totalWords: Int = 0
    var dictationCount: Int = 0
    /// Purge-proof all-time counters from `lifetime_stats` — unlike the two
    /// above, these do NOT shrink when retention prunes rows. nil when the db
    /// predates the table; display falls back to the windowed sums.
    var lifetimeWords: Int?
    var lifetimeDictations: Int?
    /// Words ÷ minutes spoken, over dictations with a known positive duration.
    var averageWPM: Int = 0
    var activity: [DayBucket] = []
    /// Consecutive days (ending today, or yesterday if today is still empty) on
    /// which you dictated. Your own streak — compared to nobody.
    var streak: Int = 0

    var spokenHours: Double {
        // derived only for display; activity-independent
        Double(secondsSpoken) / 3600.0
    }
    var secondsSpoken: Int = 0

    static let empty = HubStats()
}
