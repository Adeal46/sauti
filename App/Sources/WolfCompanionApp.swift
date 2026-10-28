import SwiftUI
import SwiftData

@main
struct WolfCompanionApp: App {
    @StateObject private var player = PlaybackController()
    @StateObject private var importer = ImportCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(importer)
                .tint(Color("AccentColor"))
        }
        .modelContainer(for: ReadingDocument.self)
    }
}
