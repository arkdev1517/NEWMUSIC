import CoreFoundation
import Foundation
import Security

protocol CredentialStore: Sendable {
    func string(for key: String) -> String?
    func set(_ value: String?, for key: String) throws
}

/// Small Keychain-backed credential store. Cookies are account credentials,
/// so they never go into UserDefaults, app logs, backups, or the app bundle.
struct KeychainCredentialStore: CredentialStore {
    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.music.bitchord") {
        self.service = service
    }

    func string(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    func set(_ value: String?, for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }

        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "Could not securely store the account session (Keychain status \(status))."
    }
}

enum SessionCredential {
    static let youtubeCookie = "youtube-music-cookie"
    /// Scrobbling secrets (Android keeps these in its settings store; the
    /// Keychain is the secure equivalent on iOS).
    static let lastfmAPIKey = "lastfm-api-key"
    static let lastfmSecret = "lastfm-secret"
    static let lastfmSessionKey = "lastfm-session-key"
    static let listenBrainzToken = "listenbrainz-token"
}
