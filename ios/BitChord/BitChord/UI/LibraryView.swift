import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [BrowseRoute] = []
    @State private var showingImporter = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 23) {
                    accountLibrarySection
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
                        isPlaying: model.playback.isPlaying
                    ) {
                        model.play(track, queue: model.localAudio.tracks)
                    }
                    .contextMenu {
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
