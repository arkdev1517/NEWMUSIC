import SwiftUI

struct BitChordRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = AppTab.home
    @State private var showingPartyInvite = false

    var body: some View {
        Group {
            if model.settings.onboardingComplete {
                mainTabs
            } else {
                OnboardingView()
            }
        }
        .preferredColorScheme(colorScheme)
        .onOpenURL { url in
            if model.listenTogether.openInvite(url) {
                showingPartyInvite = true
            }
        }
        .alert(
            "BitChord",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.dismissNotice() } }
            )
        ) {
            Button("OK", role: .cancel) { model.dismissNotice() }
        } message: {
            Text(model.notice ?? "")
        }
        .task { await model.listenTogether.restoreSavedParty() }
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .miniPlayerInset()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)
            ExploreView()
                .miniPlayerInset()
                .tabItem { Label("Explore", systemImage: "safari") }
                .tag(AppTab.explore)
            LibraryView()
                .miniPlayerInset()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)
            SearchView()
                .miniPlayerInset()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
        }
        .tint(BitChordStyle.accent)
        .sheet(isPresented: $model.showingPlayer) {
            PlayerView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // "Go to artist / album" from any row or menu lands here.
        .sheet(item: $model.presentedRoute) { route in
            NavigationStack {
                BrowseDetailView(route: route)
            }
            .tint(BitChordStyle.accent)
            .presentationDragIndicator(.visible)
        }
        // "Add to playlist" from any context menu lands here.
        .sheet(item: $model.playlistPickerTrack) { track in
            AddToPlaylistSheet(track: track)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showingPartyInvite) {
            NavigationStack {
                ListenTogetherView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingPartyInvite = false }
                        }
                    }
            }
            .tint(BitChordStyle.accent)
        }
    }

    private var colorScheme: ColorScheme? {
        switch model.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppTab: Hashable {
    case home
    case explore
    case library
    case search
}

/// The mini player, pinned above the tab bar.
///
/// It is an inset on each tab's own content and not on the `TabView`: an
/// inset on the `TabView` itself lands on the row the tab bar is drawn
/// in, so the two fight over the same space — the mini player covers the
/// tabs, and there is no way to change the view while a track is playing.
private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if model.playback.currentTrack != nil {
                MiniPlayerView { model.showingPlayer = true }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .background(.bar)
            }
        }
    }
}

private extension View {
    /// The mini player, above the tab bar.
    func miniPlayerInset() -> some View {
        modifier(MiniPlayerInset())
    }
}
