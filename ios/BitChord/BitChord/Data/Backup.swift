import Foundation

/// Backup export/import — the counterpart of Android's `data/stats/Backup.kt`.
/// One JSON document carrying the parts of BitChord that belong to the user
/// and exist on iOS: settings values, local playlists, listening history and
/// search history. Credentials (YouTube cookie, scrobbling keys) are never
/// written into a backup — they stay in the Keychain.
struct BitChordBackup: Codable, Sendable {
    var formatVersion: Int
    var exportedAt: Date
    var settings: [String: String]
    var playlists: [LocalPlaylist]
    var listeningEvents: [PlayEvent]
    var searchHistory: [MusicSearchHistory]

    static let currentFormatVersion = 1

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> BitChordBackup {
        let backup = try JSONDecoder().decode(BitChordBackup.self, from: data)
        guard backup.formatVersion <= currentFormatVersion else {
            throw MusicRequestError.service(
                "This backup was made by a newer version of BitChord (format \(backup.formatVersion)). Update the app to restore it."
            )
        }
        return backup
    }
}
