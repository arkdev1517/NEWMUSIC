import SwiftUI
import UniformTypeIdentifiers

/// Settings — the iOS mirror of Android's `SettingsSheet`, section for
/// section where the behaviour exists on iOS: account, Listen Together,
/// per-network quality, downloads, playback, lyrics, scrobbling,
/// appearance, data and backup.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSignIn = false
    @State private var confirmation: SettingsConfirmation?
    @State private var backupFile: URL?
    @State private var showingBackupImporter = false

    var body: some View {
        Form {
            accountSection
            listenTogetherSection
            playbackSection
            qualitySection
            downloadsSection
            lyricsSection
            scrobblingSection
            appearanceSection
            dataSection
            backupSection
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .tint(BitChordStyle.accent)
        .sheet(isPresented: $showingSignIn) {
            YouTubeSignInView { cookie in model.saveYouTubeSession(cookie: cookie) }
        }
        .fileImporter(
            isPresented: $showingBackupImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleBackupImport(result)
        }
        .alert(
            confirmation?.title ?? "BitChord",
            isPresented: Binding(
                get: { confirmation != nil },
                set: { if !$0 { confirmation = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { confirmation = nil }
            switch confirmation {
            case .some(.signOut):
                Button("Sign Out", role: .destructive) {
                    model.signOutYouTube()
                    YouTubeWebSession.clearCookies()
                    confirmation = nil
                }
            case .some(.clearHistory):
                Button("Clear", role: .destructive) {
                    model.clearSearchHistory()
                    confirmation = nil
                }
            case .some(.clearListening):
                Button("Clear", role: .destructive) {
                    model.recorder.clearHistory()
                    model.localAudio.clearHistory()
                    confirmation = nil
                }
            case .some(.clearDownloads):
                Button("Delete All", role: .destructive) {
                    model.downloads.deleteAll()
                    confirmation = nil
                }
            case nil:
                EmptyView()
            }
        } message: {
            Text(confirmation?.message ?? "")
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section("YouTube Music") {
            HStack(spacing: 12) {
                if let profile = model.accountProfile, let artwork = profile.artworkURL {
                    ArtworkView(url: artwork, size: 44, cornerRadius: 22)
                } else {
                    Image(systemName: model.isYouTubeSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.title)
                        .foregroundStyle(BitChordStyle.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.accountProfile?.name ?? (model.isYouTubeSignedIn ? "Account connected" : "Not connected"))
                        .font(.subheadline.weight(.semibold))
                    Text(
                        model.accountProfile?.email.isEmpty == false
                            ? (model.accountProfile?.email ?? "")
                            : (model.isYouTubeSignedIn
                                ? "Your library and account actions are available."
                                : "Connect to browse your account library and save likes.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)

            HStack {
                Text("Your name")
                Spacer()
                TextField("Name for Listen Together", text: Binding(
                    get: { model.settings.displayName },
                    set: { model.settings.displayName = $0 }
                ))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .frame(maxWidth: 180)
            }

            Button {
                showingSignIn = true
            } label: {
                Label(model.isYouTubeSignedIn ? "Change account" : "Connect YouTube Music", systemImage: "person.badge.key")
            }
            if model.isYouTubeSignedIn {
                Button(role: .destructive) {
                    confirmation = .signOut
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            Text("Sign-in uses YouTube Music in a secure Apple web view. BitChord stores the session cookie in Keychain; Google may restrict embedded sign-in on some accounts or devices.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var listenTogetherSection: some View {
        Section("Listen Together") {
            NavigationLink {
                ListenTogetherView()
            } label: {
                Label("Party controls", systemImage: "person.3.sequence.fill")
            }
            Text("Create or join a synchronized room using BitChord’s real-time party service.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Playback

    private var playbackSection: some View {
        Section("Playback") {
            Toggle("Autoplay", isOn: Binding(
                get: { model.settings.autoplay },
                set: { model.settings.autoplay = $0 }
            ))
            Picker("Playback speed", selection: Binding(
                get: { model.settings.playbackSpeed },
                set: { model.setPlaybackSpeed($0) }
            )) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                    Text(speed == 1 ? "Normal" : "\(trimmed(speed))×").tag(speed)
                }
            }
            Stepper(value: Binding(
                get: { model.settings.crossfadeSeconds },
                set: { model.settings.crossfadeSeconds = $0 }
            ), in: 0...12) {
                LabeledContent(
                    "Crossfade",
                    value: model.settings.crossfadeSeconds == 0 ? "Off" : "\(model.settings.crossfadeSeconds)s"
                )
            }
            Toggle("Stats for nerds", isOn: Binding(
                get: { model.settings.showNerdStats },
                set: { model.settings.showNerdStats = $0 }
            ))
            Text("Crossfade fades each song out into the next. Android overlaps the two tracks sample-exactly; AVPlayer offers no overlap, so iOS fades at the boundary instead.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Quality

    private var qualitySection: some View {
        Section("Audio quality") {
            qualityPicker("On Wi-Fi", selection: Binding(
                get: { model.settings.audioQualityWiFi },
                set: { model.settings.audioQualityWiFi = $0 }
            ))
            qualityPicker("On mobile data", selection: Binding(
                get: { model.settings.audioQualityCellular },
                set: { model.settings.audioQualityCellular = $0 }
            ))
            LabeledContent("Now using") {
                Text(model.settings.effectiveQuality(metered: model.network.isMetered).title)
                    .foregroundStyle(.secondary)
            }
            Text("YouTube serves iOS-compatible AAC up to ~256 kbps. On Android the higher rungs can also pull lossless audio from configured addon sources, which have no iOS counterpart yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func qualityPicker(_ title: String, selection: Binding<AudioQuality>) -> some View {
        Picker(title, selection: selection) {
            ForEach(AudioQuality.allCases) { quality in
                Text("\(quality.title) · \(quality.detail)").tag(quality)
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: Downloads

    private var downloadsSection: some View {
        Section("Downloads") {
            qualityPicker("Download quality", selection: Binding(
                get: { model.settings.downloadQuality },
                set: { model.settings.downloadQuality = $0 }
            ))
            Toggle("Download on Wi-Fi only", isOn: Binding(
                get: { model.settings.wifiOnlyDownloads },
                set: { model.settings.wifiOnlyDownloads = $0 }
            ))
            NavigationLink {
                DownloadsView()
            } label: {
                LabeledContent {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(model.downloads.totalBytes), countStyle: .file))
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Downloaded songs", systemImage: "arrow.down.circle")
                }
            }
            if !model.downloads.downloads.isEmpty {
                Button("Delete all downloads", role: .destructive) {
                    confirmation = .clearDownloads
                }
            }
        }
    }

    // MARK: Lyrics

    private var lyricsSection: some View {
        Section("Lyrics") {
            Toggle("Synced lyrics", isOn: Binding(
                get: { model.settings.syncedLyrics },
                set: { model.settings.syncedLyrics = $0 }
            ))
            if model.settings.lyricsOffsetMs != 0 {
                LabeledContent("Timing offset", value: "\(model.settings.lyricsOffsetMs > 0 ? "+" : "")\(String(format: "%.2f", Double(model.settings.lyricsOffsetMs) / 1000))s")
                Button("Reset timing offset") {
                    model.settings.lyricsOffsetMs = 0
                }
            }
            Text("Lyrics come from LRCLIB, the video's captions, and YouTube Music's own lyrics tab, in that order. Adjust timing from the lyrics panel while a song plays.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Scrobbling

    private var scrobblingSection: some View {
        Section("Scrobbling") {
            NavigationLink {
                ScrobblingSettingsView()
            } label: {
                Label("Last.fm & ListenBrainz", systemImage: "dot.radiowaves.up.forward")
            }
            let services = [
                model.settings.lastfmEnabled && model.scrobbler.isLastfmConnected ? "Last.fm" : nil,
                model.settings.listenBrainzEnabled && model.scrobbler.hasListenBrainzToken ? "ListenBrainz" : nil
            ].compactMap { $0 }
            Text(services.isEmpty
                ? "Nothing is being scrobbled. Connect a service to keep a public listening diary."
                : "Scrobbling to \(services.formatted(.list(type: .and))).")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Appearance & data

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: Binding(
                get: { model.appearance },
                set: { model.setAppearance($0) }
            )) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var dataSection: some View {
        Section("On this iPhone") {
            LabeledContent("Imported audio", value: "\(model.localAudio.tracks.count) files")
            LabeledContent("Local playlists", value: "\(model.playlists.playlists.count)")
            LabeledContent("Listening history", value: "\(model.recorder.events.count) plays")
            Button("Clear search history", role: .destructive) {
                confirmation = .clearHistory
            }
            .disabled(model.searchHistory.isEmpty)
            Button("Clear listening history", role: .destructive) {
                confirmation = .clearListening
            }
            .disabled(model.recorder.events.isEmpty)
            Text("iOS does not expose Android’s shared MediaStore library scan. Import individual audio files through Files; BitChord keeps a private app-owned copy.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var backupSection: some View {
        Section("Backup") {
            Button {
                exportBackup()
            } label: {
                Label("Export backup", systemImage: "square.and.arrow.up.on.square")
            }
            if let backupFile {
                ShareLink(item: backupFile) {
                    Label("Share backup file", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                showingBackupImporter = true
            } label: {
                Label("Import backup", systemImage: "square.and.arrow.down.on.square")
            }
            Text("A backup carries your settings, on-device playlists and listening history. Account sessions and scrobbling keys stay in the Keychain and are never exported.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About BitChord") {
            HStack(spacing: 12) {
                Image("BitChordLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("BitChord")
                        .font(.headline)
                    Text("Native iOS edition")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(versionLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("YouTube Music catalogue access uses its unofficial InnerTube web-client interface. Availability and stream resolution can change independently of BitChord.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func exportBackup() {
        do {
            let data = try model.makeBackup()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("BitChord-Backup.json", isDirectory: false)
            try data.write(to: url, options: [.atomic])
            backupFile = url
            model.notice = "Backup ready — use “Share backup file” to save it."
        } catch {
            model.notice = error.localizedDescription
        }
    }

    private func handleBackupImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.notice = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try model.restoreBackup(from: data)
            } catch {
                model.notice = error.localizedDescription
            }
        }
    }

    private func trimmed(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        return text.replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private var versionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
