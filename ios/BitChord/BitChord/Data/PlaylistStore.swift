import Combine
import Foundation

/// A playlist kept on the device — the counterpart of Android's
/// `LocalPlaylistStore`. Account playlists live on YouTube Music and are
/// edited through the InnerTube endpoints; these work signed-out, hold
/// imported local files too, and are part of the backup export.
struct LocalPlaylist: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var tracks: [MusicTrack]
    var createdAt: Date

    var artworkURL: String? { tracks.first?.artworkURL }

    var totalDurationText: String? {
        let seconds = tracks.compactMap(\.durationSeconds).reduce(0, +)
        guard seconds > 0 else { return nil }
        let total = Int(seconds)
        return total >= 3600
            ? "\(total / 3600)h \((total % 3600) / 60)m"
            : "\(total / 60)m"
    }
}

@MainActor
final class PlaylistStore: ObservableObject {
    @Published private(set) var playlists: [LocalPlaylist] = []

    private let directory: URL
    private let fileName = "local-playlists.json"

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = support
        load()
    }

    @discardableResult
    func createPlaylist(name: String, tracks: [MusicTrack] = []) -> LocalPlaylist {
        let playlist = LocalPlaylist(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled playlist" : name,
            tracks: tracks,
            createdAt: Date()
        )
        playlists.insert(playlist, at: 0)
        persist()
        return playlist
    }

    func rename(_ playlist: LocalPlaylist, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        playlists[index].name = cleaned
        persist()
    }

    func delete(_ playlist: LocalPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        persist()
    }

    func add(_ track: MusicTrack, to playlist: LocalPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].tracks.append(track)
        persist()
    }

    func removeTracks(atOffsets offsets: IndexSet, from playlist: LocalPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].tracks.remove(atOffsets: offsets)
        persist()
    }

    func moveTracks(fromOffsets source: IndexSet, toOffset destination: Int, in playlist: LocalPlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].tracks.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func playlist(id: String) -> LocalPlaylist? {
        playlists.first { $0.id == id }
    }

    func importPlaylists(_ imported: [LocalPlaylist]) {
        let known = Set(playlists.map(\.id))
        playlists.append(contentsOf: imported.filter { !known.contains($0.id) })
        persist()
    }

    private var fileURL: URL { directory.appendingPathComponent(fileName, isDirectory: false) }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LocalPlaylist].self, from: data) else { return }
        playlists = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
