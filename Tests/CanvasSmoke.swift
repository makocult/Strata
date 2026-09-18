import AppKit

@main
struct CanvasSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let leaf = MindNode(title: "Last leaf")
        let branch = MindNode(title: "Branch", children: [leaf])
        let removed = MindNode(title: "Delete me")
        let store = MindMapStore(root: MindNode(title: "Root", children: [removed, branch]))
        store.selectedID = removed.id
        assert(store.delete(removed.id) == leaf.id, "Deleting the selection must select the last terminal node")
        assert(store.selectedID == leaf.id)
        print("PASS: deletion falls back to the last terminal node")

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = CanvasScrollView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let canvas = MindCanvas(store: store)
        window.contentView = scroll
        scroll.documentView = canvas
        canvas.refresh()
        window.makeFirstResponder(canvas)
        func centered(_ id: UUID) {
            let rect = canvas.card(id)!
            assert(abs(scroll.contentView.bounds.midX - rect.midX) < 2, "Focus must center X at the current magnification")
            assert(abs(scroll.contentView.bounds.midY - rect.midY) < 2, "Focus must center Y at the current magnification")
        }
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        func key(_ code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            canvas.keyDown(with: event)
        }
        func anchorPoint() -> CGPoint {
            let rect = scroll.contentView.bounds
            return CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.4)
        }
        assert(scroll.allowsMagnification && scroll.minMagnification == 0.25 && scroll.maxMagnification == 3)
        for scale: CGFloat in [0.25, 0.6, 1, 2, 3] {
            let anchor = anchorPoint()
            let before = canvas.convert(anchor, to: nil)
            scroll.zoom(to: scale, at: anchor)
            let after = canvas.convert(anchor, to: nil)
            assert(abs(before.x - after.x) < 2 && abs(before.y - after.y) < 2, "Zoom must preserve the point under the pointer")
            assert(scroll.magnification == scale)
            canvas.centerRoot(); centered(store.root.id)
            for orientation in [StrataLayoutOrientation.horizontal, .vertical] {
                canvas.orientation = orientation
                store.select(branch.id)
                key(48)
                let child = store.selectedID!
                assert(canvas.editingID == child && window.firstResponder === canvas.editor)
                centered(child)
                assert(scroll.magnification == scale)
                canvas.finishEditing(commit: true)
                key(36)
                let sibling = store.selectedID!
                centered(sibling)
                assert(scroll.magnification == scale)
                canvas.finishEditing(commit: true)
                key(51)
                assert(store.selectedID == child && canvas.card(sibling) == nil)
                centered(child)
                assert(scroll.magnification == scale)
                key(51)
                assert(store.selectedID == leaf.id)
                centered(leaf.id)
                // Re-rendering after a mutation must not pull a manually panned view back.
                let origin = scroll.contentView.bounds.origin
                scroll.contentView.scroll(to: CGPoint(x: origin.x + 40, y: origin.y + 30))
                let panned = scroll.contentView.bounds.origin
                canvas.refresh()
                assert(scroll.contentView.bounds.origin == panned)
            }
        }
        scroll.zoom(to: 0.01, at: anchorPoint()); assert(scroll.magnification == 0.25)
        scroll.zoom(to: 20, at: anchorPoint()); assert(scroll.magnification == 3)
        print("PASS: pointer-anchored zoom, 25%-300% bounds, fixed-scale child/sibling/delete focus in both orientations, one-shot focus")

        scroll.zoom(to: 1, at: anchorPoint())
        let wheel = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!)!
        canvas.scrollWheel(with: wheel)
        assert(scroll.magnification > 1, "A wheel event delivered to the canvas must zoom")
        canvas.beginEditing(leaf.id)
        let beforeEditorZoom = scroll.magnification
        canvas.editor!.scrollWheel(with: wheel)
        assert(scroll.magnification > beforeEditorZoom && canvas.editingID == leaf.id)
        canvas.finishEditing(commit: true)
        print("PASS: native wheel event routing through canvas and inline editor")

        for scale: CGFloat in [0.25, 2, 3] {
            scroll.zoom(to: scale, at: anchorPoint())
            canvas.centerRoot()
            let start = CGPoint(x: 80, y: 80)
            let end = CGPoint(x: 140, y: 120)
            let origin = scroll.contentView.bounds.origin
            mouse(.leftMouseDown, at: start)
            assert(canvas.pressedID == nil)
            mouse(.leftMouseDragged, at: end)
            assert(abs(scroll.contentView.bounds.origin.x - (origin.x - 60 / scale)) < 2)
            assert(abs(scroll.contentView.bounds.origin.y - (origin.y + 40 / scale)) < 2)
            mouse(.leftMouseUp, at: end)
            canvas.centerNode(branch.id)
            let rect = canvas.card(branch.id)!
            let nodeStart = canvas.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
            let nodeEnd = CGPoint(x: nodeStart.x - 35, y: nodeStart.y + 20)
            mouse(.leftMouseDown, at: nodeStart)
            mouse(.leftMouseDragged, at: nodeEnd)
            let moved = canvas.convert(canvas.card(branch.id)!, to: nil)
            assert(abs(moved.midX - nodeEnd.x) < 2 && abs(moved.midY - nodeEnd.y) < 2, "Scaled node drag must follow the mouse in window coordinates")
            key(53)
            mouse(.leftMouseUp, at: nodeEnd)
        }
        print("PASS: blank-canvas pan and subtree drag preserve mouse distance at multiple scales")

        for orientation in [StrataLayoutOrientation.horizontal, .vertical] {
            canvas.orientation = orientation; canvas.refresh(); canvas.centerNode(branch.id)
            let before = canvas.convert(canvas.card(branch.id)!, to: nil)
            let export = store.textExport()
            let button = canvas.disclosureRect(branch.id)!
            let click = canvas.convert(CGPoint(x: button.midX, y: button.midY), to: nil)
            mouse(.leftMouseDown, at: click)
            mouse(.leftMouseUp, at: click)
            assert(store.node(branch.id)!.isCollapsed && canvas.card(leaf.id) == nil)
            let after = canvas.convert(canvas.card(branch.id)!, to: nil)
            assert(abs(before.midX - after.midX) < 2 && abs(before.midY - after.midY) < 2, "Collapse must keep the toggled card under the pointer")
            assert(store.textExport() == export && store.node(leaf.id) != nil)
            assert(canvas.treeLayout.frames.count == 2)
            key(49)
            assert(!store.node(branch.id)!.isCollapsed && canvas.card(leaf.id) != nil)
            store.select(leaf.id)
            canvas.toggleCollapsed(branch.id)
            assert(store.selectedID == branch.id, "Collapsing a selected descendant must move selection to its branch")
            key(48)
            let child = store.selectedID!
            assert(!store.node(branch.id)!.isCollapsed && canvas.editingID == child)
            centered(child)
            canvas.finishEditing(commit: true)
            key(51)
        }
        assert(!store.toggleCollapsed(leaf.id))
        print("PASS: disclosure mouse hit, Space toggle, stable branch position, hidden descendants, full export and creating inside a collapsed branch")

        store.toggleCollapsed(branch.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("collapsed.json")
        try store.save(url)
        let reopened = MindMapStore(); try reopened.open(url)
        assert(reopened.root == store.root && reopened.node(branch.id)!.isCollapsed)
        let legacy = Data("{\"id\":\"\(UUID().uuidString)\",\"title\":\"Legacy\",\"children\":[]}".utf8)
        let legacyRoot = try JSONDecoder().decode(MindNode.self, from: legacy)
        assert(!legacyRoot.isCollapsed)
        let newChild = store.createChild(of: store.root.id)!
        canvas.refresh()
        store.delete(newChild); canvas.refresh()
        assert(store.selectedID == leaf.id && !store.node(branch.id)!.isCollapsed)
        centered(leaf.id)
        let another = store.createChild(of: store.root.id)!
        store.select(branch.id)
        assert(store.delete(another) == branch.id)
        canvas.refresh(); centered(branch.id)
        store.selectedID = nil
        assert(store.delete(leaf.id) == branch.id)
        assert(store.delete(branch.id) == store.root.id)
        canvas.refresh(); centered(store.root.id)
        assert(store.delete(store.root.id) == nil)
        print("PASS: collapsed JSON round trip, legacy JSON, revealing a hidden fallback, surviving selection, nil selection and root-only fallback")

        for orientation in [StrataLayoutOrientation.horizontal, .vertical] {
            for scale: CGFloat in [0.25, 3] {
                let hidden = MindNode(title: "Hidden descendant")
                let moving = MindNode(title: "Moving branch", children: [hidden], isCollapsed: true)
                let targetLeaf = MindNode(title: "Target leaf")
                let target = MindNode(title: "Target", children: [targetLeaf], isCollapsed: true)
                store.root = MindNode(title: "Root", children: [moving, target])
                canvas.orientation = orientation; canvas.refresh()
                scroll.zoom(to: scale, at: anchorPoint()); canvas.centerNode(target.id)
                let sourceRect = canvas.card(moving.id)!
                let targetRect = canvas.card(target.id)!
                let start = canvas.convert(CGPoint(x: sourceRect.midX, y: sourceRect.midY), to: nil)
                let end = canvas.convert(CGPoint(x: targetRect.midX, y: targetRect.midY), to: nil)
                mouse(.leftMouseDown, at: start)
                mouse(.leftMouseDragged, at: end)
                assert(canvas.drop?.0 == target.id && canvas.drop?.1 == .inside)
                assert(store.node(target.id)!.isCollapsed, "Hover cannot mutate the stored collapse state")
                assert(canvas.card(targetLeaf.id) != nil && canvas.visibleIDs.contains(targetLeaf.id), "Previewing an expanded target must draw its existing children")
                assert(canvas.card(hidden.id) == nil && canvas.dropPreview!.frames[hidden.id] == nil)
                let ghost = canvas.dropPreview!.frames[moving.id]!.offsetBy(dx: canvas.inset, dy: canvas.inset)
                let expected = canvas.convert(ghost, to: nil)
                mouse(.leftMouseUp, at: end)
                let actual = canvas.convert(canvas.card(moving.id)!, to: nil)
                assert(abs(actual.midX - expected.midX) < 2 && abs(actual.midY - expected.midY) < 2)
                assert(!store.node(target.id)!.isCollapsed && store.node(moving.id)!.isCollapsed)
                assert(store.node(hidden.id) != nil && canvas.card(hidden.id) == nil)
                assert(scroll.magnification == scale)
                let export = store.textExport()
                store.select(targetLeaf.id)
                canvas.toggleCollapsed(store.root.id)
                assert(store.selectedID == store.root.id && canvas.treeLayout.frames.count == 1 && canvas.treeLayout.connectors.isEmpty)
                assert(store.textExport() == export)
                canvas.toggleCollapsed(store.root.id)
                assert(canvas.card(targetLeaf.id) != nil && canvas.card(hidden.id) == nil, "Expanding ancestors must preserve nested collapse state")
            }
        }
        print("PASS: collapsed subtree drag, expanded drop preview, exact scaled landing, root collapse and nested collapse preservation")
    }
}
