import SwiftUI
import SwiftData

@main
struct SautiApp: App {
    @StateObject private var player = PlaybackController()
    @StateObject private var importer = ImportCoordinator()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(player)
                .environmentObject(importer)
                .tint(Color("AccentColor"))
        }
        .modelContainer(for: ReadingDocument.self)
    }
}
