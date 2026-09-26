import AppKit

/// Minimal two-way channel between the canvas and the SwiftUI toolbar so the
/// canvas stays free of SwiftUI dependencies.
@MainActor
final class CanvasBridge: ObservableObject {
    var selectedNodeCount = 0 {
        didSet {
            if oldValue != selectedNodeCount { objectWillChange.send() }
        }
    }
    weak var canvas: MindCanvas?

    func requestAnnotation() {
        canvas?.createAnnotationFromSelection()
    }
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

    // Batch drag: extra selected branches that follow the pressed branch.
    var multiDragExtras: [UUID] = []
    private var multiDragArmed = false

    // Group annotations (braces). Selection and inline label editing.
    var selectedAnnotationID: UUID?
    var pressedAnnotationID: UUID?
    var annotationEditor: NSTextView?
    var editingAnnotationID: UUID?

    // Lightweight bridge to the SwiftUI toolbar (multi-selection count and
    // annotation requests). The canvas owns no SwiftUI dependencies.
    var bridge: CanvasBridge?

    // Multi-selection lives at the canvas interaction layer. The store keeps a
    // single primary selection so existing tree commands and insertion logic
    // continue to behave deterministically.
    private(set) var selectedNodeIDs = Set<UUID>()
    private var marqueeStart: CGPoint?
    private var marqueeRect: CGRect?
    private var marqueeDidDrag = false
    private var commandSelectionAnchorID: UUID?

    var inset: CGFloat {
        let viewport = enclosingScrollView?.contentSize ?? CGSize(width: 900, height: 620)
        // Margin must keep a centered viewport valid at the minimum zoom, or
        // autoscroll clamps the origin mid-drag and the canvas jumps.
        return max(1600, max(viewport.width, viewport.height) / CanvasScrollView.minimumZoom / 2 + 64)
    }
    var centeredRoot: UUID?
    var handledFocusRequest: UUID?
    var panStart = CGPoint.zero
    var panOrigin = CGPoint.zero

