import SwiftUI

@main
struct BitChordApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            BitChordRootView()
                .environmentObject(model)
                .tint(BitChordStyle.accent)
        }
    }
}
