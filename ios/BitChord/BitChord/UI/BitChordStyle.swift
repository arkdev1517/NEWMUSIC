import SwiftUI
import UIKit

enum BitChordStyle {
    /// Apple Music's signature red, `AccentRed` in the Android theme
    /// (`0xFFFA2D48`) — the one colour the app spends everywhere.
    static let accent = Color(red: 0.980, green: 0.176, blue: 0.282)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)

    static let brandGradient = LinearGradient(
        colors: [Color(red: 0.99, green: 0.35, blue: 0.46), Color(red: 0.96, green: 0.13, blue: 0.24)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func categoryColor(_ raw: UInt32?) -> Color {
        guard let raw else { return accent }
        let value = raw & 0x00FF_FFFF
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}

struct ArtworkView: View {
    let url: String?
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 10

    var body: some View {
        Group {
            if let url, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        fallback
                    case .empty:
                        fallback.overlay { ProgressView().controlSize(.small).tint(.white.opacity(0.8)) }
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(BitChordStyle.brandGradient)
            .overlay {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
            }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    var systemImage = "music.note.list"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 35, weight: .light))
                .foregroundStyle(BitChordStyle.accent)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(BitChordStyle.accent)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 42)
    }
}

struct RetryStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t load", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(BitChordStyle.accent)
        }
        .padding(.vertical, 22)
    }
}