    func depth(_ id: UUID) -> Int {
        func visit(_ node: MindNode, _ level: Int) -> Int? {
            if node.id == id { return level }
            for child in node.children {
                if let found = visit(child, level + 1) { return found }
            }
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

    init(store: MindMapStore) {
        self.store = store
        super.init(frame: .zero)
        if let selectedID = store.selectedID { selectedNodeIDs = [selectedID] }
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        if let id = editingAnnotationID, store.annotation(id) == nil {
            finishAnnotationEditing(commit: false)
        }
        let overrides = editingID.flatMap { id in editor.map { [id: $0.string] } } ?? [:]
        treeLayout = TreeLayoutEngine.layout(root: store.root, orientation: orientation, titleOverrides: overrides)
        let viewport = enclosingScrollView?.contentSize ?? CGSize(width: 900, height: 620)
        setFrameSize(CGSize(
            width: max(viewport.width, treeLayout.contentSize.width + inset * 2),
            height: max(viewport.height, treeLayout.contentSize.height + inset * 2)
        ))

        selectedNodeIDs = selectedNodeIDs.filter { store.node($0) != nil }
        if let primary = store.selectedID {
            if !selectedNodeIDs.contains(primary) { selectedNodeIDs = [primary] }
        } else if !selectedNodeIDs.isEmpty {
            store.selectedID = selectedNodeIDs.first
        }
        bridge?.selectedNodeCount = selectedNodeIDs.count

        if let id = editingID, let rect = card(id), let editor {
            let height = NodeSizing.size(for: editor.string).height - 16
            editor.frame = CGRect(x: rect.minX + 12, y: rect.midY - height / 2, width: rect.width - 24, height: height)
        }
        if let id = editingAnnotationID, let labelRect = annotationLabelRect(id), let annotationEditor {
            annotationEditor.frame = labelRect
        }

        if let scroll = enclosingScrollView, scroll.contentView.bounds.width > 0 {
            let hasPendingFocus = store.focusRequest.flatMap { $0.id != handledFocusRequest } ?? false
            if centeredRoot != store.root.id {
                centeredRoot = store.root.id
                // A pending focus request repositions the viewport itself, so
                // the initial root centering would only fight it.
                if !hasPendingFocus { centerNode(store.root.id) }
            }
            if let request = store.focusRequest, handledFocusRequest != request.id, centerNode(request.nodeID) {
                handledFocusRequest = request.id
                if request.activateCanvas, editingID == nil { window?.makeFirstResponder(self) }
            }
        }
        needsDisplay = true
    }

    func attachBridge(_ bridge: CanvasBridge) {
        self.bridge = bridge
        bridge.canvas = self
        bridge.selectedNodeCount = selectedNodeIDs.count
    }

    func card(_ id: UUID) -> CGRect? {
        if draggedIDs.contains(id) {
            return treeLayout.frames[id]?.offsetBy(dx: inset + dragOffset.width, dy: inset + dragOffset.height)
        }
        if dragging, multiDragExtras.contains(id) {
            return treeLayout.frames[id]?.offsetBy(dx: inset + dragOffset.width, dy: inset + dragOffset.height)
        }
        return (dropPreview ?? treeLayout).frames[id]?.offsetBy(dx: inset, dy: inset)
    }

    var visibleIDs: Set<UUID> {
        Set(treeLayout.frames.keys).union(dropPreview?.frames.keys.map { $0 } ?? [])
    }

    func hit(_ point: CGPoint) -> UUID? {
        visibleIDs.first { card($0)?.contains(point) == true }
    }

    func disclosureRect(_ id: UUID) -> CGRect? {
        guard let node = store.node(id), !node.children.isEmpty, let rect = card(id) else { return nil }
        return orientation == .horizontal
            ? CGRect(x: rect.maxX + 8, y: rect.midY - 9, width: 18, height: 18)
            : CGRect(x: rect.midX - 9, y: rect.maxY + 8, width: 18, height: 18)
    }

    // MARK: - Group annotation geometry

    struct AnnotationGeometry {
        var braceStart = CGPoint.zero
        var braceEnd = CGPoint.zero
        var segmentHeight: CGFloat = 9
        var armLength: CGFloat = 18
        var pointingRight = true
    }

    private var annotationFont: NSFont { NSFont.systemFont(ofSize: 12) }

    /// Vertical extent and right edge covered by the annotation's live member
    /// cards. In vertical layouts the brace hangs below the members, so the
    /// "right edge" tracks the horizontal center of the group.
    private func annotationMemberExtent(_ annotation: GroupAnnotation) -> (minY: CGFloat, maxY: CGFloat, maxX: CGFloat)? {
        var minY: CGFloat?
        var maxY: CGFloat?
        var maxX: CGFloat?
        for id in annotation.memberIDs {
            guard let rect = memberCard(id) else { continue }
            minY = min(minY ?? rect.minY, rect.minY)
            maxY = max(maxY ?? rect.maxY, rect.maxY)
            let rightEdge = orientation == .horizontal ? rect.maxX : rect.midX
            maxX = max(maxX ?? rightEdge, rightEdge)
        }
        guard let minY, let maxY, let maxX else { return nil }
        return (minY, maxY, maxX)
    }

    /// Card for annotation geometry: follows live drags so the brace tracks
    /// members being moved. Falls back to the final preview frame.
    private func memberCard(_ id: UUID) -> CGRect? {
        if draggedIDs.contains(id) || (dragging && multiDragExtras.contains(id)) {
            return treeLayout.frames[id]?.offsetBy(dx: inset + dragOffset.width, dy: inset + dragOffset.height)
        }
        if let preview = dropPreview, preview.frames[id] != nil {
            return preview.frames[id]?.offsetBy(dx: inset, dy: inset)
        }
        return treeLayout.frames[id]?.offsetBy(dx: inset, dy: inset)
    }

    func annotationGeometry(_ annotationID: UUID) -> AnnotationGeometry? {
        guard let annotation = store.annotation(annotationID) else { return nil }
        guard let extent = annotationMemberExtent(annotation) else { return nil }
        var geometry = AnnotationGeometry()
        geometry.braceStart = CGPoint(x: extent.maxX + 14, y: extent.minY)
        geometry.braceEnd = CGPoint(x: extent.maxX + 14, y: extent.maxY)
        geometry.pointingRight = true
        return geometry
    }

    /// Hit area of the annotation itself — the brace band and the label — for
    /// selection and double-click editing. Member cards stay clickable as
    /// normal nodes and are deliberately excluded.
    func annotationHitRects(_ annotationID: UUID) -> [CGRect]? {
        guard let annotation = store.annotation(annotationID) else { return nil }
        var total = CGRect.null
        for id in annotation.memberIDs {
            guard let rect = memberCard(id) else { continue }
            total = total.union(rect)
        }
        guard !total.isNull else { return nil }
        var rects: [CGRect] = []
        let braceBand: CGFloat = 40
        if orientation == .horizontal {
            rects.append(CGRect(x: total.maxX + 6, y: total.minY, width: braceBand, height: total.height))
        } else {
            rects.append(CGRect(x: total.minX, y: total.maxY + 6, width: total.width, height: braceBand))
        }
        if let labelRect = annotationLabelRect(annotationID) {
            rects.append(labelRect)
        }
        return rects
    }

    func annotationLabelRect(_ annotationID: UUID) -> CGRect? {
        guard let annotation = store.annotation(annotationID) else { return nil }
        guard let extent = annotationMemberExtent(annotation) else { return nil }
        let font = annotationFont
        let width = min(300, max(60, (annotation.label as NSString).size(withAttributes: [.font: font]).width + 24))
        let singleLineHeight = font.boundingRectForFont.height + 10
        let wrapped = (annotation.label as NSString).boundingRect(
            with: CGSize(width: width - 12, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let height = max(singleLineHeight, ceil(wrapped.height) + 10)
        if orientation == .horizontal {
            let x = extent.maxX + 14 + 18 + 8
            return CGRect(x: x, y: extent.minY + (extent.maxY - extent.minY) / 2 - height / 2, width: width, height: height)
        } else {
            return CGRect(x: extent.maxX + 14, y: extent.maxY + 14 + 8, width: width, height: height)
        }
    }

    func hitAnnotation(_ point: CGPoint) -> UUID? {
        for annotation in store.annotations {
            if let rects = annotationHitRects(annotation.id),
               rects.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
                return annotation.id
            }
        }
        return nil
    }

    private func drawAnnotations() {
        for annotation in store.annotations {
            guard let geometry = annotationGeometry(annotation.id) else { continue }
            let selected = selectedAnnotationID == annotation.id
            let color = selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            color.setStroke()
            color.withAlphaComponent(0.75).setFill()
            let brace = NSBezierPath()
            brace.lineWidth = selected ? 2 : 1.5
            let tipX = geometry.braceStart.x + geometry.armLength
            // Right-pointing brace: { — tip on the right, arms on the left.
            brace.move(to: CGPoint(x: geometry.braceStart.x, y: geometry.braceStart.y))
            brace.curve(
                to: CGPoint(x: tipX, y: (geometry.braceStart.y + geometry.braceEnd.y) / 2),
                controlPoint1: CGPoint(x: geometry.braceStart.x + geometry.armLength * 0.6, y: geometry.braceStart.y),
                controlPoint2: CGPoint(x: tipX - geometry.armLength * 0.45, y: (geometry.braceStart.y + geometry.braceEnd.y) / 2 - geometry.segmentHeight)
            )
            brace.curve(
                to: CGPoint(x: geometry.braceStart.x, y: geometry.braceEnd.y),
                controlPoint1: CGPoint(x: tipX - geometry.armLength * 0.45, y: (geometry.braceStart.y + geometry.braceEnd.y) / 2 + geometry.segmentHeight),
                controlPoint2: CGPoint(x: geometry.braceStart.x + geometry.armLength * 0.6, y: geometry.braceEnd.y)
            )
            brace.stroke()

            if editingAnnotationID != annotation.id, let labelRect = annotationLabelRect(annotation.id) {
                let path = NSBezierPath(roundedRect: labelRect, xRadius: 7, yRadius: 7)
                NSColor.controlAccentColor.withAlphaComponent(selected ? 0.10 : 0.05).setFill()
                path.fill()
                color.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 1
                path.stroke()
                (annotation.label as NSString).draw(
                    with: labelRect.insetBy(dx: 6, dy: 5),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: annotationFont, .foregroundColor: NSColor.labelColor]
                )
            }
        }
    }

    /// Creates a brace annotation around the current multi-selection.
    @discardableResult
    func createAnnotationFromSelection(label: String = "分组备注") -> UUID? {
        guard selectedNodeIDs.count >= 2 else { return nil }
        let ids = Array(selectedNodeIDs)
        finishAnnotationEditing(commit: true)
        guard let id = store.addAnnotation(memberIDs: ids, label: label) else { return nil }
        selectedAnnotationID = id
        needsDisplay = true
        DispatchQueue.main.async { [weak self] in
            self?.beginAnnotationEditing(id)
        }
        return id
    }

    func beginAnnotationEditing(_ id: UUID) {
        guard let annotation = store.annotation(id), let rect = annotationLabelRect(id) else { return }
        selectedAnnotationID = id
        editingAnnotationID = id
        let text = CanvasTextView(frame: rect)
        text.isRichText = false
        text.drawsBackground = true
        text.backgroundColor = NSColor.textBackgroundColor
        text.font = annotationFont
        text.textColor = .labelColor
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.string = annotation.label
        text.delegate = self
        annotationEditor = text
        addSubview(text)
        window?.makeFirstResponder(text)
        text.selectAll(nil)
        needsDisplay = true
    }

    func finishAnnotationEditing(commit: Bool) {
        guard let id = editingAnnotationID else { return }
        let value = annotationEditor?.string ?? ""
        editingAnnotationID = nil
        annotationEditor?.delegate = nil
        annotationEditor?.removeFromSuperview()
        annotationEditor = nil
        if commit { store.updateAnnotation(id, label: value) }
        window?.makeFirstResponder(self)
        refresh()
    }

    func selectOnly(_ id: UUID?) {
        selectedNodeIDs = id.map { [$0] } ?? []
        store.selectedID = id
        needsDisplay = true
    }

    private func primarySelection(from ids: Set<UUID>) -> UUID? {
        ids.min { lhs, rhs in
            guard let left = card(lhs), let right = card(rhs) else { return lhs.uuidString < rhs.uuidString }
            if abs(left.minY - right.minY) > 0.5 { return left.minY < right.minY }
            return left.minX < right.minX
        }
    }

    @discardableResult
    func applyMarqueeSelection(in rect: CGRect) -> Set<UUID> {
        let matches = Set(treeLayout.frames.keys.filter { id in
            guard let frame = card(id) else { return false }
            return frame.intersects(rect)
        })
        selectedNodeIDs = matches
        store.selectedID = primarySelection(from: matches)
        needsDisplay = true
        return matches
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func resetMarquee() {
        marqueeStart = nil
        marqueeRect = nil
        marqueeDidDrag = false
        commandSelectionAnchorID = nil
        NSCursor.arrow.set()
    }

    private func deleteSelection() {
        let targets = selectedNodeIDs.filter { $0 != store.root.id }
        guard !targets.isEmpty else { return }
        _ = store.delete(Array(targets))
        selectedNodeIDs = store.selectedID.map { [$0] } ?? []
        refresh()
    }

    func toggleCollapsed(_ id: UUID) {
        finishEditing(commit: true)
        guard let before = card(id), store.toggleCollapsed(id) else { return }
        refresh()
        if let after = card(id), let scroll = enclosingScrollView {
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: CGPoint(
                x: origin.x + after.midX - before.midX,
                y: origin.y + after.midY - before.midY
            ))
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
                        bend1 = CGPoint(x: x, y: from.y)
                        bend2 = CGPoint(x: x, y: to.y)
                    } else {
                        from = CGPoint(x: parentFrame.midX, y: parentFrame.maxY)
                        to = CGPoint(x: childFrame.midX, y: childFrame.minY)
                        let y = from.y + max(16, (to.y - from.y) / 2)
                        bend1 = CGPoint(x: from.x, y: y)
                        bend2 = CGPoint(x: to.x, y: y)
                    }
                    result += [
                        TreeConnector(from: from, to: bend1),
                        TreeConnector(from: bend1, to: bend2),
                        TreeConnector(from: bend2, to: to)
                    ]
                }
                visit(child)
            }
        }
        visit(root)
        return result
    }

    func stroke(_ connectors: [TreeConnector], dashed: Bool = false) {
        (dashed ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        let lines = NSBezierPath()
        lines.lineWidth = dashed ? 2 : 1.5
        if dashed { lines.setLineDash([6, 4], count: 2, phase: 0) }
        for line in connectors {
            lines.move(to: CGPoint(x: line.from.x + inset, y: line.from.y + inset))
            lines.line(to: CGPoint(x: line.to.x + inset, y: line.to.y + inset))
        }
        lines.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard treeLayout != nil else { return }
        stroke(liveConnectors)
        stroke(placeholderConnectors, dashed: true)
        drawAnnotations()

        if let marqueeRect {
            let path = NSBezierPath(rect: marqueeRect)
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1.25
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.stroke()
        }

        if let dropPreview {
            for id in draggedIDs {
                guard let frame = dropPreview.frames[id] else { continue }
                let rect = frame.offsetBy(dx: inset, dy: inset)
                let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
                NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
                path.fill()
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 2
                path.setLineDash([6, 4], count: 2, phase: 0)
                path.stroke()
            }
        }

        let orderedIDs = visibleIDs.sorted { !draggedIDs.contains($0) && draggedIDs.contains($1) }
        for id in orderedIDs {
            guard let node = store.node(id), let rect = card(id) else { continue }
            let selected = selectedNodeIDs.contains(id) || store.selectedID == id
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            let level = depth(id)
            let colors: [NSColor] = [.systemIndigo, .systemBlue, .systemTeal, .systemGray]
            let color = colors[level]
            if draggedIDs.contains(id) {
                NSColor.windowBackgroundColor.setFill()
                path.fill()
            }
            (level == 0 ? color : color.withAlphaComponent(selected ? 0.25 : (level == 1 ? 0.16 : 0.07))).setFill()
            path.fill()
            (selected ? NSColor.controlAccentColor : color.withAlphaComponent(0.6)).setStroke()
            path.lineWidth = editingID == id ? 3 : (selected ? 2.5 : 1)
            path.stroke()
            if selected {
                NSColor.controlAccentColor.setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -4), xRadius: 11, yRadius: 11)
                ring.lineWidth = 1.5
                ring.stroke()
            }
            if editingID != id {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NodeSizing.font,
                    .foregroundColor: level == 0 ? NSColor.white : NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]
                let height = (node.title as NSString).boundingRect(
                    with: CGSize(width: rect.width - 24, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes
                ).height
                let textRect = CGRect(
                    x: rect.minX + 12,
                    y: rect.midY - ceil(height) / 2,
                    width: rect.width - 24,
                    height: ceil(height)
                )
                (node.title as NSString).draw(
                    with: textRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes
                )
            }
            if let button = disclosureRect(id) {
                let circle = NSBezierPath(ovalIn: button)
                NSColor.windowBackgroundColor.setFill()
                circle.fill()
                NSColor.secondaryLabelColor.setStroke()
                circle.lineWidth = 1
                circle.stroke()
                let symbol = NSBezierPath()
                symbol.lineWidth = 1.5
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
            let mark = NSBezierPath()
            mark.lineWidth = 4
            if placement == .inside {
                mark.appendRoundedRect(rect.insetBy(dx: -4, dy: -4), xRadius: 10, yRadius: 10)
            } else if orientation == .horizontal {
                let y = placement == .before ? rect.minY - 5 : rect.maxY + 5
                mark.move(to: CGPoint(x: rect.minX, y: y))
                mark.line(to: CGPoint(x: rect.maxX, y: y))
            } else {
                let x = placement == .before ? rect.minX - 5 : rect.maxX + 5
                mark.move(to: CGPoint(x: x, y: rect.minY))
                mark.line(to: CGPoint(x: x, y: rect.maxY))
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

        if event.modifierFlags.contains(.command) {
            resetDrag()
            pressedID = nil
            marqueeStart = downPoint
            marqueeRect = CGRect(origin: downPoint, size: .zero)
            marqueeDidDrag = false
            commandSelectionAnchorID = hit(downPoint)
            NSCursor.crosshair.set()
            needsDisplay = true
            return
        }

        resetMarquee()
        if let id = visibleIDs.first(where: { disclosureRect($0)?.insetBy(dx: -3, dy: -3).contains(downPoint) == true }) {
            pressedID = nil
            resetDrag()
            pressedDisclosure = true
            selectOnly(id)
            if event.clickCount == 1 { toggleCollapsed(id) }
            needsDisplay = true
            return
        }

        // Brace annotations sit above the plain marquee path: clicking one
        // selects the note instead of starting a canvas pan.
        if let annotationID = hitAnnotation(downPoint) {
            if editingAnnotationID != annotationID { finishAnnotationEditing(commit: true) }
            selectedAnnotationID = annotationID
            pressedAnnotationID = annotationID
            resetDrag()
            pressedID = nil
            needsDisplay = true
            return
        }
        pressedAnnotationID = nil
        if selectedAnnotationID != nil, hit(downPoint) == nil {
            selectedAnnotationID = nil
            needsDisplay = true
        }

        pressedID = hit(downPoint)
        resetDrag()
        // Pressing a member of an existing multi-selection arms a batch drag:
        // keep the whole selection until mouseUp collapses it on a plain
        // click (no drag), mirroring standard multi-select behavior.
        multiDragArmed = pressedID != nil
            && selectedNodeIDs.contains(pressedID!)
            && selectedNodeIDs.count > 1
        if multiDragArmed {
            store.selectedID = pressedID
        } else {
            selectOnly(pressedID)
        }
        if event.clickCount == 2, let id = pressedID { beginEditing(id) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !pressedDisclosure else { return }

        if let start = marqueeStart {
            autoscroll(with: event)
            let point = convert(event.locationInWindow, from: nil)
            let distance = hypot(point.x - start.x, point.y - start.y) * (enclosingScrollView?.magnification ?? 1)
            if distance > 3 { marqueeDidDrag = true }
            if marqueeDidDrag {
                let rect = normalizedRect(from: start, to: point)
                marqueeRect = rect
                _ = applyMarqueeSelection(in: rect)
            }
            NSCursor.crosshair.set()
            needsDisplay = true
            return
        }

        if pressedID == nil, let scroll = enclosingScrollView {
            NSCursor.closedHand.set()
            let p = event.locationInWindow
            scroll.contentView.scroll(to: CGPoint(
                x: panOrigin.x - (p.x - panStart.x) / scroll.magnification,
                y: panOrigin.y + (p.y - panStart.y) / scroll.magnification
            ))
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
        if multiDragArmed {
            let subtree = draggedIDs
            for id in selectedNodeIDs where !subtree.contains(id) {
                if let node = store.node(id) { collect(node) }
            }
            // Ancestors of the pressed branch are left alone: the pressed
            // branch is being detached from them by this very drag.
            multiDragExtras = selectedNodeIDs
                .filter { !subtree.contains($0) && !collectSubtree($0).contains(source) }
                .sorted { lhs, rhs in
                    let left = treeLayout.frames[lhs]
                    let right = treeLayout.frames[rhs]
                    guard let left, let right else { return lhs.uuidString < rhs.uuidString }
                    if abs(left.minY - right.minY) > 0.5 { return left.minY < right.minY }
                    return left.minX < right.minX
                }
        }
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
            let a = card(a)!
            let b = card(b)!
            return hypot(point.x - a.midX, point.y - a.midY) < hypot(point.x - b.midX, point.y - b.midY)
        }
        guard let target, let rect = card(target) else {
            drop = nil
            dropPreview = nil
            previewRoot = nil
            return
        }
        let fraction = orientation == .horizontal
            ? (point.y - rect.minY) / rect.height
            : (point.x - rect.minX) / rect.width
        // Layout only reserves insertion space below the hovered card, never
        // above it, so the canvas does not reflow both directions at once.
        let placement: DropPlacement = fraction > 0.75 ? .after : .inside
        if drop?.0 == target, drop?.1 == placement { return }
        let candidate = MindMapStore(root: store.root)
        guard candidate.move(source, relativeTo: target, placement: placement, additionalIDs: multiDragExtras),
              candidate.root != store.root else {
            drop = nil
            dropPreview = nil
            previewRoot = nil
            return
        }
        let layout = TreeLayoutEngine.layout(root: candidate.root, orientation: orientation)
        // Anchor the hovered card so the preview cannot move its own drop zone.
        guard let targetFrame = layout.frames[target] ?? layout.frames[source] else { return }
        let anchorID = layout.frames[target] != nil ? target : source
        let currentAnchorFrame = card(anchorID) ?? rect
        let dx = (currentAnchorFrame.minX - inset) - (layout.frames[anchorID]?.minX ?? targetFrame.minX)
        let dy = (currentAnchorFrame.minY - inset) - (layout.frames[anchorID]?.minY ?? targetFrame.minY)
        dropPreview = TreeLayout(
            frames: layout.frames.mapValues { $0.offsetBy(dx: dx, dy: dy) },
            connectors: layout.connectors.map {
                TreeConnector(
                    from: CGPoint(x: $0.from.x + dx, y: $0.from.y + dy),
                    to: CGPoint(x: $0.to.x + dx, y: $0.to.y + dy)
                )
            },
            contentSize: layout.contentSize
        )
        previewRoot = candidate.root
        drop = (target, placement)
    }

    private func collectSubtree(_ id: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        func collect(_ node: MindNode) {
            result.insert(node.id)
            node.children.forEach(collect)
        }
        if let node = store.node(id) { collect(node) }
        return result
    }

    override func mouseUp(with event: NSEvent) {
        if marqueeStart != nil {
            if !marqueeDidDrag, let id = commandSelectionAnchorID {
                if selectedNodeIDs.contains(id) {
                    selectedNodeIDs.remove(id)
                    if store.selectedID == id { store.selectedID = primarySelection(from: selectedNodeIDs) }
                } else {
                    selectedNodeIDs.insert(id)
                    store.selectedID = id
                }
            }
            resetMarquee()
            pressedID = nil
            pressedDisclosure = false
            needsDisplay = true
            return
        }

        if pressedAnnotationID != nil {
            if event.clickCount == 2, let id = pressedAnnotationID {
                beginAnnotationEditing(id)
            }
            pressedAnnotationID = nil
            return
        }

        NSCursor.arrow.set()
        // A plain click (no drag) on a multi-selection collapses it to the
        // pressed node; a completed batch drag keeps the selection.
        if !dragging, let pressed = pressedID, multiDragArmed {
            selectOnly(pressed)
        }
        let previewRootFrame = dropPreview?.frames[store.root.id]
        var moved = false
        if dragging, let source = pressedID, let (target, placement) = drop {
            let extras = multiDragExtras
            moved = store.move(source, relativeTo: target, placement: placement, additionalIDs: extras)
        }
        resetDrag()
        pressedID = nil
        pressedDisclosure = false
        refresh()
        if moved, let previewRootFrame, let frame = treeLayout.frames[store.root.id], let scroll = enclosingScrollView {
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: CGPoint(
                x: origin.x + frame.minX - previewRootFrame.minX,
                y: origin.y + frame.minY - previewRootFrame.minY
            ))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func resetDrag() {
        drop = nil
        dragging = false
        dragOffset = .zero
        draggedIDs.removeAll()
        dropPreview = nil
        previewRoot = nil
        multiDragExtras = []
        multiDragArmed = false
    }

    private func isTextInput(_ event: NSEvent) -> Bool {
        guard let characters = event.characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.contains { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0xF700...0xF8FF).contains(Int(scalar.value))
        }
    }

    override func keyDown(with event: NSEvent) {
        if marqueeStart != nil {
            if event.keyCode == 53 {
                resetMarquee()
                needsDisplay = true
            }
            return
        }

        if dragging {
            if event.keyCode == 53 {
                resetDrag()
                pressedID = nil
                NSCursor.arrow.set()
                refresh()
            }
            return
        }

        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            super.keyDown(with: event)
            return
        }

        let hasShiftOrOption = !event.modifierFlags.intersection([.shift, .option]).isEmpty
        if !hasShiftOrOption {
            let directions: [UInt16: NodeNavigationDirection] = [
                123: .parent,
                124: .child,
                126: .previous,
                125: .next
            ]
            if let direction = directions[event.keyCode] {
                let destination = store.navigate(direction)
                selectOnly(destination)
                refresh()
                if let rect = card(destination) { scrollToVisible(rect.insetBy(dx: -30, dy: -30)) }
                return
            }
        }

        guard let id = store.selectedID else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 36 where !hasShiftOrOption, 76 where !hasShiftOrOption:
            guard selectedNodeIDs.count <= 1 else { NSSound.beep(); return }
            if let created = id == store.root.id ? store.createChild(of: id) : store.createSibling(after: id) {
                selectOnly(created)
                refresh()
                beginEditing(created)
            }

        case 48 where !hasShiftOrOption:
            guard selectedNodeIDs.count <= 1 else { NSSound.beep(); return }
            if let created = store.createChild(of: id) {
                selectOnly(created)
                refresh()
                beginEditing(created)
            }

        case 51, 117:
            if selectedAnnotationID != nil, selectedNodeIDs.count <= 1 {
                if let annotationID = selectedAnnotationID {
                    selectedAnnotationID = nil
                    store.removeAnnotation(annotationID)
                    refresh()
                    return
                }
            }
            if selectedNodeIDs.count > 1 {
                deleteSelection()
            } else {
                store.delete(id)
                selectedNodeIDs = store.selectedID.map { [$0] } ?? []
                refresh()
            }

        case 49 where !hasShiftOrOption:
            guard selectedNodeIDs.count <= 1 else { NSSound.beep(); return }
            toggleCollapsed(id)

        default:
            if selectedNodeIDs.count <= 1, isTextInput(event) {
                beginEditing(id)
                editor?.keyDown(with: event)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    func beginEditing(_ id: UUID) {
        guard let node = store.node(id), let rect = card(id) else { return }
        selectOnly(id)
        finishAnnotationEditing(commit: true)
        editingID = id
        store.beginEditSession()
        let text = CanvasTextView(frame: rect.insetBy(dx: 12, dy: 8))
        text.isRichText = false
        text.drawsBackground = false
        text.font = NodeSizing.font
        text.textColor = depth(id) == 0 ? .white : .labelColor
        text.insertionPointColor = depth(id) == 0 ? .white : .controlAccentColor
        text.alignment = .center
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.string = node.title
        text.delegate = self
        editor = text
        addSubview(text)
        window?.makeFirstResponder(text)
        text.selectAll(nil)
        scrollToVisible(rect.insetBy(dx: -30, dy: -30))
        needsDisplay = true
    }

    func finishEditing(commit: Bool) {
        guard let id = editingID else { return }
        let value = editor?.string ?? ""
        editingID = nil
        editor?.delegate = nil
        editor?.removeFromSuperview()
        editor = nil
        if commit { store.rename(id, to: value, inEditSession: true) }
        selectOnly(id)
        window?.makeFirstResponder(self)
        refresh()
    }

    func textDidChange(_ notification: Notification) {
        if annotationEditor != nil, let annotationEditor, notification.object as? NSTextView === annotationEditor {
            needsDisplay = true
            return
        }
        refresh()
    }

    func textDidEndEditing(_ notification: Notification) {
        if annotationEditor != nil, let annotationEditor, notification.object as? NSTextView === annotationEditor {
            finishAnnotationEditing(commit: true)
            return
        }
        finishEditing(commit: true)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }

        if textView === annotationEditor {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finishAnnotationEditing(commit: true)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finishAnnotationEditing(commit: false)
                return true
            }
            return false
        }

        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishEditing(commit: true)
            return true
        }

        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            guard let parentID = editingID else { return false }
            finishEditing(commit: true)
            if let created = store.createChild(of: parentID) {
                selectOnly(created)
                refresh()
                beginEditing(created)
            }
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(commit: false)
            return true
        }

        return false
    }
}
