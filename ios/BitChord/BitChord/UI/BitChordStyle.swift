import SwiftUI
import UIKit

enum BitChordStyle {
    static let accent = Color(red: 0.98, green: 0.23, blue: 0.39)
    static let secondaryAccent = Color(red: 0.72, green: 0.27, blue: 0.76)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)

    static let brandGradient = LinearGradient(
        colors: [Color(red: 0.98, green: 0.36, blue: 0.46), Color(red: 0.96, green: 0.13, blue: 0.24)],
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
                if isCurrent && isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(BitChordStyle.accent)
                        .accessibilityLabel("Playing")
                } else if let duration = track.durationText {
                    Text(duration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "play.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BitChordStyle.accent)
                    .padding(.leading, 4)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(track.title) by \(track.artist)")
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
