import AppKit

@main
struct NavigationSmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        let first = MindNode(title: "First")
        let second = MindNode(title: "Second")
        let branch = MindNode(title: "Branch", children: [first, second])
        let store = MindMapStore(root: MindNode(title: "Root", children: [branch]))
        let canvas = MindCanvas(store: store)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = CanvasScrollView(frame: window.contentView!.bounds)
        window.contentView = scroll; scroll.documentView = canvas
        canvas.refresh(); window.makeFirstResponder(canvas)
        func key(_ code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            canvas.keyDown(with: event)
        }
        store.select(first.id)
        key(125)
        assert(store.selectedID == second.id, "Down must select the next sibling")
        print("PASS: native arrow event selects next sibling")

        let previous = MindNode(title: "Previous parent", children: [MindNode(title: "Previous child")])
        let next = MindNode(title: "Next parent", children: [MindNode(title: "Next child")])
        let middle = MindNode(title: "Middle", children: [branch])
        store.root = MindNode(title: "Root", children: [previous, middle, next])
        canvas.refresh()
        for orientation in [StrataLayoutOrientation.horizontal, .vertical] {
            canvas.orientation = orientation; canvas.refresh()
            for scale: CGFloat in [0.25, 1, 3] {
                scroll.zoom(to: scale, at: CGPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY))
                store.select(first.id); key(125); assert(store.selectedID == second.id)
                key(126); assert(store.selectedID == first.id)
                key(123); assert(store.selectedID == branch.id)
                key(124); assert(store.selectedID == first.id)
                key(126); assert(store.selectedID == previous.id, "Sibling boundary must climb multiple ancestors to the previous parent branch")
                store.select(second.id); key(125); assert(store.selectedID == next.id)
                key(125); assert(store.selectedID == next.id, "End of tree must not wrap")
                store.select(previous.id); key(126); assert(store.selectedID == previous.id)
                store.select(store.root.id); key(123); assert(store.selectedID == store.root.id)
                key(124); assert(store.selectedID == previous.id)
                store.selectedID = nil; key(124); assert(store.selectedID == store.root.id)
                store.selectedID = UUID(); key(126); assert(store.selectedID == store.root.id)
                store.toggleCollapsed(branch.id)
                store.select(branch.id); key(124)
                assert(store.selectedID == first.id && !store.node(branch.id)!.isCollapsed)
                assert(canvas.card(first.id) != nil)
                assert(scroll.documentVisibleRect.intersects(canvas.card(first.id)!))
                key(124); assert(store.selectedID == first.id, "Right on a leaf must remain selected")
                assert(scroll.magnification == scale, "Navigation must preserve zoom")
            }
        }
        print("PASS: parent/child, sibling and ancestor boundaries, collapsed children, nil/stale selection, both layouts and zoom limits")

        scroll.zoom(to: 1, at: CGPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY))
        store.select(first.id); canvas.beginEditing(first.id)
        let editor = canvas.editor!
        editor.string = "文字编辑"; editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.moveLeft(nil)
        assert(editor.selectedRange().location == 1 && store.selectedID == first.id)
        editor.moveRight(nil)
        assert(editor.selectedRange().location == 2 && store.selectedID == first.id)
        canvas.finishEditing(commit: false)
        print("PASS: inline editing keeps arrow commands in the text responder")
    }
}
