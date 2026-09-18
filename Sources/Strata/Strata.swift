import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let newStrataDocument = Notification.Name("newStrataDocument")
    static let clearStrataDocument = Notification.Name("clearStrataDocument")
}

@MainActor
final class TextPreviewState: ObservableObject {
    @Published var text: String?
    @Published var copied = false
    @Published var copyError = ""

    @discardableResult
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let text else { return false }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string), pasteboard.string(forType: .string) == text else {
            copyError = "复制失败，请重试。"
            return false
        }
        self.text = nil
        copyError = ""
        copied = true
        return true
    }
}

struct ContentView: View {
    @ObservedObject var store: MindMapStore
    @ObservedObject var library: MaterialLibraryStore
    @State private var orientation = StrataLayoutOrientation.horizontal
    @State private var error = ""
    @StateObject private var preview = TextPreviewState()
    @StateObject private var ai = AIWorkflow()
    @State private var showAI = false
    @State private var showLibrary = false
    @State private var resetAction: ResetAction?
    @State private var optimizeTask: Task<Void, Never>?
    @State private var confirmOptimize = false

    enum ResetAction: String, Identifiable {
        case new = "新建工作"
        case clear = "清空画布"
        var id: Self { self }
    }

    var body: some View {
        HStack(spacing: 0) {
            NativeCanvas(store: store, orientation: orientation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showLibrary {
                Divider()
                MaterialLibraryPanel(library: library, store: store) { showLibrary = false }
            }
        }
            .toolbar {
                Button {
                    requestReset(.new)
                } label: { Label("新建", systemImage: "plus") }
                    .help("新建工作（⌘N）")
                    .accessibilityIdentifier("new-document")
                Button {
                    requestReset(.clear)
                } label: { Label("清空", systemImage: "trash") }
                    .help("清空当前画布")
                    .accessibilityIdentifier("clear-document")
                Button("打开") { open() }
                Button("保存") { save() }
                LayoutSwitch(orientation: $orientation)
                Button {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    showLibrary.toggle()
                } label: { Label("素材库", systemImage: "square.grid.2x2") }
                    .help("显示或收起素材库")
                    .accessibilityIdentifier("material-library-toggle")
                Button {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    showAI = true
                } label: { Label("AI 整理", systemImage: "sparkles") }
                    .help("根据材料生成思维导图")
                    .disabled(ai.isOptimizing)
                Button {
                    confirmOptimize = true
                } label: { Label("AI 优化", systemImage: "wand.and.stars") }
                    .help("将当前思考结构整理为可直接使用的提示词")
                    .disabled(store.isEmptyDocument || ai.isGenerating || ai.isOptimizing || ai.configuration.model.isEmpty)
                Button("复制提示词") { copyPrompt() }
                    .help("将整理好的提示词直接复制到剪贴板")
                    .disabled(store.isEmptyDocument)
            }
            .sheet(isPresented: $showAI) { AIGenerationSheet(workflow: ai, store: store) }
            .alert("优化当前导图？", isPresented: $confirmOptimize) {
                Button("取消", role: .cancel) {}
                Button("开始优化") { startOptimization() }
            } message: {
                Text("AI 会保留现有意图和事实，整理逻辑与表达，并标出影响执行的关键信息缺口。成功后替换当前导图；失败或取消不会改变内容。")
            }
            .confirmationDialog(
                resetAction?.rawValue ?? "",
                isPresented: Binding(
                    get: { resetAction != nil },
                    set: { if !$0 { resetAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let resetAction {
                    Button(resetAction.rawValue, role: .destructive) { reset() }
                }
                Button("取消", role: .cancel) { resetAction = nil }
            } message: {
                Text("当前内容尚未自动保存。继续后将从空白主题开始。")
            }
            .overlay(alignment: .top) {
                if preview.copied {
                    Label("复制成功", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                        .task {
                            do { try await Task.sleep(for: .seconds(2)) } catch { return }
                            preview.copied = false
                        }
                }
            }
            .overlay {
                if ai.isOptimizing {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("AI 正在优化提示词").font(.headline)
                        AIElapsedStatus(title: "正在调整结构与表达", startedAt: ai.startedAt)
                            .frame(width: 280)
                        HStack {
                            Spacer()
                            Button("取消") { optimizeTask?.cancel() }
                        }
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 12)
                }
            }
            .alert("操作失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
                Button("好") { error = "" }
            } message: { Text(error) }
            .onReceive(NotificationCenter.default.publisher(for: .newStrataDocument)) { _ in requestReset(.new) }
            .onReceive(NotificationCenter.default.publisher(for: .clearStrataDocument)) { _ in requestReset(.clear) }
    }
    private func requestReset(_ action: ResetAction) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if store.isEmptyDocument { reset() }
        else { resetAction = action }
    }
    private func reset() {
        resetAction = nil
        preview.text = nil
        preview.copied = false
        preview.copyError = ""
        showAI = false
        optimizeTask?.cancel()
        store.reset()
    }
    private func copyPrompt() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        preview.copied = false
        preview.copyError = ""
        preview.text = store.textExport()
        if !preview.copy() { error = preview.copyError }
    }
    private func startOptimization() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        optimizeTask = Task {
            let succeeded = await ai.optimize(store)
            if !succeeded, !ai.error.isEmpty { error = ai.error }
            optimizeTask = nil
        }
    }
    private func open() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.open(url) } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Strata.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.save(url) } catch { self.error = error.localizedDescription }
        }
    }
}

