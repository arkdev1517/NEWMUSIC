import Foundation

enum SettingsConfirmation {
    case signOut
    case clearHistory
    case clearListening
    case clearDownloads

    var title: String {
        switch self {
        case .signOut: "Sign out of YouTube Music?"
        case .clearHistory: "Clear recent searches?"
        case .clearListening: "Clear listening history?"
        case .clearDownloads: "Delete all downloads?"
        }
    }

    var message: String {
        switch self {
        case .signOut:
            "This removes the saved account session from BitChord and clears its embedded YouTube and Google cookies."
        case .clearHistory:
            "This only clears search history stored on this device."
        case .clearListening:
            "This removes this iPhone's listening history and the statistics built from it. Your YouTube Music history is untouched."
        case .clearDownloads:
            "Downloaded songs will need an internet connection to play again."
        }
    }
}
