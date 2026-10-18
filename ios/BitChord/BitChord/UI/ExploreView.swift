import SwiftUI

struct ExploreView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if model.exploreSections.isEmpty {
                    if model.isExploreLoading {
                        ProgressView("Loading genres and moods")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = model.exploreError {
                        RetryStateView(message: error) {
                            Task { await model.loadExplore(force: true) }
                        }
                    } else {
                        EmptyStateView(
                            title: "No categories available",
                            message: "YouTube Music did not return any moods or genres.",
                            actionTitle: "Try Again",
                            action: { Task { await model.loadExplore(force: true) } }
                        )
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(model.exploreSections) { section in
                                VStack(alignment: .leading, spacing: 12) {
                                    ShelfHeader(title: section.title)
                                    LazyVGrid(columns: columns, spacing: 12) {
                                        ForEach(section.categories) { category in
                                            NavigationLink(value: category) {
                                                CategoryTile(category: category)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                    .refreshable { await model.loadExplore(force: true) }
                }
            }
            .navigationTitle("Explore")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SettingsToolbarButton() }
            }
            .navigationDestination(for: MusicCategory.self) { category in
                CategoryDetailView(category: category)
            }
        }
        .task { await model.loadExplore() }
    }
}

private struct CategoryTile: View {
    let category: MusicCategory

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [BitChordStyle.categoryColor(category.stripeColor).opacity(0.72), BitChordStyle.categoryColor(category.stripeColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            HStack {
                Text(category.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(15)
        }
        .frame(height: 98)
        .accessibilityElement(children: .combine)
    }
}
