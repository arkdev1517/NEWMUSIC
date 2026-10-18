import Foundation

enum SettingsConfirmation {
    case signOut
    case clearHistory

    var title: String {
        switch self {
        case .signOut: "Sign out of YouTube Music?"
        case .clearHistory: "Clear recent searches?"
        }
    }

    var message: String {
        switch self {
        case .signOut:
            "This removes the saved account session from BitChord and clears its embedded YouTube and Google cookies."
        case .clearHistory:
            "This only clears search history stored on this device."
        }
    }
}
