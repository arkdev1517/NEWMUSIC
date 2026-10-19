import SwiftUI

/// Listening statistics — Android's Replay (`ReplayScreen` over
/// `ListeningStats`) in its informational core: minutes listened, songs
/// played, and the top tracks / artists / albums for this month, this
/// year, or all time, computed from the same on-device recorder. Android's
/// shareable poster/stories rendering on top of the same numbers is a
/// documented remaining difference.
struct StatsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var period: ListeningRecorder.Period = .month

    var body: some View {
        let summary = model.recorder.summary(period: period)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Picker("Period", selection: $period) {
                    ForEach(ListeningRecorder.Period.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                if summary.totalPlays == 0 {
                    EmptyStateView(
                        title: "No listening yet",
                        message: "Play some music and your \(period == .month ? "monthly" : period == .year ? "yearly" : "all-time") highlights will build up here. A song counts once you've heard a good stretch of it.",
                        systemImage: "chart.bar"
                    )
                } else {
                    headline(summary)
                    rankedSection("Top songs", entries: summary.topTracks) { entry in
                        if let track = entry.track {
                            model.play(track, queue: summary.topTracks.compactMap(\.track))
                        }
                    }
                    rankedSection("Top artists", entries: summary.topArtists) { entry in
                        presentArtist(named: entry.title)
                    }
                    rankedSection("Top albums", entries: summary.topAlbums) { _ in }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .navigationTitle("Your Replay")
        .navigationBarTitleDisplayMode(.large)
    }

    private func headline(_ summary: ListeningRecorder.Summary) -> some View {
        HStack(spacing: 12) {
            statCard(
                value: minutesLabel(summary.totalSeconds),
                label: "listened"
            )
            statCard(
                value: "\(summary.totalPlays)",
                label: summary.totalPlays == 1 ? "song played" : "songs played"
            )
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 30, weight: .heavy))
                .foregroundStyle(BitChordStyle.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(BitChordStyle.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func rankedSection(
        _ title: String,
        entries: [ListeningRecorder.RankedEntry],
        action: @escaping (ListeningRecorder.RankedEntry) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: title)
            if entries.isEmpty {
                Text("Nothing to rank yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        action(entry)
                    } label: {
                        HStack(spacing: 13) {
                            Text("\(index + 1)")
                                .font(.subheadline.weight(.heavy).monospacedDigit())
                                .foregroundStyle(index < 3 ? BitChordStyle.accent : Color.secondary)
                                .frame(width: 24)
                            ArtworkView(url: entry.artworkURL, size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !entry.subtitle.isEmpty {
                                    Text(entry.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            Text("^[\(entry.plays) play](inflect: true)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func minutesLabel(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 60 {
            let hours = Double(minutes) / 60
            return hours >= 10 ? "\(Int(hours.rounded())) hrs" : "\(String(format: "%.1f", hours)) hrs"
        }
        return "\(minutes) min"
    }

    private func presentArtist(named name: String) {
        Task {
            let probe = MusicTrack(videoID: nil, title: "", artist: name, artworkURL: nil, localFileName: nil)
            if let route = await model.artistRoute(for: probe) {
                model.presentedRoute = route
            } else {
                model.notice = "No artist page found for \(name)."
            }
        }
    }
}
