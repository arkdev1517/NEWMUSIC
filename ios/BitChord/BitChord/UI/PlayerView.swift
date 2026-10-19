import AVFoundation
import AVKit
import MediaPlayer
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
            .contextMenu {
                TrackActionsMenu(track: track)
            }
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

private enum PlayerPanel {
    case artwork
    case lyrics
    case queue
}

/// The player's own measurements for the space it is given.
///
/// The now-playing screen is a phone's: one column, the artwork on top of
/// it and the controls under it, all of the same width. A window wider
/// than a phone — a Mac, an iPad in landscape — must not stretch that
/// column across the whole width: the scrubber, the transport and the
/// action row would end up a hand's width apart, and the artwork would
/// float in the middle of them instead of lining up with the titles
/// under it. So the column keeps a phone's proportions and is centred in
/// whatever it is given, and the artwork gives up room when the window is
/// short rather than pushing the controls off the bottom.
struct PlayerLayout {
    /// The width of the column — the artwork's, so the two line up.
    let columnWidth: CGFloat

    /// The artwork's edge: square, as wide as the column.
    var artworkSize: CGFloat { columnWidth }

    init(in size: CGSize) {
        // The rows under the artwork — the title block, the scrubber, the
        // transport, the volume, the action row, the bottom row — with the
        // gaps between them. What is left over is the artwork's.
        let belowArtwork: CGFloat = 410
        let room = size.height - belowArtwork
        // A phone's width, and no wider than a comfortable column.
        let widest = min(max(size.width - 48, 240), 460)
        // Never narrower than the transport and the action row need, unless
        // the window itself is narrower than that.
        columnWidth = min(widest, max(300, min(widest, room)))
    }
}