struct DocumentCommands: Commands {
    let newDocument: () -> Void
    let clearDocument: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建工作", action: newDocument)
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .pasteboard) {
            Button("清空画布", action: clearDocument)
        }
    }
}

struct NativeCanvas: NSViewRepresentable {
    let store: MindMapStore
    let orientation: StrataLayoutOrientation
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CanvasScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let canvas = MindCanvas(store: store)
        scroll.documentView = canvas
        canvas.refresh()
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let canvas = scroll.documentView as? MindCanvas else { return }
        canvas.orientation = orientation
        canvas.refresh()
    }
}

final class CanvasScrollView: NSScrollView {
    static let minimumZoom: CGFloat = 0.25
    static let maximumZoom: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        allowsMagnification = true
        minMagnification = Self.minimumZoom
        maxMagnification = Self.maximumZoom
    }
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        guard newSize != frame.size, let canvas = documentView as? MindCanvas,
              canvas.treeLayout != nil, contentView.bounds.width > 0, contentView.bounds.height > 0 else {
            super.setFrameSize(newSize)
            return
        }
        let center = CGPoint(x: contentView.bounds.midX - canvas.inset, y: contentView.bounds.midY - canvas.inset)
        let previousRoot = canvas.centeredRoot
        let previousFocus = canvas.handledFocusRequest
        super.setFrameSize(newSize)
        tile()
        canvas.refresh()
        guard previousRoot == canvas.centeredRoot, previousFocus == canvas.handledFocusRequest else { return }
        contentView.scroll(to: CGPoint(
            x: center.x + canvas.inset - contentView.bounds.width / 2,
            y: center.y + canvas.inset - contentView.bounds.height / 2
        ))
        reflectScrolledClipView(contentView)
    }

    func zoom(to value: CGFloat, at point: CGPoint) {
        let scale = min(Self.maximumZoom, max(Self.minimumZoom, value))
        guard scale != magnification else { return }
        let before = contentView.bounds
        let fraction = CGPoint(x: (point.x - before.minX) / before.width, y: (point.y - before.minY) / before.height)
        magnification = scale
        let after = contentView.bounds
        contentView.scroll(to: CGPoint(x: point.x - fraction.x * after.width, y: point.y - fraction.y * after.height))
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let canvas = documentView as? MindCanvas, !canvas.dragging else { return }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        let step = max(-0.4, min(0.4, delta * (event.hasPreciseScrollingDeltas ? 0.008 : 0.1)))
        zoom(to: magnification * exp(step), at: canvas.convert(event.locationInWindow, from: nil))
    }
}

final class CanvasTextView: NSTextView {
    override func scrollWheel(with event: NSEvent) { enclosingScrollView?.scrollWheel(with: event) }
}

