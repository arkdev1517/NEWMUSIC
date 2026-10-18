import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var didSubmit = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                sourcePicker
                filterPicker
                content
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SettingsToolbarButton() }
            }
            .navigationDestination(for: BrowseRoute.self) { route in
                BrowseDetailView(route: route)
            }
        }
        .tint(BitChordStyle.accent)
        .onChange(of: query) { _, value in
            model.searchQuery = value
            didSubmit = false
        }
        .onChange(of: model.searchSource) { _, _ in
            let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
            didSubmit = !clean.isEmpty
            if didSubmit { Task { await model.submitSearch(clean) } }
        }
        .task(id: query) {
            let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard clean.count >= 2, !didSubmit else { return }
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            await model.loadSearchSuggestions(for: clean)
        }
    }

    private var sourcePicker: some View {
        Picker("Search source", selection: Binding(
            get: { model.searchSource },
            set: { model.setSearchSource($0) }
        )) {
            ForEach(SearchSource.allCases) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Songs, artists, albums", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($queryFocused)
                .onSubmit { submit(query) }
                .accessibilityLabel(model.searchSource == .localMusic ? "Search imported audio" : "Search YouTube Music")
            if !query.isEmpty {
                Button {
                    query = ""
                    model.clearSearchResults()
                    queryFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
            Button {
                submit(query)
            } label: {
                Image(systemName: "arrow.forward.circle.fill")
                    .font(.title2)
                    .foregroundStyle(BitChordStyle.accent)
            }
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Search")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(BitChordStyle.cardBackground, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var filterPicker: some View {
        if model.searchSource == .youtubeMusic {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchFilter.allCases) { filter in
                        Button {
                            if model.searchFilter != filter {
                                didSubmit = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                Task { await model.searchForFilter(filter) }
                            }
                        } label: {
                            Text(filter.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(model.searchFilter == filter ? .white : .primary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .background {
                                    Capsule().fill(model.searchFilter == filter ? BitChordStyle.accent : BitChordStyle.cardBackground)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if didSubmit {
            results
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            historyContent
        } else if !model.searchSuggestions.isEmpty {
            suggestionsContent
        } else {
            EmptyStateView(
                title: "Keep typing to search",
                message: model.searchSource == .localMusic
                    ? "Press Search to find matching tracks imported into BitChord."
                    : "Search suggestions come from YouTube Music. Press Search to load matching music.",
                systemImage: "text.magnifyingglass"
            )
        }
    }

    @ViewBuilder
    private var results: some View {
        if model.searchSource == .localMusic {
            localResults
        } else if model.searchItems.isEmpty && model.isSearchLoading {
            ProgressView("Searching YouTube Music")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.searchError, model.searchItems.isEmpty {
            RetryStateView(message: error) { submit(query) }
                .frame(maxHeight: .infinity)
        } else if model.searchItems.isEmpty {
            EmptyStateView(
                title: "No results found",
                message: "Try another search or choose a different result type.",
                systemImage: "magnifyingglass"
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.searchItems) { item in
                        searchResult(item)
                            .padding(.horizontal, 16)
                    }
                    if let error = model.searchError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    if model.searchContinuation != nil {
                        Button {
                            Task { await model.loadMoreSearch() }
                        } label: {
                            HStack(spacing: 8) {
                                if model.isSearchLoading { ProgressView().controlSize(.small) }
                                Text(model.isSearchLoading ? "Loading more" : "Load more results")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                        }
                        .buttonStyle(.bordered)
                        .tint(BitChordStyle.accent)
                        .disabled(model.isSearchLoading)
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder
    private var localResults: some View {
        if model.localSearchResults.isEmpty {
            EmptyStateView(
                title: "No imported tracks found",
                message: "Search only includes audio files you imported into BitChord from Files.",
                systemImage: "music.note.list"
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.localSearchResults) { track in
                        TrackRow(
                            track: track,
                            isCurrent: model.playback.currentTrack?.id == track.id,
                            isPlaying: model.playback.isPlaying
                        ) {
                            model.play(track, queue: model.localSearchResults)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
        }
    }

    private var historyContent: some View {
        Group {
            if model.searchHistory.isEmpty {
                EmptyStateView(
                    title: "Search music",
                    message: "Find songs, videos, albums, artists and playlists from YouTube Music.",
                    systemImage: "magnifyingglass"
                )
            } else {
                List {
                    Section("Recent searches") {
                        ForEach(model.searchHistory) { entry in
                            Button {
                                query = entry.query
                                submit(entry.query)
                            } label: {
                                Label(entry.query, systemImage: "clock.arrow.circlepath")
                                    .foregroundStyle(.primary)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    model.removeSearchHistory(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var suggestionsContent: some View {
        List {
            Section("Suggestions") {
                ForEach(model.searchSuggestions, id: \.self) { suggestion in
                    Button {
                        query = suggestion
                        submit(suggestion)
                    } label: {
                        Label(suggestion, systemImage: "magnifyingglass")
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func searchResult(_ item: MusicItem) -> some View {
        if let track = item.track() {
            TrackRow(
                track: track,
                isCurrent: model.playback.currentTrack?.id == track.id,
                isPlaying: model.playback.isPlaying
            ) {
                model.play(track, queue: model.searchItems.compactMap { $0.track() })
            }
        } else if let route = item.browseRoute() {
            NavigationLink(value: route) {
                HStack(spacing: 13) {
                    ArtworkView(url: item.artworkURL, size: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                        Text(item.subtitle.isEmpty ? item.kind.rawValue.capitalized : item.subtitle)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func submit(_ value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        didSubmit = true
        queryFocused = false
        Task { await model.submitSearch(clean) }
    }
}
