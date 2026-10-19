import SwiftUI

/// An album / artist / playlist page — Android's `DetailScreen`: header with
/// Play + Shuffle, the account verbs that belong to the page kind (Save for
/// releases, Subscribe for artists), a description when the page carries
/// one, sortable track rows with the full song-actions menu, and
/// download-everything for track collections.
struct BrowseDetailView: View {
    let route: BrowseRoute

    @EnvironmentObject private var model: AppModel
    @State private var page: MusicBrowsePage?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @AppStorage private var sortRaw: String

    private enum TrackSort: String, CaseIterable {
        case `default` = "default"
        case title
        case artist
        case duration

        var title: String {
            switch self {
            case .default: "Default order"
            case .title: "Title"
            case .artist: "Artist"
            case .duration: "Duration"
            }
        }
    }

    init(route: BrowseRoute) {
        self.route = route
        _sortRaw = AppStorage(wrappedValue: TrackSort.default.rawValue, "detail-song-sort-\(route.browseID)")
    }

    private var sort: TrackSort { TrackSort(rawValue: sortRaw) ?? .default }

    var body: some View {
        Group {
            if isLoading && page == nil {
                ProgressView("Loading \(route.title)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if page == nil, let errorMessage {
                RetryStateView(message: errorMessage) { Task { await load() } }
            } else if let page {
                pageContent(page)
            } else {
                EmptyStateView(title: "Page unavailable", message: "YouTube Music returned no collection data.")
            }
        }
        .navigationTitle(page?.title ?? route.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: BrowseRoute.self) { nestedRoute in
            BrowseDetailView(route: nestedRoute)
        }
        .task(id: route.id) { await load() }
    }

    @ViewBuilder
    private func pageContent(_ page: MusicBrowsePage) -> some View {
        let tracks = sortedTracks(page)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                collectionHeader(page)

                if !page.pageDescription.isEmpty {
                    Text(page.pageDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !tracks.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(tracks) { track in
                            TrackRow(
                                track: track,
                                isCurrent: model.playback.currentTrack?.id == track.id,
                                isPlaying: model.playback.isPlaying,
                                currentPlaylistID: route.kind == .playlist ? route.browseID : nil
                            ) {
                                model.play(track, queue: tracks)
                            }
                        }
                    }
                } else if !page.items.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                        ForEach(page.items) { item in
                            MusicItemCard(item: item) { select(item, from: page.items) }
                        }
                    }
                } else {
                    EmptyStateView(
                        title: "No items in this collection",
                        message: "YouTube Music did not return any playable rows for this page.",
                        systemImage: "music.note.list"
                    )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                if page.continuation != nil {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack(spacing: 8) {
                            if isLoadingMore { ProgressView().controlSize(.small) }
                            Text(isLoadingMore ? "Loading more" : "Load more")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(BitChordStyle.accent)
                    .disabled(isLoadingMore)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .refreshable { await load() }
    }

    private func sortedTracks(_ page: MusicBrowsePage) -> [MusicTrack] {
        switch sort {
        case .default:
            page.tracks
        case .title:
            page.tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            page.tracks.sorted {
                $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
                    || ($0.artist == $1.artist && $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending)
            }
        case .duration:
            page.tracks.sorted { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }
        }
    }

    private func collectionHeader(_ page: MusicBrowsePage) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                ArtworkView(
                    url: ArtworkURL.upgraded(page.artworkURL, target: 360),
                    size: 112,
                    cornerRadius: route.kind == .artist ? 56 : 16
                )
                VStack(alignment: .leading, spacing: 6) {
                    Text(page.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(3)
                    if !page.subtitle.isEmpty {
                        Text(page.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if !page.tracks.isEmpty {
                        Text("^[\(page.tracks.count) song](inflect: true)\(totalDuration(page.tracks).map { " · \($0)" } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            if !page.tracks.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        guard let first = sortedTracks(page).first else { return }
                        model.play(first, queue: sortedTracks(page))
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BitChordStyle.accent)

                    Button {
                        model.playShuffled(page.tracks)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(BitChordStyle.accent)
                }
            }

            accountActions(page)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(BitChordStyle.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func accountActions(_ page: MusicBrowsePage) -> some View {
        HStack(spacing: 18) {
            if route.kind == .artist {
                let subscribed = page.isSubscribed ?? model.subscribedChannelIDs.contains(route.browseID)
                Button {
                    model.toggleSubscription(channelID: route.browseID)
                } label: {
                    Label(
                        subscribed ? "Subscribed" : "Subscribe",
                        systemImage: subscribed ? "checkmark.circle.fill" : "bell.badge"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(subscribed ? BitChordStyle.accent : Color.primary)
            }

            if let playlistID = page.playlistID, route.kind == .album || route.kind == .playlist {
                let saved = model.savedPlaylistIDs.contains(playlistID)
                Button {
                    model.toggleSaved(playlistID: playlistID)
                } label: {
                    Label(
                        saved ? "Saved" : "Save to library",
                        systemImage: saved ? "bookmark.fill" : "bookmark"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(saved ? BitChordStyle.accent : Color.primary)
            }

            if !page.tracks.isEmpty {
                Button {
                    model.downloadTracks(page.tracks)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)

                Menu {
                    ForEach(TrackSort.allCases, id: \.rawValue) { candidate in
                        Button {
                            sortRaw = candidate.rawValue
                        } label: {
                            Label(candidate.title, systemImage: sort == candidate ? "checkmark" : "arrow.up.arrow.down")
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline.weight(.semibold))
                }
            }

            if let url = shareURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var shareURL: URL? {
        switch route.kind {
        case .playlist:
            URL(string: "https://music.youtube.com/playlist?list=\(route.browseID.removingVLPrefix)")
        case .artist:
            URL(string: "https://music.youtube.com/channel/\(route.browseID)")
        default:
            URL(string: "https://music.youtube.com/browse/\(route.browseID)")
        }
    }

    private func totalDuration(_ tracks: [MusicTrack]) -> String? {
        let seconds = tracks.compactMap(\.durationSeconds).reduce(0, +)
        guard seconds > 0 else { return nil }
        let total = Int(seconds)
        return total >= 3600 ? "\(total / 3600)h \((total % 3600) / 60)m" : "\(total / 60)m"
    }

    private func select(_ item: MusicItem, from items: [MusicItem]) {
        guard let track = item.track() else { return }
        model.play(track, queue: items.compactMap { $0.track() })
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            page = try await model.fetchBrowsePage(route)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !isLoadingMore, let current = page, let token = current.continuation else { return }
        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }
        do {
            let next = try await model.fetchMoreBrowsePage(route, token: token)
            guard var updated = page else { return }
            updated.tracks.append(contentsOf: next.tracks)
            updated.items.append(contentsOf: next.items)
            updated.continuation = next.continuation
            page = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
