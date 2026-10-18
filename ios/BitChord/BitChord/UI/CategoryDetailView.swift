import SwiftUI

struct CategoryDetailView: View {
    let category: MusicCategory

    @EnvironmentObject private var model: AppModel
    @State private var shelves: [MusicShelf] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && shelves.isEmpty {
                ProgressView("Loading \(category.title)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, shelves.isEmpty {
                RetryStateView(message: errorMessage) { Task { await load() } }
            } else if shelves.isEmpty {
                EmptyStateView(
                    title: "No music found",
                    message: "YouTube Music returned no shelves for \(category.title).",
                    actionTitle: "Try Again",
                    action: { Task { await load() } }
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(shelves) { shelf in
                            MusicShelfView(shelf: shelf) { item in select(item, from: shelf.items) }
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: BrowseRoute.self) { route in
            BrowseDetailView(route: route)
        }
        .task(id: category.id) { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            shelves = try await model.fetchCategoryShelves(category)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func select(_ item: MusicItem, from items: [MusicItem]) {
        guard let track = item.track() else { return }
        model.play(track, queue: items.compactMap { $0.track() })
    }
}
