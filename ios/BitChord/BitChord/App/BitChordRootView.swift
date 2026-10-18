import SwiftUI

struct BitChordRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab = AppTab.home
    @State private var showingPartyInvite = false

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)
            ExploreView()
                .tabItem { Label("Explore", systemImage: "safari") }
                .tag(AppTab.explore)
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
        }
        .tint(BitChordStyle.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.playback.currentTrack != nil {
                MiniPlayerView { model.showingPlayer = true }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .background(.bar)
            }
        }
        .sheet(isPresented: $model.showingPlayer) {
            PlayerView()
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
        .preferredColorScheme(colorScheme)
        .task { await model.listenTogether.restoreSavedParty() }
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
