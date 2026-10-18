import SwiftUI
import WebKit

struct YouTubeSignInView: View {
    let onConnect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isOnMusicPage = false
    @State private var sessionCookie: String?
    @State private var statusMessage = "Sign in to your YouTube Music account below."

    private var canConnect: Bool { isOnMusicPage && sessionCookie != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                YouTubeLoginWebView(
                    isOnMusicPage: $isOnMusicPage,
                    sessionCookie: $sessionCookie,
                    statusMessage: $statusMessage
                )
                .ignoresSafeArea(edges: .bottom)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) {
                        Image(systemName: canConnect ? "checkmark.circle.fill" : "lock.shield")
                            .foregroundStyle(canConnect ? BitChordStyle.accent : Color.secondary)
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        guard let sessionCookie else { return }
                        onConnect(sessionCookie)
                        dismiss()
                    } label: {
                        Text("Use this YouTube Music account")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BitChordStyle.accent)
                    .disabled(!canConnect)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(.bar)
            }
            .navigationTitle("Connect YouTube Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .tint(BitChordStyle.accent)
    }
}

private struct YouTubeLoginWebView: UIViewRepresentable {
    @Binding var isOnMusicPage: Bool
    @Binding var sessionCookie: String?
    @Binding var statusMessage: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        context.coordinator.clearYouTubeCookiesAndOpenLogin()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: YouTubeLoginWebView
        weak var webView: WKWebView?
        private let cookieStore = WKWebsiteDataStore.default().httpCookieStore

        init(parent: YouTubeLoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView.url?.host?.lowercased() == "music.youtube.com" else { return }
            parent.isOnMusicPage = true
            parent.statusMessage = "Checking the signed-in YouTube Music session…"
            webView.evaluateJavaScript(Self.identityProbe) { [weak self] value, error in
                guard let self else { return }
                guard error == nil,
                      let identity = value as? [String: Any],
                      identity["loggedIn"] as? Bool == true else {
                    self.parent.sessionCookie = nil
                    self.parent.statusMessage = "YouTube Music is open. Sign in there, then wait for this status to update."
                    return
                }
                self.cookieStore.getAllCookies { cookies in
                    let usable = cookies.filter {
                        let domain = $0.domain.lowercased()
                        let appliesToYouTube = domain == "youtube.com" || domain.hasSuffix(".youtube.com")
                        return appliesToYouTube && ($0.expiresDate.map { $0 > Date() } ?? true)
                    }
                    let uniqueCookies = Dictionary(usable.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
                    let header = uniqueCookies.values
                        .sorted { $0.name < $1.name }
                        .map { "\($0.name)=\($0.value)" }
                        .joined(separator: "; ")
                    let hasSigningCookie = uniqueCookies.keys.contains { ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"].contains($0) }
                    DispatchQueue.main.async {
                        guard hasSigningCookie, !header.isEmpty else {
                            self.parent.sessionCookie = nil
                            self.parent.statusMessage = "YouTube Music is signed in, but its session is not ready yet. Try again in a moment."
                            return
                        }
                        self.parent.sessionCookie = header
                        self.parent.statusMessage = "Signed in. Your session is stored securely in this app’s Keychain."
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isOnMusicPage = false
            parent.sessionCookie = nil
            parent.statusMessage = error.localizedDescription
        }

        func clearYouTubeCookiesAndOpenLogin() {
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let googleCookies = cookies.filter {
                    let domain = $0.domain.lowercased()
                    return domain == "youtube.com" || domain.hasSuffix(".youtube.com")
                        || domain == "google.com" || domain.hasSuffix(".google.com")
                }
                let group = DispatchGroup()
                for cookie in googleCookies {
                    group.enter()
                    self.cookieStore.delete(cookie) { group.leave() }
                }
                group.notify(queue: .main) { [weak self] in
                    guard let self, let webView = self.webView,
                          let url = URL(string: "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&prompt=select_account&continue=https%3A%2F%2Fmusic.youtube.com%2F") else { return }
                    webView.load(URLRequest(url: url))
                }
            }
        }

        private static let identityProbe = """
        (function () {
          try {
            if (!window.ytcfg || !window.ytcfg.get) return null;
            return { loggedIn: !!window.ytcfg.get('LOGGED_IN') };
          } catch (e) { return null; }
        })()
        """
    }
}

enum YouTubeWebSession {
    static func clearCookies() {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            let googleCookies = cookies.filter {
                let domain = $0.domain.lowercased()
                return domain == "youtube.com" || domain.hasSuffix(".youtube.com")
                    || domain == "google.com" || domain.hasSuffix(".google.com")
            }
            googleCookies.forEach { store.delete($0) }
        }
    }
}
