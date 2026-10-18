import AVFoundation
import Combine
import Foundation

@MainActor
final class LocalAudioStore: ObservableObject {
    @Published private(set) var tracks: [MusicTrack] = []
    @Published private(set) var recentTracks: [MusicTrack] = []

    private let defaults: UserDefaults
    private let manifestKey = "imported-audio-manifest-v1"
    private let recentsKey = "recently-played-v1"
    private let directory: URL

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = support.appendingPathComponent("ImportedAudio", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func importFiles(_ urls: [URL]) async throws -> Int {
        var imported: [MusicTrack] = []
        for source in urls {
            let hasScope = source.startAccessingSecurityScopedResource()
            defer {
                if hasScope { source.stopAccessingSecurityScopedResource() }
            }
            let fileName = "\(UUID().uuidString).\(source.pathExtension.isEmpty ? "audio" : source.pathExtension)"
            let destination = directory.appendingPathComponent(fileName, isDirectory: false)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                let metadata = await Self.readMetadata(at: destination)
                let fallback = source.deletingPathExtension().lastPathComponent
                imported.append(MusicTrack(
                    videoID: nil,
                    title: metadata.title ?? fallback,
                    artist: metadata.artist ?? "Unknown artist",
                    artworkURL: nil,
                    durationText: metadata.duration.map(Self.durationLabel),
                    albumName: metadata.album,
                    localFileName: fileName
                ))
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
        guard !imported.isEmpty else { return 0 }
        let known = Set(tracks.map(\.id))
        let unique = imported.filter { !known.contains($0.id) }
        tracks.insert(contentsOf: unique, at: 0)
        try persistManifest()
        return unique.count
    }

    func localURL(for track: MusicTrack) throws -> URL {
        guard let fileName = track.localFileName else { throw CocoaError(.fileNoSuchFile) }
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    func recordRecent(_ track: MusicTrack) {
        recentTracks.removeAll { $0.id == track.id }
        recentTracks.insert(track, at: 0)
        recentTracks = Array(recentTracks.prefix(50))
        persistRecents()
    }

    func clearHistory() {
        recentTracks = []
        defaults.removeObject(forKey: recentsKey)
    }

    func remove(_ track: MusicTrack) throws {
        if let fileName = track.localFileName {
            let url = directory.appendingPathComponent(fileName)
            try FileManager.default.removeItem(at: url)
        }
        tracks.removeAll { $0.id == track.id }
        try persistManifest()
    }

    private func load() {
        if let data = defaults.data(forKey: manifestKey),
           let decoded = try? JSONDecoder().decode([MusicTrack].self, from: data) {
            tracks = decoded.filter { track in
                guard let name = track.localFileName else { return false }
                return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
            }
        }
        if let data = defaults.data(forKey: recentsKey),
           let decoded = try? JSONDecoder().decode([MusicTrack].self, from: data) {
            recentTracks = decoded
        }
    }

    private func persistManifest() throws {
        defaults.set(try JSONEncoder().encode(tracks), forKey: manifestKey)
    }

    private func persistRecents() {
        guard let data = try? JSONEncoder().encode(recentTracks) else { return }
        defaults.set(data, forKey: recentsKey)
    }

    private static func readMetadata(at url: URL) async -> (title: String?, artist: String?, album: String?, duration: TimeInterval?) {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let title = await stringValue(.commonIdentifierTitle, in: metadata)
        let artist = await stringValue(.commonIdentifierArtist, in: metadata)
        let album = await stringValue(.commonIdentifierAlbumName, in: metadata)
        let time = try? await asset.load(.duration)
        let duration = time?.seconds.isFinite == true && (time?.seconds ?? 0) > 0 ? time?.seconds : nil
        return (title, artist, album, duration)
    }

    private static func stringValue(_ identifier: AVMetadataIdentifier, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func durationLabel(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded()))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
