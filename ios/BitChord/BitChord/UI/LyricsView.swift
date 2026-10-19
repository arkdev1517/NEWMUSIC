import SwiftUI

/// The lyrics panel of the now-playing screen — Android's
/// `PlayerLyrics` / `SyncedLyricsPanel` reduced to its observable behaviour:
///
/// - the active line is enlarged and lit, neighbours dim (and, past a couple
///   of lines, blur — Android's `lyricsBlur`);
/// - word-synced lines light word by word;
/// - instrumental gaps show as three dots;
/// - tapping a line seeks to it;
/// - the panel follows playback, and stops fighting the user for a few
///   seconds after they drag it themselves;
/// - a small offset stepper writes the same `lyricsOffsetMs` setting the
///   Android offset sheet edits;
/// - with synced lyrics switched off in settings, lines show plain.
struct LyricsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var followBlockedUntil = Date.distantPast

    var body: some View {
        Group {
            if model.isLyricsLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding lyrics…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics = model.currentLyrics {
                content(lyrics)
            } else {
                EmptyStateView(
                    title: "No lyrics found",
                    message: "No provider has lyrics for this song.",
                    systemImage: "quote.bubble"
                )
            }
        }
    }

    @ViewBuilder
    private func content(_ lyrics: TrackLyrics) -> some View {
        let synced = lyrics.isSynced && model.settings.syncedLyrics
        let nowMs = Int(model.playback.position * 1000) + model.settings.lyricsOffsetMs
        let activeIndex = synced ? activeLineIndex(in: lyrics.lines, nowMs: nowMs) : nil

        VStack(spacing: 8) {
            header(lyrics)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            lineView(line, index: index, activeIndex: activeIndex, nowMs: nowMs)
                                .id(index)
                                .onTapGesture {
                                    guard lyrics.isSynced else { return }
                                    let target = Double(line.timeMs - model.settings.lyricsOffsetMs) / 1000
                                    model.seek(to: max(0, target))
                                }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 24)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8).onChanged { _ in
                        followBlockedUntil = Date().addingTimeInterval(5)
                    }
                )
                .onChange(of: activeIndex) { _, newIndex in
                    guard let newIndex, Date() > followBlockedUntil else { return }
                    withAnimation(.easeInOut(duration: 0.45)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.92),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private func header(_ lyrics: TrackLyrics) -> some View {
        HStack(spacing: 10) {
            Text(lyrics.source.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if lyrics.isSynced {
                Text(lyrics.lines.contains(where: \.isWordSynced) ? "Word-synced" : "Synced")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(BitChordStyle.accent.opacity(0.18), in: Capsule())
                    .foregroundStyle(BitChordStyle.accent)
            }
            Spacer()
            if lyrics.isSynced {
                // Lyrics offset: nudge every timestamp, ±0.25s per tap.
                HStack(spacing: 4) {
                    Button {
                        model.settings.lyricsOffsetMs -= 250
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    Text(offsetLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44)
                    Button {
                        model.settings.lyricsOffsetMs += 250
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Lyrics timing offset")
            }
        }
    }

    private var offsetLabel: String {
        let ms = model.settings.lyricsOffsetMs
        if ms == 0 { return "±0.0s" }
        let sign = ms > 0 ? "+" : "−"
        return "\(sign)\(String(format: "%.2f", abs(Double(ms)) / 1000))s"
    }

    @ViewBuilder
    private func lineView(_ line: LyricLine, index: Int, activeIndex: Int?, nowMs: Int) -> some View {
        let isActive = index == activeIndex
        let distance = activeIndex.map { abs($0 - index) } ?? 0
        Group {
            if line.isGap {
                Text("• • •")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isActive ? BitChordStyle.accent : Color.secondary)
            } else if isActive, line.isWordSynced {
                wordSyncedLine(line, nowMs: nowMs)
            } else {
                Text(line.text)
                    .font(isActive ? .title3.weight(.bold) : .body.weight(.semibold))
                    .foregroundStyle(isActive ? Color.primary : Color.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(activeIndex == nil || isActive ? 1 : max(0.35, 1 - Double(distance) * 0.16))
        .blur(radius: activeIndex != nil && distance > 2 ? 1.1 : 0)
        .animation(.easeInOut(duration: 0.3), value: isActive)
    }

    private func wordSyncedLine(_ line: LyricLine, nowMs: Int) -> some View {
        // Words already sung are lit, the rest dim — the Apple-Music-style
        // fill the Android panel renders per syllable, at word granularity.
        var rendered = AttributedString()
        for (index, word) in line.words.enumerated() {
            var part = AttributedString(word.text)
            part.foregroundColor = nowMs >= word.startMs ? BitChordStyle.accent : Color.secondary
            rendered += part
            if index + 1 < line.words.count {
                rendered += AttributedString(" ")
            }
        }
        return Text(rendered)
            .font(.title3.weight(.bold))
    }

    private func activeLineIndex(in lines: [LyricLine], nowMs: Int) -> Int? {
        lines.lastIndex { $0.timeMs <= nowMs }
    }
}