struct ShelfHeader: View {
    let title: String
    var subtitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct TrackRow: View {
    let track: MusicTrack
    var isCurrent = false
    var isPlaying = false
    /// Rows get the song-actions context menu unless the host supplies its
    /// own (the imported-files list adds its file-removal menu instead).
    var showsContextMenu = true
    var currentPlaylistID: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ArtworkView(url: track.artworkURL, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.subheadline.weight(isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? BitChordStyle.accent : .primary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                DownloadStatusView(track: track)
                if isCurrent && isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(BitChordStyle.accent)
                        .accessibilityLabel("Playing")
                } else if let duration = track.durationText {
                    Text(duration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(track.title) by \(track.artist)")
        .contextMenu {
            if showsContextMenu {
                TrackActionsMenu(track: track, currentPlaylistID: currentPlaylistID)
            }
        }
    }
}

struct MusicItemCard: View {
    let item: MusicItem
    let action: () -> Void

    var body: some View {
        Group {
            if !item.isPlayable, let route = item.browseRoute() {
                NavigationLink(value: route) { cardContent }
                    .buttonStyle(.plain)
            } else {
                Button(action: action) { cardContent }
                    .buttonStyle(.plain)
            }
        }
        .accessibilityLabel("\(item.title)\(item.subtitle.isEmpty ? "" : ", \(item.subtitle)")")
        .contextMenu {
            if let track = item.track() {
                TrackActionsMenu(track: track)
            } else if item.browseID != nil {
                BrowseActionsMenu(item: item)
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(url: item.artworkURL, size: 148, cornerRadius: 13)
            Text(item.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 148, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct MusicShelfView: View {
    let shelf: MusicShelf
    let onSelect: (MusicItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: shelf.title, subtitle: shelf.subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.items) { item in
                        MusicItemCard(item: item) { onSelect(item) }
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.vertical, 8)
    }
}

struct SettingsToolbarButton: View {
    var body: some View {
        NavigationLink {
            SettingsView()
        } label: {
            Image(systemName: "gearshape")
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
        }
        .accessibilityLabel("Settings")
    }
}

/// YouTube serves artwork at the size named in the URL (`w60-h60`), which is
/// far too small for headers and the player. Asking for a bigger rendition
/// is a URL rewrite, the same one the Android image loader performs.
enum ArtworkURL {
    static func upgraded(_ raw: String?, target: Int = 540) -> String? {
        guard let raw else { return nil }
        let pattern = try! NSRegularExpression(pattern: #"w\d+-h\d+"#)
        let range = NSRange(raw.startIndex..., in: raw)
        guard pattern.firstMatch(in: raw, range: range) != nil else { return raw }
        return pattern.stringByReplacingMatches(in: raw, range: range, withTemplate: "w\(target)-h\(target)")
    }
}

/// The small download state glyph rows carry: a spinner of progress while
/// the bytes move, a filled arrow once the track lives on the device.
struct DownloadStatusView: View {
    let track: MusicTrack
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let progress = model.downloads.progress[track.id] {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .frame(width: 16, height: 16)
                .accessibilityLabel("Downloading, \(Int(progress * 100)) percent")
        } else if model.downloads.isDownloaded(track) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Downloaded")
        }
    }
}

/// The song actions — Android's `SongActionsSheet` as a menu. Used inside
/// `.contextMenu` on rows and cards, and from the player's overflow menu,
/// so every surface offers the same verbs for a track.
struct TrackActionsMenu: View {
    let track: MusicTrack
    /// Set when the row lives inside that playlist's own page.
    var currentPlaylistID: String? = nil
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.playTrackNext(track)
        } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }

        Button {
            model.addToQueue(track)
        } label: { Label("Add to queue", systemImage: "text.append") }

        if track.videoID != nil {
            Button {
                model.startRadio(track)
            } label: { Label("Start radio", systemImage: "dot.radiowaves.left.and.right") }
        }

        Divider()

        if track.videoID != nil {
            Button {
                model.toggleLike(track)
            } label: {
                Label(
                    model.likedTrackIDs.contains(track.id) ? "Remove from Liked Music" : "Like",
                    systemImage: model.likedTrackIDs.contains(track.id) ? "heart.fill" : "heart"
                )
            }
            Button {
                model.toggleDislike(track)
            } label: {
                Label(
                    model.dislikedTrackIDs.contains(track.id) ? "Undo dislike" : "Dislike",
                    systemImage: model.dislikedTrackIDs.contains(track.id) ? "hand.thumbsdown.fill" : "hand.thumbsdown"
                )
            }
        }

        Button {
            model.playlistPickerTrack = track
        } label: { Label("Add to playlist", systemImage: "text.badge.plus") }

        if let currentPlaylistID, track.setVideoID != nil {
            Button(role: .destructive) {
                model.removeTrackFromAccountPlaylist(track, playlistID: currentPlaylistID)
            } label: { Label("Remove from this playlist", systemImage: "text.badge.minus") }
        }

        Divider()

        if track.videoID != nil {
            if model.downloads.isDownloading(track) {
                Button(role: .destructive) {
                    model.downloads.cancel(track)
                } label: { Label("Cancel download", systemImage: "xmark.circle") }
            } else if model.downloads.isDownloaded(track) {
                Button(role: .destructive) {
                    model.deleteDownload(track)
                } label: { Label("Delete download", systemImage: "trash") }
            } else {
                Button {
                    model.downloadTrack(track)
                } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }

        Button {
            model.presentArtist(for: track)
        } label: { Label("Go to artist", systemImage: "person.crop.circle") }

        if track.albumBrowseID != nil {
            Button {
                model.presentAlbum(for: track)
            } label: { Label("Go to album", systemImage: "opticaldisc") }
        }

        if let url = track.shareURL {
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// The collection-card actions (Android's `BrowseActionsSheet`).
struct BrowseActionsMenu: View {
    let item: MusicItem
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            model.playCollection(item, shuffled: false)
        } label: { Label("Play", systemImage: "play.fill") }

        Button {
            model.playCollection(item, shuffled: true)
        } label: { Label("Shuffle play", systemImage: "shuffle") }

        if let url = shareURL {
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var shareURL: URL? {
        guard let browseID = item.browseID else { return nil }
        switch item.kind {
        case .playlist:
            return URL(string: "https://music.youtube.com/playlist?list=\(browseID.removingVLPrefix)")
        case .artist:
            return URL(string: "https://music.youtube.com/channel/\(browseID)")
        default:
            return URL(string: "https://music.youtube.com/browse/\(browseID)")
        }
    }
}
