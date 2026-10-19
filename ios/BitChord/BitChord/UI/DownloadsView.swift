import SwiftUI

/// Downloaded songs and the in-flight queue — Android's
/// `DownloadManagerSheet` plus the Downloads library section: progress for
/// active transfers, sizes, play/delete per song, clear-all.
struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingClearConfirm = false

    var body: some View {
        Group {
            if model.downloads.downloads.isEmpty && model.downloads.progress.isEmpty {
                EmptyStateView(
                    title: "No downloads yet",
                    message: "Download songs from their actions menu and they'll live here, ready to play offline.",
                    systemImage: "arrow.down.circle"
                )
            } else {
                List {
                    if !model.downloads.progress.isEmpty {
                        Section("Downloading") {
                            ForEach(Array(model.downloads.progress.keys.sorted()), id: \.self) { id in
                                if let track = track(for: id) {
                                    HStack(spacing: 13) {
                                        ArtworkView(url: track.artworkURL, size: 48)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(track.title)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                            ProgressView(value: model.downloads.progress[id] ?? 0)
                                                .tint(BitChordStyle.accent)
                                            Text("\(Int((model.downloads.progress[id] ?? 0) * 100))%")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button {
                                            model.downloads.cancel(track)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Cancel download")
                                    }
                                }
                            }
                        }
                    }

                    Section {
                        ForEach(model.downloads.downloads) { entry in
                            TrackRow(
                                track: entry.track,
                                isCurrent: model.playback.currentTrack?.id == entry.track.id,
                                isPlaying: model.playback.isPlaying
                            ) {
                                model.play(entry.track, queue: model.downloads.downloads.map(\.track))
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.deleteDownload(entry.track)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("Downloaded")
                    } footer: {
                        if !model.downloads.downloads.isEmpty {
                            Text("^[\(model.downloads.downloads.count) song](inflect: true) · \(ByteCountFormatter.string(fromByteCount: Int64(model.downloads.totalBytes), countStyle: .file)) on this iPhone")
                        }
                    }

                    if !model.downloads.failures.isEmpty {
                        Section("Failed") {
                            ForEach(Array(model.downloads.failures.sorted(by: { $0.key < $1.key })), id: \.key) { id, message in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track(for: id)?.title ?? "Song")
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let track = track(for: id) {
                                    Button("Try again") {
                                        model.downloadTrack(track)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(BitChordStyle.accent)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !model.downloads.downloads.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear all", role: .destructive) {
                        showingClearConfirm = true
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .alert("Delete all downloads?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete all", role: .destructive) {
                model.downloads.deleteAll()
            }
        } message: {
            Text("Downloaded songs will need an internet connection to play again.")
        }
    }

    private func track(for id: String) -> MusicTrack? {
        model.downloads.downloads.first(where: { $0.track.id == id })?.track
            ?? model.queue.first(where: { $0.id == id })
            ?? model.recorder.recentTracks.first(where: { $0.id == id })
            ?? model.playback.currentTrack.flatMap { $0.id == id ? $0 : nil }
    }
}
