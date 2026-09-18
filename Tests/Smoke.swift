import AppKit
@main struct Smoke {
 @MainActor static func main() {
  let app = NSApplication.shared
  let store = MindMapStore()
  let canvas = MindCanvas(store: store)
  let window = NSWindow(contentRect: NSRect(x:0,y:0,width:900,height:620), styleMask:[.titled], backing:.buffered, defer:false)
  window.contentView = canvas
  canvas.refresh()
  window.makeFirstResponder(canvas)
  func key(_ code: UInt16) {
   let e = NSEvent.keyEvent(with:.keyDown, location:.zero, modifierFlags:[], timestamp:0, windowNumber:window.windowNumber, context:nil, characters:"", charactersIgnoringModifiers:"", isARepeat:false, keyCode:code)!
   canvas.keyDown(with:e)
  }
  key(48)
  assert(store.root.children.count == 1 && canvas.editor != nil)
  assert(window.firstResponder === canvas.editor)
  canvas.editor!.string = "第一项"; canvas.finishEditing(commit:true)
  assert(window.firstResponder === canvas)
  key(36)
  assert(store.root.children.count == 2)
  canvas.finishEditing(commit:true)
  let first = store.root.children[0].id, second = store.root.children[1].id
  assert(store.move(second, relativeTo:first, placement:.before))
  assert(store.root.children[0].id == second)
  assert(store.move(first, relativeTo:second, placement:.inside))
  assert(!store.move(second, relativeTo:first, placement:.inside))
  assert(store.textExport() == "# 主题\n## 新节点\n第一项", "Markdown must preserve intermediate branches and leave leaves unheaded")
  let small = NodeSizing.size(for:"短")
  let long = NodeSizing.size(for:String(repeating:"中文长文本测试",count:50))
  assert(long.width <= 300 && long.height > small.height)
  for orientation in [StrataLayoutOrientation.horizontal, .vertical] {
   let layout = TreeLayoutEngine.layout(root:store.root,orientation:orientation)
   assert(layout.frames.count == 3 && !layout.connectors.isEmpty)
   let frames = Array(layout.frames.values)
   for i in frames.indices { for j in frames.indices where j > i { assert(!frames[i].intersects(frames[j])) } }
  }
  store.selectedID = first; key(51); assert(store.node(first) == nil)
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
  try! store.save(url); let restored = MindMapStore(); try! restored.open(url); assert(restored.root == store.root); try! FileManager.default.removeItem(at:url)
  assert(MindMapStore().textExport() == "主题")
  let previousRootID = restored.root.id
  restored.reset()
  assert(restored.root.id != previousRootID && restored.isEmptyDocument)
  assert(restored.selectedID == restored.root.id && restored.focusRequest?.nodeID == restored.root.id)
  print("PASS: native responder editing, Tab child, Enter sibling, Delete, reorder, reparent, cycle rejection, sizing, both layouts/connectors, export, JSON round trip, document reset")
  let scroll = NSScrollView(frame: NSRect(x:0,y:0,width:900,height:620))
  window.contentView = scroll; scroll.documentView = canvas; canvas.refresh(); canvas.centerRoot()
  let rootFrame = canvas.card(store.root.id)!
  assert(abs(scroll.contentView.bounds.midX - rootFrame.midX) < 2)
  assert(abs(scroll.contentView.bounds.midY - rootFrame.midY) < 2)
  let origin = scroll.contentView.bounds.origin
  canvas.pressedID = nil; canvas.panOrigin = origin; canvas.panStart = CGPoint(x:100,y:100)
  let drag = NSEvent.mouseEvent(with:.leftMouseDragged, location:CGPoint(x:140,y:130), modifierFlags:[], timestamp:0, windowNumber:window.windowNumber, context:nil, eventNumber:1, clickCount:1, pressure:1)!
  canvas.mouseDragged(with:drag)
  assert(abs(scroll.contentView.bounds.origin.x - (origin.x - 40)) < 2)
  assert(abs(scroll.contentView.bounds.origin.y - (origin.y + 30)) < 2)
  assert(canvas.depth(store.root.id) == 0)
  print("PASS: root centering and blank-canvas drag")
  let movingLeaf = MindNode(title: "Moving leaf")
  let moving = MindNode(title: "Moving", children: [movingLeaf])
  let target = MindNode(title: "Target")
  let dragStore = MindMapStore(root: MindNode(title: "Root", children: [moving, target]))
  let dragCanvas = MindCanvas(store: dragStore)
  scroll.documentView = dragCanvas; dragCanvas.refresh(); dragCanvas.centerRoot()
  func mouse(_ type: NSEvent.EventType, _ point: CGPoint) {
   let event = NSEvent.mouseEvent(with: type, location: dragCanvas.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
   switch type {
   case .leftMouseDown: dragCanvas.mouseDown(with: event)
   case .leftMouseDragged: dragCanvas.mouseDragged(with: event)
   default: dragCanvas.mouseUp(with: event)
   }
  }
  let original = dragCanvas.card(moving.id)!
  let leafOriginal = dragCanvas.card(movingLeaf.id)!
  let start = CGPoint(x: original.midX, y: original.midY)
  mouse(.leftMouseDown, start)
  mouse(.leftMouseDragged, CGPoint(x: start.x + 30, y: start.y + 20))
  assert(dragCanvas.card(moving.id) == original.offsetBy(dx: 30, dy: 20), "Dragged card must follow the pointer")
  assert(dragCanvas.card(movingLeaf.id) == leafOriginal.offsetBy(dx: 30, dy: 20), "Descendants must follow the dragged branch")
  mouse(.leftMouseUp, CGPoint(x: start.x + 30, y: start.y + 20))
  print("PASS: dragged subtree follows pointer")
  for orientation in [StrataLayoutOrientation.horizontal, .vertical] {
   dragStore.root = MindNode(title: "Root", children: [moving, target])
   dragCanvas.orientation = orientation; dragCanvas.refresh(); dragCanvas.centerRoot()
   let sourceRect = dragCanvas.card(moving.id)!
   let targetRect = dragCanvas.card(target.id)!
   let pointer = CGPoint(x: targetRect.midX, y: targetRect.midY)
   mouse(.leftMouseDown, CGPoint(x: sourceRect.midX, y: sourceRect.midY))
   mouse(.leftMouseDragged, pointer)
   assert(dragCanvas.drop?.0 == target.id && dragCanvas.drop?.1 == .inside, "Center drop must resolve a child destination")
   assert(dragStore.root.children.count == 2, "Hover must not mutate the document")
   assert(dragCanvas.dropPreview != nil, "Valid drop must expose a placeholder layout")
   let placeholder = dragCanvas.dropPreview!.frames[moving.id]!
   let live = dragCanvas.card(moving.id)!.offsetBy(dx: -dragCanvas.inset, dy: -dragCanvas.inset)
   let incoming = orientation == .horizontal ? CGPoint(x: live.minX, y: live.midY) : CGPoint(x: live.midX, y: live.minY)
   assert(dragCanvas.liveConnectors.contains { $0.to == incoming }, "Live connector must terminate on the moving card")
   let ghostIncoming = orientation == .horizontal ? CGPoint(x: placeholder.minX, y: placeholder.midY) : CGPoint(x: placeholder.midX, y: placeholder.minY)
   assert(dragCanvas.placeholderConnectors.contains { $0.to == ghostIncoming }, "Placeholder must have its own connector")
   let expected = dragCanvas.previewRoot!
   mouse(.leftMouseUp, pointer)
   assert(dragStore.root == expected, "Committed tree must match the preview")
   assert(dragStore.node(target.id)?.children.first?.id == moving.id)
  }
  print("PASS: child drop in both orientations")
  let preview = TextPreviewState()
  preview.text = store.textExport()
  let clipboard = NSPasteboard.withUniqueName()
  defer { clipboard.releaseGlobally() }
  let exported = preview.text
  assert(preview.copy(to: clipboard))
  assert(clipboard.string(forType: .string) == exported)
  assert(preview.text == nil && preview.copied, "Successful copy must dismiss the preview and publish success")
  assert(!preview.copy(to: clipboard), "Closed preview must not overwrite the clipboard")
  assert(clipboard.string(forType: .string) == exported)
  print("PASS: clipboard round trip, preview dismissal and success feedback")
  for orientation in [StrataLayoutOrientation.horizontal, .vertical] {
   for placement in [DropPlacement.before, .after] {
    let holder = MindNode(title: "Holder", children: [moving])
    dragStore.root = MindNode(title: "Root", children: [holder, target])
    dragCanvas.orientation = orientation; dragCanvas.refresh(); dragCanvas.centerRoot()
    let sourceRect = dragCanvas.card(moving.id)!
    let targetRect = dragCanvas.card(target.id)!
    let point = orientation == .horizontal
     ? CGPoint(x: targetRect.midX, y: placement == .before ? targetRect.minY - 4 : targetRect.maxY + 4)
     : CGPoint(x: placement == .before ? targetRect.minX - 4 : targetRect.maxX + 4, y: targetRect.midY)
    mouse(.leftMouseDown, CGPoint(x: sourceRect.midX, y: sourceRect.midY))
    mouse(.leftMouseDragged, point)
    assert(dragCanvas.drop?.0 == target.id && dragCanvas.drop?.1 == placement)
    let placeholder = dragCanvas.dropPreview!
    for _ in 0..<5 { mouse(.leftMouseDragged, point) }
    assert(dragCanvas.dropPreview == placeholder, "Stationary hover must not jitter")
    let ghost = placeholder.frames[moving.id]!.offsetBy(dx: dragCanvas.inset, dy: dragCanvas.inset)
    let screenGhost = dragCanvas.convert(ghost, to: nil)
    mouse(.leftMouseUp, point)
    assert(dragCanvas.convert(dragCanvas.card(moving.id)!, to: nil) == screenGhost, "Release must land exactly on the placeholder")
    let expected = placement == .before ? [holder.id, moving.id, target.id] : [holder.id, target.id, moving.id]
    assert(dragStore.root.children.map(\.id) == expected)
   }
   dragStore.root = MindNode(title: "Root", children: [moving, target])
   dragCanvas.refresh(); dragCanvas.centerRoot()
   let sourceRect = dragCanvas.card(moving.id)!
   let descendantRect = dragCanvas.card(movingLeaf.id)!
   mouse(.leftMouseDown, CGPoint(x: sourceRect.midX, y: sourceRect.midY))
   mouse(.leftMouseDragged, CGPoint(x: descendantRect.midX, y: descendantRect.midY))
   assert(dragCanvas.drop == nil && dragCanvas.dropPreview == nil, "Descendants must not accept a drop")
   let targetRect = dragCanvas.card(target.id)!
   mouse(.leftMouseDragged, CGPoint(x: targetRect.midX, y: targetRect.midY))
   assert(dragCanvas.dropPreview != nil)
   let beforeCancel = dragStore.root
   let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53)!
   dragCanvas.keyDown(with: escape)
   mouse(.leftMouseUp, CGPoint(x: targetRect.midX, y: targetRect.midY))
   assert(dragStore.root == beforeCancel && dragCanvas.dropPreview == nil && !dragCanvas.dragging)
  }
  print("PASS: sibling zones, stable placeholders, exact landing, cycle rejection and Escape cancellation in both layouts")
  _ = app
 }
}