final class MindCanvas: NSView, NSTextViewDelegate {
    let store: MindMapStore
    var orientation = StrataLayoutOrientation.horizontal
    var treeLayout: TreeLayout!
    var editor: NSTextView?
    var editingID: UUID?
    var pressedID: UUID?
    var pressedDisclosure = false
    var downPoint = CGPoint.zero
    var dragging = false
    var dragOffset = CGSize.zero
    var draggedIDs = Set<UUID>()
    var drop: (UUID, DropPlacement)?
    var dropPreview: TreeLayout?
    var previewRoot: MindNode?
    var inset: CGFloat {
        let viewport = enclosingScrollView?.contentView.frame.size ?? CGSize(width: 900, height: 620)
        return max(1600, max(viewport.width, viewport.height) / CanvasScrollView.minimumZoom / 2 + 64)
    }
    var centeredRoot: UUID?
    var handledFocusRequest: UUID?
    var panStart = CGPoint.zero
    var panOrigin = CGPoint.zero
    func depth(_ id: UUID) -> Int {
        func visit(_ node: MindNode, _ level: Int) -> Int? {
            if node.id == id { return level }
            for child in node.children { if let found = visit(child, level + 1) { return found } }
            return nil
        }
        return min(visit(store.root, 0) ?? 0, 3)
    }
    func centerRoot() {
        if centerNode(store.root.id) { centeredRoot = store.root.id }
    }
    @discardableResult
    func centerNode(_ id: UUID) -> Bool {
        guard let scroll = enclosingScrollView, let rect = card(id), scroll.contentView.bounds.width > 0 else { return false }
        let viewport = scroll.contentView.bounds.size
        scroll.contentView.scroll(to: CGPoint(x: rect.midX - viewport.width / 2, y: rect.midY - viewport.height / 2))
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(store: MindMapStore) { self.store = store; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        let overrides = editingID.flatMap { id in editor.map { [id: $0.string] } } ?? [:]
        treeLayout = TreeLayoutEngine.layout(root: store.root, orientation: orientation, titleOverrides: overrides)
        let viewport = enclosingScrollView?.contentSize ?? CGSize(width: 900, height: 620)
        setFrameSize(CGSize(width: max(viewport.width, treeLayout.contentSize.width + inset * 2), height: max(viewport.height, treeLayout.contentSize.height + inset * 2)))
        if let id = editingID, let rect = card(id), let editor {
            let height = NodeSizing.size(for: editor.string).height - 16
            editor.frame = CGRect(x: rect.minX + 12, y: rect.midY - height / 2, width: rect.width - 24, height: height)
        }
        if centeredRoot != store.root.id { centerRoot() }
        if let request = store.focusRequest, handledFocusRequest != request.id, centerNode(request.nodeID) {
            handledFocusRequest = request.id
            if request.activateCanvas, editingID == nil { window?.makeFirstResponder(self) }
        }
        needsDisplay = true
    }
    func card(_ id: UUID) -> CGRect? {
        if draggedIDs.contains(id) {
            return treeLayout.frames[id]?.offsetBy(dx: inset + dragOffset.width, dy: inset + dragOffset.height)
        }
        return (dropPreview ?? treeLayout).frames[id]?.offsetBy(dx: inset, dy: inset)
    }
    var visibleIDs: Set<UUID> { Set(treeLayout.frames.keys).union(dropPreview?.frames.keys.map { $0 } ?? []) }
    func hit(_ point: CGPoint) -> UUID? { visibleIDs.first { card($0)?.contains(point) == true } }
    func disclosureRect(_ id: UUID) -> CGRect? {
        guard let node = store.node(id), !node.children.isEmpty, let rect = card(id) else { return nil }
        return orientation == .horizontal
            ? CGRect(x: rect.maxX + 8, y: rect.midY - 9, width: 18, height: 18)
            : CGRect(x: rect.midX - 9, y: rect.maxY + 8, width: 18, height: 18)
    }
    func toggleCollapsed(_ id: UUID) {
        finishEditing(commit: true)
        guard let before = card(id), store.toggleCollapsed(id) else { return }
        refresh()
        if let after = card(id), let scroll = enclosingScrollView {
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: CGPoint(x: origin.x + after.midX - before.midX, y: origin.y + after.midY - before.midY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    var liveConnectors: [TreeConnector] {
        guard dragging else { return treeLayout.connectors }
        let frames = visibleIDs.reduce(into: [UUID: CGRect]()) { result, id in
            result[id] = card(id)?.offsetBy(dx: -inset, dy: -inset)
        }
        return connectors(root: previewRoot ?? store.root, frames: frames)
    }
    var placeholderConnectors: [TreeConnector] {
        guard let dropPreview, let previewRoot else { return [] }
        return connectors(root: previewRoot, frames: dropPreview.frames, onlyDragged: true)
    }
    func connectors(root: MindNode, frames: [UUID: CGRect], onlyDragged: Bool = false) -> [TreeConnector] {
        var result: [TreeConnector] = []
        func visit(_ parent: MindNode) {
            guard let parentFrame = frames[parent.id] else { return }
            for child in parent.children {
                if let childFrame = frames[child.id], !onlyDragged || draggedIDs.contains(child.id) {
                    let from: CGPoint
                    let to: CGPoint
                    let bend1: CGPoint
                    let bend2: CGPoint
                    if orientation == .horizontal {
                        from = CGPoint(x: parentFrame.maxX, y: parentFrame.midY)
                        to = CGPoint(x: childFrame.minX, y: childFrame.midY)
                        let x = from.x + max(16, (to.x - from.x) / 2)
                        bend1 = CGPoint(x: x, y: from.y); bend2 = CGPoint(x: x, y: to.y)
                    } else {
                        from = CGPoint(x: parentFrame.midX, y: parentFrame.maxY)
                        to = CGPoint(x: childFrame.midX, y: childFrame.minY)
                        let y = from.y + max(16, (to.y - from.y) / 2)
                        bend1 = CGPoint(x: from.x, y: y); bend2 = CGPoint(x: to.x, y: y)
                    }
                    result += [TreeConnector(from: from, to: bend1), TreeConnector(from: bend1, to: bend2), TreeConnector(from: bend2, to: to)]
                }
                visit(child)
            }
        }
        visit(root)
        return result
    }
    func stroke(_ connectors: [TreeConnector], dashed: Bool = false) {
        (dashed ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        let lines = NSBezierPath(); lines.lineWidth = dashed ? 2 : 1.5
        if dashed { lines.setLineDash([6, 4], count: 2, phase: 0) }
        for line in connectors {
            lines.move(to: CGPoint(x: line.from.x + inset, y: line.from.y + inset))
            lines.line(to: CGPoint(x: line.to.x + inset, y: line.to.y + inset))
        }
        lines.stroke()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        guard treeLayout != nil else { return }
        stroke(liveConnectors)
        stroke(placeholderConnectors, dashed: true)
        if let dropPreview {
            for id in draggedIDs {
                guard let frame = dropPreview.frames[id] else { continue }
                let rect = frame.offsetBy(dx: inset, dy: inset)
                let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
                NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); path.fill()
                NSColor.controlAccentColor.setStroke(); path.lineWidth = 2
                path.setLineDash([6, 4], count: 2, phase: 0); path.stroke()
            }
        }
        let orderedIDs = visibleIDs.sorted { !draggedIDs.contains($0) && draggedIDs.contains($1) }
        for id in orderedIDs {
            guard let node = store.node(id), let rect = card(id) else { continue }
            let selected = store.selectedID == id
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            let level = depth(id)
            let colors: [NSColor] = [.systemIndigo, .systemBlue, .systemTeal, .systemGray]
            let color = colors[level]
            if draggedIDs.contains(id) {
                NSColor.windowBackgroundColor.setFill(); path.fill()
            }
            (level == 0 ? color : color.withAlphaComponent(selected ? 0.25 : (level == 1 ? 0.16 : 0.07))).setFill(); path.fill()
            (selected ? NSColor.controlAccentColor : color.withAlphaComponent(0.6)).setStroke()
            path.lineWidth = editingID == id ? 3 : (selected ? 2.5 : 1); path.stroke()
            if selected {
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -4), xRadius: 11, yRadius: 11)
                ring.lineWidth = 1.5; ring.stroke()
            }
            if editingID != id {
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping; paragraph.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [.font: NodeSizing.font, .foregroundColor: level == 0 ? NSColor.white : NSColor.labelColor, .paragraphStyle: paragraph]
                let height = (node.title as NSString).boundingRect(with: CGSize(width: rect.width - 24, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).height
                let textRect = CGRect(x: rect.minX + 12, y: rect.midY - ceil(height) / 2, width: rect.width - 24, height: ceil(height))
                (node.title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
            }
            if let button = disclosureRect(id) {
                let circle = NSBezierPath(ovalIn: button)
                NSColor.windowBackgroundColor.setFill(); circle.fill()
                NSColor.secondaryLabelColor.setStroke(); circle.lineWidth = 1; circle.stroke()
                let symbol = NSBezierPath(); symbol.lineWidth = 1.5
                symbol.move(to: CGPoint(x: button.minX + 5, y: button.midY))
                symbol.line(to: CGPoint(x: button.maxX - 5, y: button.midY))
                if node.isCollapsed && !(drop?.0 == id && drop?.1 == .inside) {
                    symbol.move(to: CGPoint(x: button.midX, y: button.minY + 5))
                    symbol.line(to: CGPoint(x: button.midX, y: button.maxY - 5))
                }
                symbol.stroke()
            }
        }
        if let (id, placement) = drop, let rect = card(id) {
            NSColor.controlAccentColor.setStroke()
            let mark = NSBezierPath(); mark.lineWidth = 4
            if placement == .inside { mark.appendRoundedRect(rect.insetBy(dx: -4, dy: -4), xRadius: 10, yRadius: 10) }
            else if orientation == .horizontal {
                let y = placement == .before ? rect.minY - 5 : rect.maxY + 5
                mark.move(to: CGPoint(x: rect.minX, y: y)); mark.line(to: CGPoint(x: rect.maxX, y: y))
            } else {
                let x = placement == .before ? rect.minX - 5 : rect.maxX + 5
                mark.move(to: CGPoint(x: x, y: rect.minY)); mark.line(to: CGPoint(x: x, y: rect.maxY))
            }
            mark.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) {
        finishEditing(commit: true)
        window?.makeFirstResponder(self)
        downPoint = convert(event.locationInWindow, from: nil)
        panStart = event.locationInWindow
        panOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        pressedDisclosure = false
        if let id = visibleIDs.first(where: { disclosureRect($0)?.insetBy(dx: -3, dy: -3).contains(downPoint) == true }) {
            pressedID = nil; resetDrag(); pressedDisclosure = true
            store.select(id)
            if event.clickCount == 1 { toggleCollapsed(id) }
            needsDisplay = true
            return
        }
        pressedID = hit(downPoint); resetDrag()
        store.selectedID = pressedID
        if event.clickCount == 2, let id = pressedID { beginEditing(id) }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !pressedDisclosure else { return }
        if pressedID == nil, let scroll = enclosingScrollView {
            NSCursor.closedHand.set()
            let p = event.locationInWindow
            scroll.contentView.scroll(to: CGPoint(x: panOrigin.x - (p.x - panStart.x) / scroll.magnification, y: panOrigin.y + (p.y - panStart.y) / scroll.magnification))
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        guard let source = pressedID, source != store.root.id, editingID == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard dragging || hypot(point.x - downPoint.x, point.y - downPoint.y) * (enclosingScrollView?.magnification ?? 1) > 5 else { return }
        dragging = true
        autoscroll(with: event)
        let current = convert(event.locationInWindow, from: nil)
        dragOffset = CGSize(width: current.x - downPoint.x, height: current.y - downPoint.y)
        func collect(_ node: MindNode) {
            draggedIDs.insert(node.id)
            node.children.forEach(collect)
        }
        if let node = store.node(source) { collect(node) }
        updateDrop(at: current, source: source)
        NSCursor.closedHand.set()
        needsDisplay = true
    }
    func updateDrop(at point: CGPoint, source: UUID) {
        // Hit-test the stationary cards, never the branch following the pointer.
        let candidates = treeLayout.frames.keys.filter { !draggedIDs.contains($0) }
        let target = candidates.filter { id in
            guard let rect = card(id) else { return false }
            return rect.insetBy(dx: -12, dy: -12).contains(point)
        }.min { a, b in
            let a = card(a)!, b = card(b)!
            return hypot(point.x - a.midX, point.y - a.midY) < hypot(point.x - b.midX, point.y - b.midY)
        }
        guard let target, let rect = card(target) else {
            drop = nil; dropPreview = nil; previewRoot = nil; return
        }
        let fraction = orientation == .horizontal ? (point.y - rect.minY) / rect.height : (point.x - rect.minX) / rect.width
        let placement: DropPlacement = fraction < 0.25 ? .before : (fraction > 0.75 ? .after : .inside)
        if drop?.0 == target, drop?.1 == placement { return }
        let candidate = MindMapStore(root: store.root)
        guard candidate.move(source, relativeTo: target, placement: placement), candidate.root != store.root else {
            drop = nil; dropPreview = nil; previewRoot = nil; return
        }
        let layout = TreeLayoutEngine.layout(root: candidate.root, orientation: orientation)
        guard let targetFrame = layout.frames[target] else { return }
        // Anchor the hovered card so the preview cannot move its own drop zone.
        let dx = rect.minX - inset - targetFrame.minX
        let dy = rect.minY - inset - targetFrame.minY
        dropPreview = TreeLayout(
            frames: layout.frames.mapValues { $0.offsetBy(dx: dx, dy: dy) },
            connectors: layout.connectors.map {
                TreeConnector(from: CGPoint(x: $0.from.x + dx, y: $0.from.y + dy), to: CGPoint(x: $0.to.x + dx, y: $0.to.y + dy))
            },
            contentSize: layout.contentSize
        )
        previewRoot = candidate.root
        drop = (target, placement)
    }
    override func mouseUp(with event: NSEvent) {
        NSCursor.arrow.set()
        let previewRootFrame = dropPreview?.frames[store.root.id]
        var moved = false
        if dragging, let source = pressedID, let (target, placement) = drop {
            moved = store.move(source, relativeTo: target, placement: placement)
        }
        resetDrag(); pressedID = nil; pressedDisclosure = false; refresh()
        if moved, let previewRootFrame, let frame = treeLayout.frames[store.root.id], let scroll = enclosingScrollView {
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: CGPoint(x: origin.x + frame.minX - previewRootFrame.minX, y: origin.y + frame.minY - previewRootFrame.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    func resetDrag() {
        drop = nil; dragging = false; dragOffset = .zero; draggedIDs.removeAll()
        dropPreview = nil; previewRoot = nil
    }
    override func keyDown(with event: NSEvent) {
        if dragging {
            if event.keyCode == 53 { resetDrag(); pressedID = nil; NSCursor.arrow.set(); refresh() }
            return
        }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { super.keyDown(with: event); return }
        let directions: [UInt16: NodeNavigationDirection] = [123: .parent, 124: .child, 126: .previous, 125: .next]
        if let direction = directions[event.keyCode] {
            let destination = store.navigate(direction)
            refresh()
            if let rect = card(destination) { scrollToVisible(rect.insetBy(dx: -30, dy: -30)) }
            return
        }
        guard let id = store.selectedID else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 36, 76:
            if let created = id == store.root.id ? store.createChild(of: id) : store.createSibling(after: id) { refresh(); beginEditing(created) }
        case 48:
            if let created = store.createChild(of: id) { refresh(); beginEditing(created) }
        case 51, 117: store.delete(id); refresh()
        case 49: toggleCollapsed(id)
        default: super.keyDown(with: event)
        }
    }
    func beginEditing(_ id: UUID) {
        guard let node = store.node(id), let rect = card(id) else { return }
        editingID = id
        let text = CanvasTextView(frame: rect.insetBy(dx: 12, dy: 8))
        text.isRichText = false; text.drawsBackground = false; text.font = NodeSizing.font
        text.textColor = depth(id) == 0 ? .white : .labelColor; text.insertionPointColor = depth(id) == 0 ? .white : .controlAccentColor
        text.alignment = .center
        text.textContainerInset = .zero; text.textContainer?.lineFragmentPadding = 0
        text.isHorizontallyResizable = false; text.isVerticallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.string = node.title; text.delegate = self
        editor = text; addSubview(text); window?.makeFirstResponder(text); text.selectAll(nil)
        scrollToVisible(rect.insetBy(dx: -30, dy: -30)); needsDisplay = true
    }
    func finishEditing(commit: Bool) {
        guard let id = editingID else { return }
        let value = editor?.string ?? ""
        editingID = nil
        editor?.delegate = nil; editor?.removeFromSuperview(); editor = nil
        if commit { store.rename(id, to: value) }
        window?.makeFirstResponder(self); refresh()
    }
    func textDidChange(_ notification: Notification) { refresh() }
    func textDidEndEditing(_ notification: Notification) { finishEditing(commit: true) }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finishEditing(commit: true); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishEditing(commit: false); return true }
        return false
    }
}
