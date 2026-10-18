import SwiftUI

struct BrowseDetailView: View {
    let route: BrowseRoute

    @EnvironmentObject private var model: AppModel
    @State private var page: MusicBrowsePage?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                collectionHeader(page)

                if !page.tracks.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(page.tracks) { track in
                            TrackRow(
                                track: track,
                                isCurrent: model.playback.currentTrack?.id == track.id,
                                isPlaying: model.playback.isPlaying
                            ) {
                                model.play(track, queue: page.tracks)
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

    private func collectionHeader(_ page: MusicBrowsePage) -> some View {
        HStack(spacing: 16) {
            ArtworkView(url: page.artworkURL, size: 112, cornerRadius: 16)
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
                    Button {
                        guard let first = page.tracks.first else { return }
                        model.play(first, queue: page.tracks)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BitChordStyle.accent)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(BitChordStyle.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
