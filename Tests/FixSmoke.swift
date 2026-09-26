import AppKit

/// Regression coverage for the 2026-09 interaction fixes: stepwise undo/redo,
/// canvas stability during drags, multi-selection batch dragging, and brace
/// annotations (creation, persistence, export, removal).
@main
struct FixSmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)

        func makeCanvas(root: MindNode) -> (MindMapStore, CanvasScrollView, MindCanvas) {
            let store = MindMapStore(root: root)
            let scroll = CanvasScrollView(frame: window.contentView!.bounds)
            let canvas = MindCanvas(store: store)
            window.contentView = scroll
            scroll.documentView = canvas
            canvas.refresh()
            window.makeFirstResponder(canvas)
            return (store, scroll, canvas)
        }

        let frame0WindowNumber = window.windowNumber

        func mouse(_ canvas: MindCanvas, _ type: NSEvent.EventType, at windowPoint: CGPoint, clickCount: Int = 1) {
            let event = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: frame0WindowNumber, context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1)!
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }

        /// Window point that hovers just below the middle of the target card,
        /// i.e. in the "insert after" zone (fraction > 0.75 means above in
        /// flipped coordinates — see updateDrop).
        func openHoverPoint(_ canvas: MindCanvas, _ id: UUID, _ targetRect: CGRect) -> CGPoint {
            canvas.convert(CGPoint(x: targetRect.midX, y: targetRect.minY + 4), to: nil)
        }

        // MARK: Stepwise undo/redo

        do {
            let store = MindMapStore()
            _ = store.createChild(of: store.root.id)
            let afterFirst = store.root
            _ = store.createChild(of: store.root.id)
            let afterSecond = store.root
            _ = store.createChild(of: store.root.id)
            let afterThird = store.root
            assert(store.undo() && store.root == afterSecond, "Undo must step back one edit at a time")
            assert(store.undo() && store.root == afterFirst, "Undo must step back one edit at a time")
            assert(store.undo() && store.root.children.isEmpty, "Undo must reach the original document")
            assert(store.redo() && store.root == afterFirst)
            assert(store.redo() && store.root == afterSecond)
            assert(store.redo() && store.root == afterThird)
            print("PASS: undo and redo move one step at a time")
        }

        // Editing session coalescing: one inline editing session is one step.
        do {
            let a = MindNode(title: "A")
            let b = MindNode(title: "B")
            let (store, _, canvas) = makeCanvas(root: MindNode(title: "Root", children: [a, b]))
            store.select(a.id)
            canvas.beginEditing(a.id)
            canvas.editor!.string = "第一改"
            canvas.finishEditing(commit: true)
            assert(store.node(a.id)!.title == "第一改")
            canvas.beginEditing(b.id)
            canvas.editor!.string = "第二改"
            canvas.finishEditing(commit: true)
            assert(store.node(b.id)!.title == "第二改")
            assert(store.undo() && store.node(b.id)!.title == "B" && store.node(a.id)!.title == "第一改", "Undo must revert only the last editing session")
            assert(store.undo() && store.node(a.id)!.title == "A", "Undo must revert the previous editing session")
            print("PASS: inline editing session is a single undo step")
        }

        // Multi-delete is one undo step.
        do {
            let a = MindNode(title: "A")
            let b = MindNode(title: "B")
            let c = MindNode(title: "C")
            let (store, _, canvas) = makeCanvas(root: MindNode(title: "Root", children: [a, b, c]))
            let rect = canvas.card(a.id)!.union(canvas.card(b.id)!)
            _ = canvas.applyMarqueeSelection(in: rect.insetBy(dx: -2, dy: -2))
            assert(canvas.selectedNodeIDs == Set([a.id, b.id]))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51)
            canvas.keyDown(with: event!)
            assert(store.root.children.map(\.title) == ["C"], "Multi-delete must remove all selected branches")
            assert(store.undo() && store.root.children.count == 3, "Multi-delete must be one undo step")
            print("PASS: multi-node delete is a single undo step")
        }

        // MARK: Canvas stability during drag

        do {
            let moving = MindNode(title: "Moving", children: [MindNode(title: "Leaf")])
            let target = MindNode(title: "Target")
            let (store, scroll, canvas) = makeCanvas(root: MindNode(title: "Root", children: [moving, target]))
            canvas.centerNode(moving.id)
            let sourceRect = canvas.card(moving.id)!
            let targetRect = canvas.card(target.id)!
            let start = canvas.convert(CGPoint(x: sourceRect.midX, y: sourceRect.midY), to: nil)
            // Below-side insertion zone (fraction > 0.75 in flipped coords).
            let hover = canvas.convert(CGPoint(x: targetRect.midX, y: targetRect.maxY + 4), to: nil)
            mouse(canvas, .leftMouseDown, at: start)
            mouse(canvas, .leftMouseDragged, at: hover)
            assert(canvas.drop != nil, "Hovering below the target must resolve a drop")
            let originDuringDrag = scroll.contentView.bounds.origin
            for _ in 0..<3 { mouse(canvas, .leftMouseDragged, at: hover) }
            assert(scroll.contentView.bounds.origin == originDuringDrag, "Stationary hover must not move the viewport")
            assert(canvas.dropPreview != nil && canvas.dropPreview!.frames[moving.id] != nil)
            // Only below-side insertion space: the preview may not place the
            // moving branch above the target when dropping after it.
            let previewFrame = canvas.dropPreview!.frames[moving.id]!.offsetBy(dx: canvas.inset, dy: canvas.inset)
            assert(previewFrame.minY >= targetRect.minY - 2, "After-drop preview must reserve space below, not following the pointer")
            let targetPreview = canvas.dropPreview!.frames[target.id]!.offsetBy(dx: canvas.inset, dy: canvas.inset)
            assert(targetPreview.minY == targetRect.minY, "The stationary target must not move when previewing an after-drop")
            mouse(canvas, .leftMouseUp, at: hover)
            assert(store.root.children.map(\.title) == ["Target", "Moving"], "Drop after the target must reorder siblings")
            print("PASS: viewport stays stable while dragging and hovering")
        }

        // MARK: Multi-selection batch drag

        do {
            let a = MindNode(title: "A")
            let b = MindNode(title: "B")
            let target = MindNode(title: "Target")
            let (store, _, canvas) = makeCanvas(root: MindNode(title: "Root", children: [a, b, target]))
            let rect = canvas.card(a.id)!.union(canvas.card(b.id)!)
            _ = canvas.applyMarqueeSelection(in: rect.insetBy(dx: -2, dy: -2))
            assert(canvas.selectedNodeIDs == Set([a.id, b.id]))
            let sourceRect = canvas.card(a.id)!
            let targetRect = canvas.card(target.id)!
            let start = canvas.convert(CGPoint(x: sourceRect.midX, y: sourceRect.midY), to: nil)
            let drop = canvas.convert(CGPoint(x: targetRect.midX, y: targetRect.midY), to: nil)
            mouse(canvas, .leftMouseDown, at: start)
            mouse(canvas, .leftMouseDragged, at: drop)
            assert(canvas.draggedIDs.contains(a.id) && canvas.draggedIDs.contains(b.id), "All selected branches must follow the pointer")
            assert(canvas.card(b.id)!.origin != canvas.treeLayout.frames[b.id]?.offsetBy(dx: canvas.inset, dy: canvas.inset).origin || canvas.dragOffset != .zero, "Extra selected card must be visually dragged")
            mouse(canvas, .leftMouseUp, at: drop)
            assert(store.node(target.id)!.children.map(\.title).contains("A"), "Pressed branch must land inside the target")
            assert(store.node(target.id)!.children.map(\.title).contains("B"), "Other selected branches must move with it")
            assert(store.root.children.map(\.title) == ["Target"], "Root keeps only the target after a batch move")
            assert(store.undo() && store.root.children.map(\.title) == ["A", "B", "Target"], "Batch move must be a single undo step")
            print("PASS: multi-selection drag moves every selected branch in one step")
        }

        // MARK: Brace annotations

        do {
            let a = MindNode(title: "A")
            let b = MindNode(title: "B")
            let (store, _, canvas) = makeCanvas(root: MindNode(title: "Root", children: [a, b]))
            let rect = canvas.card(a.id)!.union(canvas.card(b.id)!)
            _ = canvas.applyMarqueeSelection(in: rect.insetBy(dx: -2, dy: -2))
            guard let annotationID = canvas.createAnnotationFromSelection(label: "核心前提") else {
                assertionFailure("Selection of two nodes must create an annotation")
                return
            }
            assert(store.annotations.count == 1)
            assert(Set(store.annotations[0].memberIDs) == Set([a.id, b.id]))
            assert(canvas.annotationLabelRect(annotationID) != nil, "The annotation must expose a label rect")
            assert(canvas.annotationGeometry(annotationID) != nil, "The annotation must expose brace geometry")
            // Hit testing selects the brace, not member cards.
            assert(canvas.hitAnnotation(CGPoint(x: canvas.card(a.id)!.midX, y: canvas.card(a.id)!.midY)) == nil, "Member cards must not hit the annotation")
            let braceRect = canvas.annotationHitRects(annotationID)!.first!
            assert(canvas.hitAnnotation(CGPoint(x: braceRect.midX, y: braceRect.midY)) == annotationID, "The brace band must hit the annotation")
            // Export carries the label as a remark.
            let export = store.textExport()
            assert(export.contains("（备注：核心前提）"), "Export must include the annotation label as a remark, got: \(export)")
            // Persistence keeps annotations.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            try! store.save(url)
            let reopened = MindMapStore()
            try! reopened.open(url)
            assert(reopened.annotations.count == 1 && reopened.annotations[0].label == "核心前提", "Annotations must survive a save/open cycle")
            // Deleting all members disbands the annotation.
            _ = store.delete([a.id, b.id])
            assert(store.annotations.isEmpty, "Deleting every member must disband the annotation")
            assert(store.undo() && store.annotations.count == 1, "Undo must restore the disbanded annotation")
            // Removal via the store.
            assert(store.removeAnnotation(annotationID) && store.annotations.isEmpty)
            try! FileManager.default.removeItem(at: url)
            print("PASS: brace annotations — creation, hit test, export remark, persistence, disband, undo")
        }

        // Annotation rename is a discrete undo step.
        do {
            let a = MindNode(title: "A")
            let b = MindNode(title: "B")
            let (store, _, _) = makeCanvas(root: MindNode(title: "Root", children: [a, b]))
            let id = store.addAnnotation(memberIDs: [a.id, b.id], label: "初稿")!
            assert(store.updateAnnotation(id, label: "终稿") && store.annotation(id)!.label == "终稿")
            assert(store.undo() && store.annotation(id)!.label == "初稿", "Annotation rename must be undoable")
            print("PASS: annotation edits participate in undo")
        }

        // Legacy bare-root documents still open.
        do {
            let legacy = #"{"id": "\#(UUID().uuidString)", "title": "旧文档", "children": [], "isCollapsed": false}"#
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            try! legacy.data(using: .utf8)!.write(to: url)
            let store = MindMapStore()
            try! store.open(url)
            assert(store.root.title == "旧文档" && store.annotations.isEmpty)
            try! FileManager.default.removeItem(at: url)
            print("PASS: legacy bare-root JSON still opens")
        }

        print("PASS: all 2026-09 interaction fixes verified")
    }
}
