import Foundation

/// One timed word (or syllable run) inside a line, from enhanced-LRC
/// `<mm:ss.xx>` stamps. Mirrors `LyricWord` in the shared Kotlin code.
struct LyricWord: Codable, Hashable, Sendable {
    var startMs: Int
    var endMs: Int
    var text: String
}

/// One lyric line. `timeMs` is when the line starts; `words` is empty for
/// line-synced sources (LRCLIB, YouTube Music's lyrics tab) and populated for
/// word-synced ones. A line with empty text is an instrumental gap marker.
struct LyricLine: Codable, Hashable, Sendable, Identifiable {
    var timeMs: Int
    var text: String
    var words: [LyricWord] = []

    var id: Int { timeMs }
    var isGap: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }
    var isWordSynced: Bool { !words.isEmpty }
}

/// Where a set of lyrics came from, named the way the Android providers are
/// named in its lyrics-source picker.
enum LyricsSource: String, Sendable {
    case lrclib = "LRCLIB"
    case youtubeMusic = "YouTube Music"
    case transcript = "YouTube captions"
    case embedded = "Embedded in file"
}

struct TrackLyrics: Sendable {
    var lines: [LyricLine]
    var source: LyricsSource
    /// True when at least one line carries a real timestamp. YouTube Music's
    /// lyrics tab is plain text; LRCLIB and captions are timed.
    var isSynced: Bool
}
