import SwiftUI

/// Account & scrobbling — Android's `AccountAndScrobblingScreen` for the two
/// services it supports: Last.fm (user keypair + browser approval) and
/// ListenBrainz (personal token). The scrobble-delay trio is Android's:
/// minimum track length, the share of a track that must play, and the cap
/// on that wait.
struct ScrobblingSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    @State private var listenBrainzToken = ""
    @State private var tokenValidation: String?
    @State private var isValidatingToken = false

    @State private var lastfmAPIKey = ""
    @State private var lastfmSecret = ""
    @State private var lastfmStatus: String?
    @State private var isLastfmBusy = false
    @State private var lastfmAuthPending = false

    var body: some View {
        Form {
            timingSection
            listenBrainzSection
            lastfmSection
        }
        .navigationTitle("Scrobbling")
        .navigationBarTitleDisplayMode(.inline)
        .tint(BitChordStyle.accent)
        .onAppear {
            lastfmAPIKey = model.scrobbler.lastfmAPIKey
        }
    }

    private var timingSection: some View {
        Section {
            Stepper(value: Binding(
                get: { model.settings.scrobbleMinDuration },
                set: { model.settings.scrobbleMinDuration = $0 }
            ), in: 0...120, step: 5) {
                LabeledContent("Minimum track length", value: "\(model.settings.scrobbleMinDuration)s")
            }
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Scrobble after", value: "\(Int(model.settings.scrobbleDelayPercent * 100))% played")
                Slider(
                    value: Binding(
                        get: { model.settings.scrobbleDelayPercent },
                        set: { model.settings.scrobbleDelayPercent = $0 }
                    ),
                    in: 0.1...1.0
                )
                .tint(BitChordStyle.accent)
            }
            Stepper(value: Binding(
                get: { model.settings.scrobbleDelaySeconds },
                set: { model.settings.scrobbleDelaySeconds = $0 }
            ), in: 30...600, step: 30) {
                LabeledContent("At most after", value: "\(model.settings.scrobbleDelaySeconds)s")
            }
        } header: {
            Text("When a play counts")
        } footer: {
            Text("A song scrobbles once the shorter of the two waits has actually played — paused time doesn't count.")
        }
    }

    private var listenBrainzSection: some View {
        Section {
            Toggle("Scrobble to ListenBrainz", isOn: Binding(
                get: { model.settings.listenBrainzEnabled },
                set: { model.settings.listenBrainzEnabled = $0 }
            ))
            Toggle("Primary artist only", isOn: Binding(
                get: { model.settings.listenBrainzPrimaryArtistOnly },
                set: { model.settings.listenBrainzPrimaryArtistOnly = $0 }
            ))

            if model.scrobbler.hasListenBrainzToken && listenBrainzToken.isEmpty {
                LabeledContent("User token", value: "Saved")
                Button("Remove token", role: .destructive) {
                    model.scrobbler.setListenBrainzToken(nil)
                    tokenValidation = nil
                }
            } else {
                SecureField("User token", text: $listenBrainzToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    validateAndSaveToken()
                } label: {
                    HStack(spacing: 8) {
                        if isValidatingToken { ProgressView().controlSize(.small) }
                        Text("Validate and save")
                    }
                }
                .disabled(listenBrainzToken.trimmingCharacters(in: .whitespaces).isEmpty || isValidatingToken)
            }
            if let tokenValidation {
                Text(tokenValidation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("ListenBrainz")
        } footer: {
            Text("Your token is on your ListenBrainz profile page. It's kept in the Keychain and only sent to api.listenbrainz.org.")
        }
    }

    private var lastfmSection: some View {
        Section {
            Toggle("Enable Last.fm", isOn: Binding(
                get: { model.settings.lastfmEnabled },
                set: { model.settings.lastfmEnabled = $0 }
            ))
            Toggle("Scrobble plays", isOn: Binding(
                get: { model.settings.lastfmScrobbleEnabled },
                set: { model.settings.lastfmScrobbleEnabled = $0 }
            ))
            Toggle("Send now playing", isOn: Binding(
                get: { model.settings.lastfmNowPlaying },
                set: { model.settings.lastfmNowPlaying = $0 }
            ))
            Toggle("Primary artist only", isOn: Binding(
                get: { model.settings.lastfmPrimaryArtistOnly },
                set: { model.settings.lastfmPrimaryArtistOnly = $0 }
            ))

            TextField("API key", text: $lastfmAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Shared secret", text: $lastfmSecret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save keypair") {
                model.scrobbler.setLastfmKeypair(apiKey: lastfmAPIKey, secret: lastfmSecret)
                lastfmStatus = model.scrobbler.hasLastfmKeypair ? "Keypair saved." : "Both an API key and a secret are needed."
            }
            .disabled(lastfmAPIKey.isEmpty || lastfmSecret.isEmpty)

            if model.scrobbler.isLastfmConnected {
                LabeledContent("Connected as", value: model.settings.lastfmUsername.isEmpty ? "Last.fm user" : model.settings.lastfmUsername)
                Button("Disconnect Last.fm", role: .destructive) {
                    model.scrobbler.signOutLastfm()
                    lastfmAuthPending = false
                    lastfmStatus = nil
                }
            } else {
                Button {
                    beginLastfmAuth()
                } label: {
                    HStack(spacing: 8) {
                        if isLastfmBusy { ProgressView().controlSize(.small) }
                        Text("Connect Last.fm account")
                    }
                }
                .disabled(!model.scrobbler.hasLastfmKeypair || isLastfmBusy)

                if lastfmAuthPending {
                    Button("I've approved access — finish connecting") {
                        completeLastfmAuth()
                    }
                    .disabled(isLastfmBusy)
                }
            }
            if let lastfmStatus {
                Text(lastfmStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Last.fm")
        } footer: {
            Text("Last.fm issues free API keys at last.fm/api. Connecting opens last.fm in your browser to approve access; no password ever passes through BitChord. Keys stay in the Keychain.")
        }
    }

    private func validateAndSaveToken() {
        let token = listenBrainzToken.trimmingCharacters(in: .whitespaces)
        isValidatingToken = true
        tokenValidation = nil
        Task {
            let valid = await model.scrobbler.validateListenBrainzToken(token)
            isValidatingToken = false
            if valid {
                model.scrobbler.setListenBrainzToken(token)
                listenBrainzToken = ""
                tokenValidation = "Token is valid and saved."
            } else {
                tokenValidation = "ListenBrainz didn't accept that token."
            }
        }
    }

    private func beginLastfmAuth() {
        isLastfmBusy = true
        lastfmStatus = nil
        Task {
            defer { isLastfmBusy = false }
            do {
                let url = try await model.scrobbler.lastfmAuthorizationURL()
                lastfmAuthPending = true
                lastfmStatus = "Approve BitChord on the Last.fm page that just opened, then come back and finish connecting."
                openURL(url)
            } catch {
                lastfmStatus = error.localizedDescription
            }
        }
    }

    private func completeLastfmAuth() {
        isLastfmBusy = true
        Task {
            defer { isLastfmBusy = false }
            do {
                let name = try await model.scrobbler.completeLastfmAuthorization()
                lastfmAuthPending = false
                lastfmStatus = "Connected as \(name)."
                if !model.settings.lastfmScrobbleEnabled && !model.settings.lastfmNowPlaying {
                    model.settings.lastfmScrobbleEnabled = true
                    model.settings.lastfmNowPlaying = true
                }
            } catch {
                lastfmStatus = error.localizedDescription
            }
        }
    }
}
