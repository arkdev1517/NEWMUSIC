import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [BrowseRoute] = []
    @State private var showingImporter = false
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 23) {
                    shortcutsSection
                    accountLibrarySection
                    playlistsSection
                    recentSection
                    localSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 26)
            }
            .refreshable {
                if model.isYouTubeSignedIn { await model.loadLibrary(force: true) }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SettingsToolbarButton() }
            }
            .navigationDestination(for: BrowseRoute.self) { route in
                BrowseDetailView(route: route)
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task {
                        do {
                            let count = try await model.localAudio.importFiles(urls)
                            model.notice = count == 1 ? "Imported 1 audio file." : "Imported \(count) audio files."
                        } catch {
                            model.notice = error.localizedDescription
                        }
                    }
                case .failure(let error):
                    model.notice = error.localizedDescription
                }
            }
        }
        .task { await model.loadLibrary() }
        .onChange(of: model.isYouTubeSignedIn) { _, signedIn in
            if signedIn { Task { await model.loadLibrary(force: true) } }
        }
    }

    private var shortcutsSection: some View {
        VStack(spacing: 10) {
            shortcutRow(
                title: "Downloads",
                detail: model.downloads.downloads.isEmpty
                    ? "Songs saved for offline listening"
                    : "\(model.downloads.downloads.count) song\(model.downloads.downloads.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(model.downloads.totalBytes), countStyle: .file))",
                systemImage: "arrow.down.circle.fill"
            ) {
                DownloadsView()
            }
            shortcutRow(
                title: "History",
                detail: "What you've been listening to",
                systemImage: "clock.arrow.circlepath"
            ) {
                HistoryView()
            }
            shortcutRow(
                title: "Your Replay",
                detail: "Top songs, artists and listening time",
                systemImage: "chart.bar.fill"
            ) {
                StatsView()
            }
        }
    }

    private func shortcutRow<Destination: View>(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(BitChordStyle.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(BitChordStyle.cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                ShelfHeader(title: "Your playlists", subtitle: "Kept on this iPhone")
                Spacer()
                Button {
                    newPlaylistName = ""
                    showingNewPlaylist = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(BitChordStyle.accent)
                }
                .accessibilityLabel("New playlist")
            }
            if model.playlists.playlists.isEmpty {
                Text("Playlists you make on this iPhone live here. They work signed-out and are part of your backup.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ForEach(model.playlists.playlists) { playlist in
                    NavigationLink {
                        LocalPlaylistDetailView(playlistID: playlist.id)
                    } label: {
                        HStack(spacing: 13) {
                            ArtworkView(url: playlist.artworkURL, size: 54)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("^[\(playlist.tracks.count) song](inflect: true)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            if let first = playlist.tracks.first {
                                model.play(first, queue: playlist.tracks)
                            }
                        } label: { Label("Play", systemImage: "play.fill") }
                        Button {
                            model.playShuffled(playlist.tracks)
                        } label: { Label("Shuffle play", systemImage: "shuffle") }
                        Button(role: .destructive) {
                            model.playlists.delete(playlist)
                        } label: { Label("Delete playlist", systemImage: "trash") }
                    }
                }
            }
        }
        .alert("New playlist", isPresented: $showingNewPlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                model.playlists.createPlaylist(name: newPlaylistName)
            }
        }
    }

    @ViewBuilder
    private var accountLibrarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: "YouTube Music")
            if !model.isYouTubeSignedIn {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Connect your YouTube Music account to browse your saved songs, albums, artists and playlists.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Connect account", systemImage: "person.crop.circle.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BitChordStyle.accent)
                }
                .padding(16)
                .background(BitChordStyle.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if model.isLibraryLoading && model.libraryShelves.isEmpty {
                ProgressView("Loading your library")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else if let error = model.libraryError, model.libraryShelves.isEmpty {
                RetryStateView(message: error) { Task { await model.loadLibrary(force: true) } }
            } else if model.libraryShelves.isEmpty {
                Text("Your YouTube Music library is empty, or its shelves were unavailable.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.libraryShelves) { shelf in
                    MusicShelfView(shelf: shelf) { item in
                        play(item, from: shelf.items)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !model.localAudio.recentTracks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ShelfHeader(title: "Recently played")
                ForEach(model.localAudio.recentTracks) { track in
                    TrackRow(
                        track: track,
                        isCurrent: model.playback.currentTrack?.id == track.id,
                        isPlaying: model.playback.isPlaying
                    ) {
                        model.play(track, queue: model.localAudio.recentTracks)
                    }
                }
            }
        }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                ShelfHeader(title: "On this iPhone", subtitle: "Audio files imported into BitChord")
                Spacer()
                Button {
                    showingImporter = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(BitChordStyle.accent)
                }
                .accessibilityLabel("Import audio files")
            }
            if model.localAudio.tracks.isEmpty {
                EmptyStateView(
                    title: "Your local music lives here",
                    message: "Import audio files from Files. BitChord copies them into its private app storage.",
                    systemImage: "iphone.and.arrow.forward",
                    actionTitle: "Import audio",
                    action: { showingImporter = true }
                )
                .padding(.top, -12)
            } else {
                ForEach(model.localAudio.tracks) { track in
                    TrackRow(
                        track: track,
                        isCurrent: model.playback.currentTrack?.id == track.id,
                        isPlaying: model.playback.isPlaying,
                        showsContextMenu: false
                    ) {
                        model.play(track, queue: model.localAudio.tracks)
                    }
                    .contextMenu {
                        TrackActionsMenu(track: track)
                        Divider()
                        Button(role: .destructive) {
                            do { try model.localAudio.remove(track) }
                            catch { model.notice = error.localizedDescription }
                        } label: {
                            Label("Remove from BitChord", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func play(_ item: MusicItem, from items: [MusicItem]) {
        guard let track = item.track() else { return }
        model.play(track, queue: items.compactMap { $0.track() })
    }
}
