import SwiftUI

/// "Add to playlist" — Android's `PlaylistPickerSheet`: on-device playlists
/// first, the account's YouTube Music playlists below when signed in, and
/// new-playlist creation for both. Adding dismisses immediately; the model
/// reports the outcome through the usual notice.
struct AddToPlaylistSheet: View {
    let track: MusicTrack

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountPlaylists: [MusicItem] = []
    @State private var isLoadingAccount = false
    @State private var showingNewLocal = false
    @State private var showingNewAccount = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 13) {
                        ArtworkView(url: track.artworkURL, size: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section("On this iPhone") {
                    Button {
                        newPlaylistName = ""
                        showingNewLocal = true
                    } label: {
                        Label("New playlist", systemImage: "plus.circle.fill")
                            .foregroundStyle(BitChordStyle.accent)
                    }
                    ForEach(model.playlists.playlists) { playlist in
                        Button {
                            model.playlists.add(track, to: playlist)
                            model.notice = "Added to \(playlist.name)."
                            dismiss()
                        } label: {
                            PlaylistRowLabel(
                                title: playlist.name,
                                subtitle: "\(playlist.tracks.count) song\(playlist.tracks.count == 1 ? "" : "s")",
                                artworkURL: playlist.artworkURL
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if model.isYouTubeSignedIn && track.videoID != nil {
                    Section("YouTube Music") {
                        Button {
                            newPlaylistName = ""
                            showingNewAccount = true
                        } label: {
                            Label("New playlist", systemImage: "plus.circle.fill")
                                .foregroundStyle(BitChordStyle.accent)
                        }
                        if isLoadingAccount {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Loading your playlists…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(accountPlaylists) { item in
                            Button {
                                if let browseID = item.browseID {
                                    model.addTrackToAccountPlaylist(track, playlistID: browseID)
                                }
                                dismiss()
                            } label: {
                                PlaylistRowLabel(title: item.title, subtitle: item.subtitle, artworkURL: item.artworkURL)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                guard model.isYouTubeSignedIn else { return }
                isLoadingAccount = true
                accountPlaylists = await model.fetchAccountPlaylists()
                isLoadingAccount = false
            }
            .alert("New playlist", isPresented: $showingNewLocal) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let playlist = model.playlists.createPlaylist(name: newPlaylistName, tracks: [track])
                    model.notice = "Created \(playlist.name)."
                    dismiss()
                }
            }
            .alert("New YouTube Music playlist", isPresented: $showingNewAccount) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    model.createAccountPlaylist(title: newPlaylistName, firstTrack: track)
                    dismiss()
                }
            }
        }
        .tint(BitChordStyle.accent)
    }
}

private struct PlaylistRowLabel: View {
    let title: String
    let subtitle: String
    let artworkURL: String?

    var body: some View {
        HStack(spacing: 13) {
            ArtworkView(url: artworkURL, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// One on-device playlist: play/shuffle header, editable track list,
/// rename and delete. The local counterpart of the account playlist page.
struct LocalPlaylistDetailView: View {
    let playlistID: String

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var renameText = ""

    private var playlist: LocalPlaylist? {
        model.playlists.playlist(id: playlistID)
    }

    var body: some View {
        Group {
            if let playlist {
                playlistContent(playlist)
            } else {
                EmptyStateView(
                    title: "Playlist deleted",
                    message: "This playlist no longer exists."
                )
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let playlist {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            renameText = playlist.name
                            showingRename = true
                        } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) {
                            showingDelete = true
                        } label: { Label("Delete playlist", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Rename playlist", isPresented: $showingRename) {
            TextField("Playlist name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let playlist { model.playlists.rename(playlist, to: renameText) }
            }
        }
        .alert("Delete this playlist?", isPresented: $showingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let playlist {
                    model.playlists.delete(playlist)
                    dismiss()
                }
            }
        } message: {
            Text("The songs stay in your library; only this list goes away.")
        }
    }

    private func playlistContent(_ playlist: LocalPlaylist) -> some View {
        List {
            Section {
                HStack(spacing: 16) {
                    ArtworkView(url: ArtworkURL.upgraded(playlist.artworkURL, target: 360), size: 96, cornerRadius: 14)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(playlist.name)
                            .font(.title3.weight(.bold))
                            .lineLimit(2)
                        Text("^[\(playlist.tracks.count) song](inflect: true)\(playlist.totalDurationText.map { " · \($0)" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !playlist.tracks.isEmpty {
                            HStack(spacing: 10) {
                                Button {
                                    guard let first = playlist.tracks.first else { return }
                                    model.play(first, queue: playlist.tracks)
                                } label: {
                                    Label("Play", systemImage: "play.fill")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(BitChordStyle.accent)
                                Button {
                                    model.playShuffled(playlist.tracks)
                                } label: {
                                    Label("Shuffle", systemImage: "shuffle")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .tint(BitChordStyle.accent)
                            }
                            .padding(.top, 2)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
            }

            if playlist.tracks.isEmpty {
                EmptyStateView(
                    title: "No songs yet",
                    message: "Use “Add to playlist” on any song to start this list.",
                    systemImage: "music.note.list"
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(Array(playlist.tracks.enumerated()), id: \.offset) { _, track in
                        TrackRow(
                            track: track,
                            isCurrent: model.playback.currentTrack?.id == track.id,
                            isPlaying: model.playback.isPlaying
                        ) {
                            model.play(track, queue: playlist.tracks)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .onMove { source, destination in
                        model.playlists.moveTracks(fromOffsets: source, toOffset: destination, in: playlist)
                    }
                    .onDelete { offsets in
                        model.playlists.removeTracks(atOffsets: offsets, from: playlist)
                    }
                } footer: {
                    Text("Use Edit to reorder or remove songs.")
                }
            }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
    }
}
