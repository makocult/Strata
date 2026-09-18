import AppKit

@main
struct InteractionSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared

        func makeCanvas(root: MindNode) -> (MindMapStore, NSWindow, CanvasScrollView, MindCanvas) {
            let store = MindMapStore(root: root)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let scroll = CanvasScrollView(frame: window.contentView!.bounds)
            let canvas = MindCanvas(store: store)
            window.contentView = scroll
            scroll.documentView = canvas
            canvas.refresh()
            window.makeFirstResponder(canvas)
            return (store, window, scroll, canvas)
        }

        func key(_ canvas: MindCanvas, window: NSWindow, code: UInt16, characters: String = "") {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: code
            )!
            canvas.keyDown(with: event)
        }

        let first = MindNode(title: "First")
        let second = MindNode(title: "Second")
        let third = MindNode(title: "Third")
        let (selectionStore, _, _, selectionCanvas) = makeCanvas(
            root: MindNode(title: "Root", children: [first, second, third])
        )
        let firstRect = selectionCanvas.card(first.id)!
        let secondRect = selectionCanvas.card(second.id)!
        let selectionRect = firstRect.union(secondRect).insetBy(dx: -2, dy: -2)
        let selected = selectionCanvas.applyMarqueeSelection(in: selectionRect)
        assert(selected == Set([first.id, second.id]))
        assert(selectionCanvas.selectedNodeIDs == selected)
        assert(selectionStore.selectedID == first.id)
        print("PASS: marquee selection captures intersecting nodes with a stable primary selection")

        let editable = MindNode(title: "Old text")
        let (store, window, _, canvas) = makeCanvas(root: MindNode(title: "Root", children: [editable]))
        store.select(editable.id)
        canvas.refresh()
        key(canvas, window: window, code: 7, characters: "新")
        assert(canvas.editingID == editable.id)
        assert(canvas.editor?.string == "新", "Typing on a selected node must replace its previous text")
        print("PASS: typing on a selected node replaces the old text without a double click")

        canvas.editor!.string = "一级内容"
        let handledTab = canvas.textView(canvas.editor!, doCommandBy: #selector(NSResponder.insertTab(_:)))
        assert(handledTab)
        assert(store.node(editable.id)?.title == "一级内容")
        guard let childID = store.node(editable.id)?.children.last?.id else {
            assertionFailure("Tab must create a child")
            return
        }
        assert(store.selectedID == childID && canvas.editingID == childID)
        assert(window.firstResponder === canvas.editor)
        print("PASS: Tab commits the current node and immediately creates an editable child")

        canvas.editor!.string = "子内容"
        let handledEnter = canvas.textView(canvas.editor!, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        assert(handledEnter)
        assert(canvas.editingID == nil)
        assert(store.node(childID)?.title == "子内容")
        assert(store.selectedID == childID)

        key(canvas, window: window, code: 36)
        guard let parent = store.node(editable.id), let childIndex = parent.children.firstIndex(where: { $0.id == childID }) else {
            assertionFailure("Committed child must remain in the tree")
            return
        }
        let siblingIndex = childIndex + 1
        assert(parent.children.indices.contains(siblingIndex) == false, "Store snapshot before refresh should not be reused")
        let refreshedParent = store.node(editable.id)!
        assert(refreshedParent.children.indices.contains(siblingIndex))
        let siblingID = refreshedParent.children[siblingIndex].id
        assert(store.selectedID == siblingID && canvas.editingID == siblingID)
        print("PASS: first Enter commits; the next Enter creates an editable sibling")
    }
}
