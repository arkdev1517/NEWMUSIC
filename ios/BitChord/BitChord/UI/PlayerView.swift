import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var model: AppModel
    let openPlayer: () -> Void

    @ViewBuilder
    var body: some View {
        if let track = model.playback.currentTrack {
            HStack(spacing: 11) {
                Button(action: openPlayer) {
                    HStack(spacing: 11) {
                        ArtworkView(url: track.artworkURL, size: 42, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(track.title), \(track.artist). Open player.")

                if model.playback.isLoading {
                    ProgressView().controlSize(.small).padding(.horizontal, 4)
                }
                Button(action: model.togglePlayback) {
                    Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.playback.isPlaying ? "Pause" : "Play")
                Button(action: model.playNext) {
                    Image(systemName: "forward.end.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next track")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(BitChordStyle.cardBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if model.playback.duration > 0 {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(BitChordStyle.accent)
                            .frame(width: geometry.size.width * min(1, model.playback.position / model.playback.duration), height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottomLeading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 5)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var queueExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let track = model.playback.currentTrack {
                    VStack(spacing: 20) {
                        ArtworkView(url: track.artworkURL, size: 292, cornerRadius: 22)
                            .shadow(color: .black.opacity(0.2), radius: 18, y: 9)
                            .padding(.top, 12)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(track.title)
                                .font(.title2.weight(.bold))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(track.artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let error = model.playback.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        } else if model.playback.isLoading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Resolving audio stream…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        VStack(spacing: 7) {
                            Slider(
                                value: Binding(
                                    get: { min(model.playback.position, max(model.playback.duration, 1)) },
                                    set: { model.seek(to: $0) }
                                ),
                                in: 0...max(model.playback.duration, 1)
                            )
                            .tint(BitChordStyle.accent)
                            .disabled(model.playback.duration <= 0)
                            HStack {
                                Text(formatTime(model.playback.position))
                                Spacer()
                                Text(formatTime(model.playback.duration))
                            }
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 36) {
                            Button(action: model.playPrevious) {
                                Image(systemName: "backward.end.fill")
                                    .font(.title2)
                                    .frame(width: 45, height: 52)
                            }
                            .accessibilityLabel("Previous track")
                            Button(action: model.togglePlayback) {
                                Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 68, height: 68)
                                    .background(BitChordStyle.accent, in: Circle())
                            }
                            .accessibilityLabel(model.playback.isPlaying ? "Pause" : "Play")
                            Button(action: model.playNext) {
                                Image(systemName: "forward.end.fill")
                                    .font(.title2)
                                    .frame(width: 45, height: 52)
                            }
                            .accessibilityLabel("Next track")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .padding(.vertical, 2)

                        HStack(spacing: 28) {
                            Button {
                                model.toggleLike(track)
                            } label: {
                                Label(
                                    model.likedTrackIDs.contains(track.id) ? "Liked" : "Like",
                                    systemImage: model.likedTrackIDs.contains(track.id) ? "heart.fill" : "heart"
                                )
                            }
                            .disabled(track.videoID == nil)
                            .accessibilityHint("Saves this track to your YouTube Music account")

                            if let url = track.shareURL {
                                ShareLink(item: url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .tint(model.likedTrackIDs.contains(track.id) ? BitChordStyle.accent : Color.primary)
                        .padding(.bottom, 4)

                        if !model.queue.isEmpty {
                            DisclosureGroup("Queue · \(model.queue.count) tracks", isExpanded: $queueExpanded) {
                                VStack(spacing: 4) {
                                    ForEach(Array(model.queue.enumerated()), id: \.element.id) { index, queuedTrack in
                                        TrackRow(
                                            track: queuedTrack,
                                            isCurrent: index == model.queueIndex,
                                            isPlaying: model.playback.isPlaying
                                        ) {
                                            model.play(queuedTrack, queue: model.queue)
                                        }
                                    }
                                }
                                .padding(.top, 8)
                            }
                            .font(.headline)
                            .tint(.primary)
                            .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 32)
                } else {
                    EmptyStateView(title: "Nothing is playing", message: "Choose a song from Home, Explore, Library or Search.")
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(BitChordStyle.accent)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
