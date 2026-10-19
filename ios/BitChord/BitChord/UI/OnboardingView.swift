import SwiftUI

/// First-run onboarding — Android's `OnboardingScreen`, same words, same two
/// steps: a name (the one friends see in Listen Together), then the
/// optional YouTube account connection. Skipping sign-in is a first-class
/// path, exactly as on Android; the account can be connected later in
/// Settings.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var step = 0
    @State private var name = ""
    @State private var showingSignIn = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            BitChordStyle.brandGradient
                .opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                Image("BitChordLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                    .padding(.bottom, 24)

                if step == 0 {
                    nameStep
                } else {
                    connectStep
                }
                Spacer()

                // Page dots
                HStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { index in
                        Capsule()
                            .fill(index == step ? BitChordStyle.accent : Color.secondary.opacity(0.4))
                            .frame(width: index == step ? 22 : 8, height: 8)
                    }
                }
                .padding(.bottom, 28)
            }
            .padding(.horizontal, 28)
        }
        .sheet(isPresented: $showingSignIn) {
            YouTubeSignInView { cookie in
                model.saveYouTubeSession(cookie: cookie)
                finish()
            }
        }
        .onAppear {
            name = model.settings.displayName
        }
    }

    private var nameStep: some View {
        VStack(spacing: 16) {
            Text("Millions of songs, stream on BitChord")
                .font(.largeTitle.weight(.heavy))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("What should we call you?")
                .font(.title3.weight(.semibold))
                .padding(.top, 12)

            TextField("Your name", text: $name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($nameFocused)
                .submitLabel(.next)
                .onSubmit { advanceFromName() }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(BitChordStyle.cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Friends see this when you Listen Together. You can change it later in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                advanceFromName()
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(BitChordStyle.accent)
            .controlSize(.large)
            .padding(.top, 8)
        }
    }

    private var connectStep: some View {
        VStack(spacing: 16) {
            Text("Connect your YouTube account")
                .font(.largeTitle.weight(.heavy))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Bring your library, playlists and mixes with you, and start a Listen Together party with friends.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showingSignIn = true
            } label: {
                Text("Sign in with Google")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(BitChordStyle.accent)
            .controlSize(.large)
            .padding(.top, 8)

            Button("Skip sign in") {
                finish()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

            Button("Back") {
                withAnimation { step = 0 }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func advanceFromName() {
        model.settings.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nameFocused = false
        withAnimation { step = 1 }
    }

    private func finish() {
        model.settings.displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settings.onboardingComplete = true
    }
}
