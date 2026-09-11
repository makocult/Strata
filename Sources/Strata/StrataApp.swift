import SwiftUI

@main
struct StrataApp: App {
    @StateObject private var store = MindMapStore()

    var body: some Scene {
        WindowGroup("Strata") {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .undoRedo) {
                Button("新建子节点") { store.addChild() }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button("新建同级节点") { store.addSibling() }
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }
}
