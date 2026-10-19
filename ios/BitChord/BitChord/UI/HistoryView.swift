import SwiftUI

/// Listening history — Android's `HistoryScreen`. Two sources, one screen:
/// what this device heard (the on-device recorder, works signed-out) and
/// the account's YouTube Music history page when signed in.
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var source: Source = .device
    @State private var accountTracks: [MusicTrack] = []
    @State private var accountError: String?
    @State private var isLoadingAccount = false
    @State private var showingClearConfirm = false

    private enum Source: String, CaseIterable, Identifiable {
        case device
        case account

        var id: String { rawValue }
        var title: String {
            switch self {
            case .device: "On this iPhone"
            case .account: "YouTube Music"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isYouTubeSignedIn {
                Picker("History source", selection: $source) {
                    ForEach(Source.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }

            switch effectiveSource {
            case .device:
                deviceHistory
            case .account:
                accountHistory
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if effectiveSource == .device, !model.recorder.events.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", role: .destructive) {
                        showingClearConfirm = true
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .alert("Clear listening history?", isPresented: $showingClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                model.recorder.clearHistory()
                model.localAudio.clearHistory()
            }
        } message: {
            Text("This removes this iPhone's listening history and the statistics built from it. Your YouTube Music history is untouched.")
        }
        .task(id: model.isYouTubeSignedIn) {
            if model.isYouTubeSignedIn { await loadAccount() }
        }
    }

    private var effectiveSource: Source {
        model.isYouTubeSignedIn ? source : .device
    }

    private var deviceHistory: some View {
        Group {
            if model.recorder.events.isEmpty {
                EmptyStateView(
                    title: "Nothing played yet",
                    message: "Songs you play on this iPhone will appear here, most recent first.",
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                List {
                    ForEach(model.recorder.recentTracks) { track in
                        TrackRow(
                            track: track,
                            isCurrent: model.playback.currentTrack?.id == track.id,
                            isPlaying: model.playback.isPlaying
                        ) {
                            model.play(track, queue: model.recorder.recentTracks)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var accountHistory: some View {
        Group {
            if isLoadingAccount && accountTracks.isEmpty {
                ProgressView("Loading your history")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let accountError, accountTracks.isEmpty {
                RetryStateView(message: accountError) { Task { await loadAccount() } }
            } else if accountTracks.isEmpty {
                EmptyStateView(
                    title: "No account history",
                    message: "YouTube Music returned no recent listens for this account.",
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                List {
                    ForEach(accountTracks) { track in
                        TrackRow(
                            track: track,
                            isCurrent: model.playback.currentTrack?.id == track.id,
                            isPlaying: model.playback.isPlaying
                        ) {
                            model.play(track, queue: accountTracks)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .refreshable { await loadAccount() }
            }
        }
    }

    private func loadAccount() async {
        guard !isLoadingAccount else { return }
        isLoadingAccount = true
        accountError = nil
        defer { isLoadingAccount = false }
        do {
            accountTracks = try await model.fetchAccountHistory()
        } catch {
            accountError = error.localizedDescription
        }
    }
}