/// The now-playing screen — Android's `NowPlayingScreen` layout: artwork (or
/// the lyrics/queue panel in its place), title block, scrubber, transport,
/// volume, then the action row with the shuffle/repeat/autoplay capsule
/// between the lyrics and queue toggles.
struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var panel: PlayerPanel = .artwork
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let layout = PlayerLayout(in: geometry.size)
                ZStack {
                    if let track = model.playback.currentTrack {
                        VStack(spacing: 14) {
                            panelArea(track: track, size: layout.artworkSize)

                            titleBlock(track)

                            if let error = model.playback.errorMessage {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            } else if model.playback.isLoading {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Resolving audio stream…")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            scrubber
                            transport

                            if model.settings.showNerdStats {
                                nerdStats
                            }

                            volumeRow
                            actionRow
                            bottomRow(track)
                            Spacer(minLength: 0)
                        }
                        // The phone's column, centred in a wider window. A
                        // Mac's or an iPad's is wide enough to stretch the
                        // scrubber, the transport and the action row across
                        // the whole thing, which is neither how the phone
                        // looks nor how the artwork lines up with them.
                        .frame(width: layout.columnWidth)
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        EmptyStateView(
                            title: "Nothing is playing",
                            message: "Choose a song from Home, Explore, Library or Search."
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background {
                    PlayerBackdrop(url: model.playback.currentTrack?.artworkURL)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Close player")
                }
                ToolbarItem(placement: .principal) {
                    Text("Now Playing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let track = model.playback.currentTrack {
                        overflowMenu(track)
                    }
                }
            }
        }
        .tint(BitChordStyle.accent)
    }

    // MARK: Panels

    @ViewBuilder
    private func panelArea(track: MusicTrack, size: CGFloat) -> some View {
        Group {
            switch panel {
            case .artwork:
                ArtworkView(url: ArtworkURL.upgraded(track.artworkURL, target: 720), size: size, cornerRadius: 18)
                    .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
                    .scaleEffect(model.playback.isPlaying ? 1 : 0.94)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: model.playback.isPlaying)
            case .lyrics:
                LyricsView()
                    .frame(width: size, height: size)
            case .queue:
                QueueView()
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .padding(.top, 6)
    }

    private func titleBlock(_ track: MusicTrack) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Button {
                    model.presentArtist(for: track)
                } label: {
                    Text(track.artist)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                if let album = track.albumName, !album.isEmpty {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer()
            if track.videoID != nil {
                Button {
                    model.toggleLike(track)
                } label: {
                    Image(systemName: model.likedTrackIDs.contains(track.id) ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(model.likedTrackIDs.contains(track.id) ? BitChordStyle.accent : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.likedTrackIDs.contains(track.id) ? "Remove from Liked Music" : "Like")
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubPosition : min(model.playback.position, max(model.playback.duration, 1)) },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(model.playback.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        scrubPosition = model.playback.position
                    } else {
                        model.seek(to: scrubPosition)
                    }
                }
            )
            .tint(BitChordStyle.accent)
            .disabled(model.playback.duration <= 0)
            HStack {
                Text(formatTime(isScrubbing ? scrubPosition : model.playback.position))
                Spacer()
                if model.sleepTimer.isRunning, let summary = model.sleepTimer.summary {
                    Label(summary, systemImage: "moon.fill")
                        .foregroundStyle(BitChordStyle.accent)
                    Spacer()
                }
                Text(formatTime(model.playback.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 40) {
            Button(action: model.playPrevious) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 30))
                    .frame(width: 52, height: 56)
            }
            .accessibilityLabel("Previous track")
            Button(action: model.togglePlayback) {
                Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 74, height: 74)
                    .background(BitChordStyle.accent, in: Circle())
                    .shadow(color: BitChordStyle.accent.opacity(0.4), radius: 12, y: 5)
            }
            .accessibilityLabel(model.playback.isPlaying ? "Pause" : "Play")
            Button(action: model.playNext) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 30))
                    .frame(width: 52, height: 56)
            }
            .accessibilityLabel("Next track")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private var nerdStats: some View {
        let parts: [String] = [
            model.currentStreamInfo?.codec ?? (model.playback.currentTrack?.localFileName != nil ? "Local file" : "—"),
            model.currentStreamInfo?.bitrateKbps.map { "\($0) kbps" } ?? "",
            model.currentStreamInfo?.sampleRateHz.map { "\($0) Hz" } ?? "",
            model.currentStreamInfo?.clientName ?? "",
            model.playback.rate != 1 ? "\(model.playback.rate)×" : ""
        ].filter { !$0.isEmpty }
        return Text(parts.joined(separator: " · "))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            VolumeSlider()
                .frame(height: 28)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Lyrics toggle · shuffle/repeat/autoplay capsule · queue toggle —
    /// `PlayerActionRow` on Android.
    private var actionRow: some View {
        HStack {
            CircleToggleButton(
                systemImage: "quote.bubble",
                highlighted: panel == .lyrics,
                label: "Lyrics"
            ) {
                panel = panel == .lyrics ? .artwork : .lyrics
            }

            Spacer()

            HStack(spacing: 0) {
                pillSegment(systemImage: "shuffle", highlighted: model.shuffleEnabled, label: "Shuffle") {
                    model.toggleShuffle()
                }
                pillSegment(
                    systemImage: model.repeatMode == .one ? "repeat.1" : "repeat",
                    highlighted: model.repeatMode != .off,
                    label: model.repeatMode.title
                ) {
                    model.cycleRepeat()
                }
                pillSegment(systemImage: "infinity", highlighted: model.settings.autoplay, label: "Autoplay") {
                    model.settings.autoplay.toggle()
                }
            }
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.12)) }

            Spacer()

            CircleToggleButton(
                systemImage: "list.bullet",
                highlighted: panel == .queue,
                label: "Queue"
            ) {
                panel = panel == .queue ? .artwork : .queue
            }
        }
    }

    private func pillSegment(systemImage: String, highlighted: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(highlighted ? BitChordStyle.accent : Color.secondary)
                .frame(width: 48, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(highlighted ? "On" : "Off")
    }

    private func bottomRow(_ track: MusicTrack) -> some View {
        HStack {
            RoutePicker()
                .frame(width: 44, height: 44)
            Spacer()
            if track.videoID != nil {
                downloadButton(track)
                Button {
                    model.toggleDislike(track)
                } label: {
                    Image(systemName: model.dislikedTrackIDs.contains(track.id) ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.body)
                        .foregroundStyle(model.dislikedTrackIDs.contains(track.id) ? BitChordStyle.accent : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dislike")
            }
            Spacer()
            if let url = track.shareURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Share")
            }
        }
    }

    @ViewBuilder
    private func downloadButton(_ track: MusicTrack) -> some View {
        if let progress = model.downloads.progress[track.id] {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .frame(width: 44, height: 44)
        } else {
            Button {
                if model.downloads.isDownloaded(track) {
                    model.deleteDownload(track)
                } else {
                    model.downloadTrack(track)
                }
            } label: {
                Image(systemName: model.downloads.isDownloaded(track) ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.body)
                    .foregroundStyle(model.downloads.isDownloaded(track) ? BitChordStyle.accent : Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.downloads.isDownloaded(track) ? "Delete download" : "Download")
        }
    }

    private func overflowMenu(_ track: MusicTrack) -> some View {
        Menu {
            Menu {
                Button {
                    model.sleepTimer.cancel()
                } label: {
                    Label("Off", systemImage: model.sleepTimer.isRunning ? "moon" : "checkmark")
                }
                ForEach(SleepTimer.presets, id: \.self) { minutes in
                    Button {
                        model.sleepTimer.start(minutes: minutes)
                    } label: {
                        Label(
                            minutes == 60 ? "1 hour" : "\(minutes) minutes",
                            systemImage: model.sleepTimer.minutes == minutes ? "checkmark" : "moon"
                        )
                    }
                }
                Button {
                    model.sleepTimer.startAfterTrack()
                } label: {
                    Label("After this song", systemImage: model.sleepTimer.afterTrack ? "checkmark" : "moon")
                }
            } label: {
                Label("Sleep timer", systemImage: "moon.fill")
            }

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Button {
                        model.setPlaybackSpeed(speed)
                    } label: {
                        Label(
                            speed == 1 ? "Normal" : "\(trimmed(speed))×",
                            systemImage: model.settings.playbackSpeed == speed ? "checkmark" : "gauge.with.dots.needle.50percent"
                        )
                    }
                }
            } label: {
                Label("Playback speed", systemImage: "gauge.with.dots.needle.67percent")
            }

            Divider()
            TrackActionsMenu(track: track)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.medium))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions")
    }

    private func trimmed(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        return text.replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 {
            return "\(total / 3600):\(String(format: "%02d", (total % 3600) / 60)):\(String(format: "%02d", total % 60))"
        }
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

private struct CircleToggleButton: View {
    let systemImage: String
    let highlighted: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(highlighted ? .white : .secondary)
                .frame(width: 40, height: 40)
                .background {
                    if highlighted {
                        Circle().fill(BitChordStyle.accent)
                    } else {
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(highlighted ? "On" : "Off")
    }
}

/// The queue panel: the whole queue in play order, the current track lit,
/// swipe to remove, drag to reorder, tap to jump.
struct QueueView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editMode: EditMode = .inactive

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Queue")
                    .font(.headline)
                Spacer()
                if !model.queue.isEmpty {
                    Button(editMode.isEditing ? "Done" : "Edit") {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(BitChordStyle.accent)
                }
                Text("^[\(model.queue.count) song](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.queue.isEmpty {
                EmptyStateView(
                    title: "Queue is empty",
                    message: "Songs you play will line up here.",
                    systemImage: "list.bullet"
                )
            } else {
                List {
                    ForEach(Array(model.queue.enumerated()), id: \.offset) { index, track in
                        TrackRow(
                            track: track,
                            isCurrent: index == model.queueIndex,
                            isPlaying: model.playback.isPlaying,
                            showsContextMenu: false
                        ) {
                            model.jumpToQueueItem(at: index)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                model.removeFromQueue(at: index)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) {
                            model.removeFromQueue(at: index)
                        }
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        let finalIndex = destination > from ? destination - 1 : destination
                        model.moveQueueItem(from: from, to: finalIndex)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
            }
        }
    }
}

/// Full-bleed blurred artwork behind the player — the static cousin of
/// Android's artwork-palette mesh gradient.
private struct PlayerBackdrop: View {
    let url: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let url = ArtworkURL.upgraded(url, target: 360), let imageURL = URL(string: url) {
                    AsyncImage(url: imageURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                                .blur(radius: 70)
                                .saturation(1.4)
                        }
                    }
                } else {
                    BitChordStyle.brandGradient.opacity(0.5)
                }
                Color.black.opacity(0.42)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .secondaryLabel
        view.activeTintColor = UIColor(red: 0.980, green: 0.176, blue: 0.282, alpha: 1)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
