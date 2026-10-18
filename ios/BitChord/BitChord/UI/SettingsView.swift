import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingSignIn = false
    @State private var confirmation: SettingsConfirmation?

    var body: some View {
        Form {
            Section("YouTube Music") {
                HStack(spacing: 12) {
                    Image(systemName: model.isYouTubeSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.title2)
                        .foregroundStyle(BitChordStyle.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.isYouTubeSignedIn ? "Account connected" : "Not connected")
                            .font(.subheadline.weight(.semibold))
                        Text(model.isYouTubeSignedIn ? "Your library and account actions are available." : "Connect to browse your account library and save likes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)

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

            Section("Search") {
                HStack {
                    Label("Recent searches", systemImage: "clock")
                    Spacer()
                    Text("\(model.searchHistory.count)")
                        .foregroundStyle(.secondary)
                }
                Button("Clear search history", role: .destructive) {
                    confirmation = .clearHistory
                }
                .disabled(model.searchHistory.isEmpty)
            }

            Section("Local music") {
                LabeledContent("Imported audio", value: "\(model.localAudio.tracks.count) files")
                LabeledContent("Recently played", value: "\(model.localAudio.recentTracks.count) tracks")
                Text("iOS does not expose Android’s shared MediaStore library scan. Import individual audio files through Files; BitChord keeps a private app-owned copy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .tint(BitChordStyle.accent)
        .sheet(isPresented: $showingSignIn) {
            YouTubeSignInView { cookie in model.saveYouTubeSession(cookie: cookie) }
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
            case nil:
                EmptyView()
            }
        } message: {
            Text(confirmation?.message ?? "")
        }
    }

    private var versionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
