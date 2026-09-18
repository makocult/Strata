import SwiftUI

@main
struct StrataApp: App {
    @StateObject private var store = MindMapStore()
    @StateObject private var library = MaterialLibraryStore(url: MaterialLibraryStore.defaultURL)

    var body: some Scene {
        WindowGroup("Strata") {
            ContentView(store: store, library: library)
                .frame(minWidth: 900, minHeight: 620)
        }
        .commands {
            DocumentCommands(
                newDocument: { NotificationCenter.default.post(name: .newStrataDocument, object: nil) },
                clearDocument: { NotificationCenter.default.post(name: .clearStrataDocument, object: nil) }
            )
        }
    }
}
