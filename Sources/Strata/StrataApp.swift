import SwiftUI

@main
struct StrataApp: App {
    @StateObject private var store = MindMapStore()
    @StateObject private var library = MaterialLibraryStore(url: MaterialLibraryStore.defaultURL)

    var body: some Scene {
        WindowGroup("Strata") {
            WorkspaceView(store: store, library: library)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            DocumentCommands(
                newDocument: { NotificationCenter.default.post(name: .newStrataDocument, object: nil) },
                clearDocument: { NotificationCenter.default.post(name: .clearStrataDocument, object: nil) }
            )
        }
    }
}
