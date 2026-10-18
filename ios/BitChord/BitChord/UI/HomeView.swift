import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [BrowseRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.homeShelves.isEmpty {
                    if model.isHomeLoading {
                        ProgressView("Loading your music")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = model.homeError {
                        RetryStateView(message: error) {
                            Task { await model.loadHome(force: true) }
                        }
                    } else {
                        EmptyStateView(
                            title: "Nothing to show yet",
                            message: "YouTube Music did not return any home shelves. Pull to refresh or try again.",
                            actionTitle: "Try Again",
                            action: { Task { await model.loadHome(force: true) } }
                        )
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(model.homeShelves) { shelf in
                                MusicShelfView(shelf: shelf) { item in
                                    select(item, from: shelf.items)
                                }
                            }
                            if let error = model.homeError {
                                RetryStateView(message: error) {
                                    Task { await model.loadMoreHome() }
                                }
                            }
                            if model.homeContinuation != nil {
                                Button {
                                    Task { await model.loadMoreHome() }
                                } label: {
                                    HStack(spacing: 8) {
                                        if model.isHomeLoading { ProgressView().controlSize(.small) }
                                        Text(model.isHomeLoading ? "Loading more" : "Load more")
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.bordered)
                                .tint(BitChordStyle.accent)
                                .disabled(model.isHomeLoading)
                                .padding(.bottom, 12)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                    }
                    .refreshable { await model.loadHome(force: true) }
                }
            }
            .navigationTitle("Listen now")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SettingsToolbarButton() }
            }
            .navigationDestination(for: BrowseRoute.self) { route in
                BrowseDetailView(route: route)
            }
        }
        .task { await model.loadHome() }
    }

    private func select(_ item: MusicItem, from items: [MusicItem]) {
        if let track = item.track() {
            model.play(track, queue: items.compactMap { $0.track() })
        } else if let route = item.browseRoute() {
            path.append(route)
        }
    }
}
