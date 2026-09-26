import AppKit
import Foundation
import SwiftUI

struct MindNode: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var children: [MindNode]
    var isCollapsed: Bool

    init(id: UUID = UUID(), title: String, children: [MindNode] = [], isCollapsed: Bool = false) {
        self.id = id
        self.title = title
        self.children = children
        self.isCollapsed = isCollapsed
    }

    private enum CodingKeys: String, CodingKey { case id, title, children, isCollapsed }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        children = try values.decode([MindNode].self, forKey: .children)
        isCollapsed = try values.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }
}

/// A note attached to a group of nodes, drawn as a brace beside the group and
/// exported as a remark for those nodes. Members are tracked by stable IDs, so
/// the group survives edits, moves and undo/redo.
struct GroupAnnotation: Identifiable, Codable, Equatable {
    let id: UUID
    var memberIDs: [UUID]
    var label: String

    init(id: UUID = UUID(), memberIDs: [UUID], label: String) {
        self.id = id
        self.memberIDs = memberIDs
        self.label = label
    }
}

enum DropPlacement: Equatable {
    case before
    case inside
    case after
}

enum StrataLayoutOrientation: String, Equatable {
    case horizontal
    case vertical
}

enum NodeNavigationDirection {
    case parent, child, previous, next
}

struct TreeConnector: Equatable {
    let from: CGPoint
    let to: CGPoint
}

struct TreeLayout: Equatable {
    let frames: [UUID: CGRect]
    let connectors: [TreeConnector]
    let contentSize: CGSize
}

/// Text metrics are shared by the renderer and tests so cards do not regress
/// to a fixed width when titles become longer or contain line breaks.
enum NodeSizing {
    static let minimumWidth: CGFloat = 88
    static let maximumWidth: CGFloat = 300
    static let minimumHeight: CGFloat = 40
    static let horizontalPadding: CGFloat = 24
    static let verticalPadding: CGFloat = 16
    static var font: NSFont { NSFont.systemFont(ofSize: 14) }

    static func size(for title: String) -> CGSize {
        let displayTitle = title.isEmpty ? "新节点" : title
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let unconstrained = (displayTitle as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let width = min(
            maximumWidth,
            max(minimumWidth, ceil(unconstrained.width) + horizontalPadding)
        )
        let textWidth = max(1, width - horizontalPadding)
        let measured = (displayTitle as NSString).boundingRect(
            with: CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let height = max(minimumHeight, ceil(measured.height) + verticalPadding)
        return CGSize(width: width, height: height)
    }
}

enum TreeLayoutEngine {
    static let siblingSpacing: CGFloat = 24
    static let levelSpacing: CGFloat = 52

    static func layout(
        root: MindNode,
        orientation: StrataLayoutOrientation,
        titleOverrides: [UUID: String] = [:]
    ) -> TreeLayout {
        var subtreeSizes: [UUID: CGSize] = [:]

        func nodeSize(_ node: MindNode) -> CGSize {
            NodeSizing.size(for: titleOverrides[node.id] ?? node.title)
        }

        func measure(_ node: MindNode) -> CGSize {
            let ownSize = nodeSize(node)
            guard !node.isCollapsed, !node.children.isEmpty else {
                subtreeSizes[node.id] = ownSize
                return ownSize
            }

            let childSizes = node.children.map(measure)
            let childWidth = childSizes.map(\.width).max() ?? 0
            let childHeight = childSizes.reduce(0) { $0 + $1.height }
                + siblingSpacing * CGFloat(max(0, childSizes.count - 1))
            let childTotalWidth = childSizes.reduce(0) { $0 + $1.width }
                + siblingSpacing * CGFloat(max(0, childSizes.count - 1))
            let size: CGSize
            switch orientation {
            case .horizontal:
                size = CGSize(
                    width: ownSize.width + levelSpacing + childWidth,
                    height: max(ownSize.height, childHeight)
                )
            case .vertical:
                size = CGSize(
                    width: max(ownSize.width, childTotalWidth),
                    height: ownSize.height + levelSpacing + (childSizes.map(\.height).max() ?? 0)
                )
            }
            subtreeSizes[node.id] = size
            return size
        }

        let totalSize = measure(root)
        var frames: [UUID: CGRect] = [:]
        var connectors: [TreeConnector] = []

        func addHorizontalConnectors(parentFrame: CGRect, childFrames: [CGRect]) {
            guard !childFrames.isEmpty else { return }
            let junctionX = parentFrame.maxX + levelSpacing / 2
            let parentCenterY = parentFrame.midY
            connectors.append(TreeConnector(
                from: CGPoint(x: parentFrame.maxX, y: parentCenterY),
                to: CGPoint(x: junctionX, y: parentCenterY)
            ))
            let childCenters = childFrames.map(\.midY)
            if let first = childCenters.min(), let last = childCenters.max() {
                connectors.append(TreeConnector(
                    from: CGPoint(x: junctionX, y: first),
                    to: CGPoint(x: junctionX, y: last)
                ))
            }
            for childFrame in childFrames {
                connectors.append(TreeConnector(
                    from: CGPoint(x: junctionX, y: childFrame.midY),
                    to: CGPoint(x: childFrame.minX, y: childFrame.midY)
                ))
            }
        }

        func addVerticalConnectors(parentFrame: CGRect, childFrames: [CGRect]) {
            guard !childFrames.isEmpty else { return }
            let junctionY = parentFrame.maxY + levelSpacing / 2
            let parentCenterX = parentFrame.midX
            connectors.append(TreeConnector(
                from: CGPoint(x: parentCenterX, y: parentFrame.maxY),
                to: CGPoint(x: parentCenterX, y: junctionY)
            ))
            let childCenters = childFrames.map(\.midX)
            if let first = childCenters.min(), let last = childCenters.max() {
                connectors.append(TreeConnector(
                    from: CGPoint(x: first, y: junctionY),
                    to: CGPoint(x: last, y: junctionY)
                ))
            }
            for childFrame in childFrames {
                connectors.append(TreeConnector(
                    from: CGPoint(x: childFrame.midX, y: junctionY),
                    to: CGPoint(x: childFrame.midX, y: childFrame.minY)
                ))
            }
        }

        func place(_ node: MindNode, at origin: CGPoint) {
            let ownSize = nodeSize(node)
            let subtreeSize = subtreeSizes[node.id] ?? ownSize
            var ownOrigin = origin

            switch orientation {
            case .horizontal:
                ownOrigin.y += (subtreeSize.height - ownSize.height) / 2
            case .vertical:
                ownOrigin.x += (subtreeSize.width - ownSize.width) / 2
            }
            let ownFrame = CGRect(origin: ownOrigin, size: ownSize)
            frames[node.id] = ownFrame

            guard !node.isCollapsed, !node.children.isEmpty else { return }
            var childFrames: [CGRect] = []

            switch orientation {
            case .horizontal:
                let childTotalHeight = node.children.reduce(CGFloat.zero) {
                    $0 + (subtreeSizes[$1.id]?.height ?? 0)
                } + siblingSpacing * CGFloat(max(0, node.children.count - 1))
                var childY = origin.y + (subtreeSize.height - childTotalHeight) / 2
                let childX = origin.x + ownSize.width + levelSpacing
                for child in node.children {
                    let childSize = subtreeSizes[child.id] ?? nodeSize(child)
                    place(child, at: CGPoint(x: childX, y: childY))
                    if let frame = frames[child.id] { childFrames.append(frame) }
                    childY += childSize.height + siblingSpacing
                }
                addHorizontalConnectors(parentFrame: ownFrame, childFrames: childFrames)

            case .vertical:
                let childTotalWidth = node.children.reduce(CGFloat.zero) {
                    $0 + (subtreeSizes[$1.id]?.width ?? 0)
                } + siblingSpacing * CGFloat(max(0, node.children.count - 1))
                var childX = origin.x + (subtreeSize.width - childTotalWidth) / 2
                let childY = origin.y + ownSize.height + levelSpacing
                for child in node.children {
                    let childSize = subtreeSizes[child.id] ?? nodeSize(child)
                    place(child, at: CGPoint(x: childX, y: childY))
                    if let frame = frames[child.id] { childFrames.append(frame) }
                    childX += childSize.width + siblingSpacing
                }
                addVerticalConnectors(parentFrame: ownFrame, childFrames: childFrames)
            }
        }

        place(root, at: .zero)
        return TreeLayout(frames: frames, connectors: connectors, contentSize: totalSize)
    }
}

struct CanvasFocusRequest: Equatable {
    let id = UUID()
    let nodeID: UUID
    var activateCanvas = false
}

@MainActor
final class MindMapStore: ObservableObject {
    /// Document snapshot used by undo/redo. Selection is stored separately so
    /// pure selection changes never pollute the edit history.
    struct HistoryEntry: Equatable {
        var root: MindNode
        var annotations: [GroupAnnotation]
    }

    @Published var root: MindNode
    @Published private(set) var annotations: [GroupAnnotation] = []
    @Published var selectedID: UUID?
    @Published private(set) var focusRequest: CanvasFocusRequest?
    @Published private(set) var undoGeneration = 0

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private let maxUndoDepth = 100
    private var undoStack: [HistoryEntry] = []
    private var redoStack: [HistoryEntry] = []

    init(root: MindNode = MindNode(title: "主题")) {
        self.root = root
        selectedID = root.id
    }

    var currentSnapshot: HistoryEntry {
        HistoryEntry(root: root, annotations: annotations)
    }

    var isEmptyDocument: Bool {
        root.title == "主题" && root.children.isEmpty
    }

    func reset() {
        let root = MindNode(title: "主题")
        recordUndo()
        self.root = root
        annotations = []
        selectedID = root.id
        requestFocus(on: root.id)
    }

    func node(_ id: UUID?) -> MindNode? {
        guard let id else { return nil }
        return find(id, in: root)
    }

    func select(_ id: UUID) {
        guard node(id) != nil else { return }
        selectedID = id
    }

    @discardableResult
    func navigate(_ direction: NodeNavigationDirection) -> UUID {
        guard let current = node(selectedID) else {
            selectedID = root.id
            return root.id
        }
        var destination = current.id
        switch direction {
        case .parent:
            destination = parentID(of: current.id) ?? current.id
        case .child:
            destination = current.children.first?.id ?? current.id
        case .previous, .next:
            var cursor = current.id
            while let parentID = parentID(of: cursor), let parent = node(parentID),
                  let index = parent.children.firstIndex(where: { $0.id == cursor }) {
                let adjacent = index + (direction == .previous ? -1 : 1)
                if parent.children.indices.contains(adjacent) {
                    destination = parent.children[adjacent].id
                    break
                }
                cursor = parentID
            }
        }
        revealAncestors(of: destination)
        selectedID = destination
        return destination
    }

    @discardableResult
    func toggleCollapsed(_ id: UUID) -> Bool {
        guard let branch = node(id), !branch.children.isEmpty else { return false }
        if !branch.isCollapsed, let selectedID, contains(selectedID, in: branch) {
            self.selectedID = id
        }
        return update(id, in: &root) { $0.isCollapsed.toggle() }
    }

    private func revealAncestors(of id: UUID) {
        var current = id
        while let parent = parentID(of: current) {
            if node(parent)?.isCollapsed == true {
                update(parent, in: &root) { $0.isCollapsed = false }
            }
            current = parent
        }
    }

    private func requestFocus(on id: UUID, activateCanvas: Bool = false) {
        revealAncestors(of: id)
        focusRequest = CanvasFocusRequest(nodeID: id, activateCanvas: activateCanvas)
    }

    @discardableResult
    func createChild(of parentID: UUID, title: String = "新节点") -> UUID? {
        guard node(parentID) != nil, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let child = MindNode(title: title)
        recordUndo()
        guard update(parentID, in: &root, { $0.children.append(child) }) else { return nil }
        selectedID = child.id
        requestFocus(on: child.id, activateCanvas: true)
        return child.id
    }

    @discardableResult
    func createSibling(after nodeID: UUID) -> UUID? {
        guard nodeID != root.id,
              let parentID = parentID(of: nodeID),
              let parent = node(parentID),
              let index = parent.children.firstIndex(where: { $0.id == nodeID })
        else {
            return nil
        }

        let sibling = MindNode(title: "新节点")
        recordUndo()
        guard update(parentID, in: &root, { $0.children.insert(sibling, at: index + 1) }) else {
            return nil
        }
        selectedID = sibling.id
        requestFocus(on: sibling.id)
        return sibling.id
    }

    @discardableResult
    func rename(_ nodeID: UUID, to title: String) -> Bool {
        rename(nodeID, to: title, inEditSession: false)
    }

    /// Deletes several branches in one undo step, ordered deepest first so
    /// nested members never invalidate their ancestors' removal. Returns the
    /// resulting selection.
    @discardableResult
    func delete(_ nodeIDs: [UUID]) -> UUID? {
        let targets = nodeIDs
            .filter { $0 != root.id }
            .sorted { depth(of: $0) > depth(of: $1) }
        guard !targets.isEmpty else { return nil }

        var candidate = root
        for id in targets where find(id, in: candidate) != nil {
            guard remove(id, from: &candidate) != nil else { continue }
        }
        recordUndo()
        root = candidate
        pruneStaleAnnotations()
        var target = root
        if let selected = node(selectedID) {
            target = selected
        } else {
            while let last = target.children.last { target = last }
        }
        selectedID = target.id
        requestFocus(on: target.id)
        return target.id
    }

    private func depth(of id: UUID) -> Int {
        func visit(_ node: MindNode, _ level: Int) -> Int? {
            if node.id == id { return level }
            for child in node.children {
                if let found = visit(child, level + 1) { return found }
            }
            return nil
        }
        return visit(root, 0) ?? 0
    }

    /// Keeps a surviving selection, otherwise selects the last leaf in tree order.
    @discardableResult
    func delete(_ nodeID: UUID) -> UUID? {
        guard nodeID != root.id else { return nil }

        var candidate = root
        guard remove(nodeID, from: &candidate) != nil else { return nil }
        recordUndo()
        root = candidate
        pruneStaleAnnotations()
        var target = root
        if let selected = node(selectedID) {
            target = selected
        } else {
            while let last = target.children.last { target = last }
        }
        selectedID = target.id
        requestFocus(on: target.id)
        return target.id
    }

    /// Moves one node using the same three drop zones rendered by the editor.
    /// All references are validated before the source is removed.
    @discardableResult
    func move(_ sourceID: UUID, relativeTo targetID: UUID, placement: DropPlacement) -> Bool {
        move(sourceID, relativeTo: targetID, placement: placement, additionalIDs: [])
    }

    /// Moves the pressed branch plus any extra selected branches in a single
    /// undo step. Extra branches follow the first one and keep their relative
    /// order; inside drops append them under the target.
    @discardableResult
    func move(_ sourceID: UUID, relativeTo targetID: UUID, placement: DropPlacement, additionalIDs: [UUID]) -> Bool {
        guard sourceID != root.id,
              sourceID != targetID,
              let source = node(sourceID),
              let sourceParentID = parentID(of: sourceID),
              !contains(targetID, in: source)
        else {
            return false
        }

        let destinationParentID: UUID
        let insertionIndex: Int

        switch placement {
        case .inside:
            guard let target = node(targetID), sourceParentID != target.id else { return false }
            destinationParentID = target.id
            insertionIndex = target.children.count

        case .before, .after:
            guard targetID != root.id,
                  let parentID = parentID(of: targetID),
                  let destinationParent = node(parentID),
                  let targetIndex = destinationParent.children.firstIndex(where: { $0.id == targetID })
            else {
                return false
            }

            destinationParentID = parentID
            var index = targetIndex + (placement == .after ? 1 : 0)
            if sourceParentID == parentID,
               let sourceIndex = destinationParent.children.firstIndex(where: { $0.id == sourceID }),
               sourceIndex < index {
                index -= 1
            }
            insertionIndex = index
        }

        var candidate = root
        guard let movedSource = remove(sourceID, from: &candidate),
              insert(movedSource, under: destinationParentID, at: insertionIndex, in: &candidate)
        else {
            return false
        }

        if !additionalIDs.isEmpty {
            var previousMovedID = sourceID
            for extraID in additionalIDs {
                guard extraID != root.id, extraID != sourceID, extraID != targetID,
                      find(extraID, in: candidate) != nil,
                      let extra = find(extraID, in: candidate),
                      !contains(destinationParentID, in: extra)
                else { continue }

                let insertParentID: UUID
                let insertIndex: Int
                if placement == .inside {
                    insertParentID = destinationParentID
                    insertIndex = find(destinationParentID, in: candidate)?.children.count ?? 0
                } else {
                    guard let parent = parent(of: previousMovedID, in: candidate),
                          let index = parent.children.firstIndex(where: { $0.id == previousMovedID })
                    else { continue }
                    insertParentID = parent.id
                    insertIndex = index + 1
                }
                guard let movedExtra = remove(extraID, from: &candidate),
                      insert(movedExtra, under: insertParentID, at: insertIndex, in: &candidate)
                else { continue }
                previousMovedID = extraID
            }
        }

        recordUndo()
        root = candidate
        selectedID = sourceID
        revealAncestors(of: sourceID)
        pruneStaleAnnotations()
        return true
    }

    /// Kept for callers that need only the leaves.
    func leaves() -> String {
        leafTitles(in: root).joined(separator: "\n")
    }

    func textExport() -> String {
        var labelByNodeID: [UUID: [String]] = [:]
        for annotation in annotations {
            for memberID in annotation.memberIDs {
                labelByNodeID[memberID, default: []].append(annotation.label)
            }
        }
        func sections(_ node: MindNode, depth: Int) -> [String] {
            let lines = node.title.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let title = lines.joined(separator: node.children.isEmpty ? "\n" : " ")
            var body = [String]()
            if node.children.isEmpty {
                body.append(title)
            } else {
                body.append(String(repeating: "#", count: depth) + " " + title)
                body += node.children.flatMap { sections($0, depth: depth + 1) }
            }
            if let labels = labelByNodeID[node.id], !labels.isEmpty, !title.isEmpty {
                body.append("（备注：" + labels.joined(separator: "；") + "）")
            }
            return body
        }
        return sections(root, depth: 1).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func replaceRoot(with root: MindNode) {
        recordUndo()
        self.root = root
        annotations = []
        selectedID = root.id
        requestFocus(on: root.id)
    }

    // MARK: - Group annotations

    /// Creates a brace annotation around the given members. Returns nil when
    /// fewer than two members remain after removing stale IDs.
    @discardableResult
    func addAnnotation(memberIDs: [UUID], label: String) -> UUID? {
        let members = memberIDs.filter { node($0) != nil }
        guard members.count >= 2 else { return nil }
        let annotation = GroupAnnotation(memberIDs: members, label: label)
        recordUndo()
        annotations.append(annotation)
        return annotation.id
    }

    @discardableResult
    func updateAnnotation(_ id: UUID, label: String) -> Bool {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return false }
        guard !normalized.isEmpty else { return false }
        guard annotations[index].label != normalized else { return true }
        recordUndo()
        annotations[index].label = normalized
        return true
    }

    @discardableResult
    func removeAnnotation(_ id: UUID) -> Bool {
        guard annotations.contains(where: { $0.id == id }) else { return false }
        recordUndo()
        annotations.removeAll { $0.id == id }
        return true
    }

    func annotation(_ id: UUID) -> GroupAnnotation? {
        annotations.first { $0.id == id }
    }

    /// Drops member IDs that no longer exist; disbands groups left with fewer
    /// than two members. Called after structural mutations.
    private func pruneStaleAnnotations() {
        var didChange = false
        var kept: [GroupAnnotation] = []
        for var annotation in annotations {
            let members = annotation.memberIDs.filter { node($0) != nil }
            if members.count != annotation.memberIDs.count || members.count < 2 {
                didChange = true
            }
            guard members.count >= 2 else { continue }
            if members != annotation.memberIDs {
                annotation.memberIDs = members
            }
            kept.append(annotation)
        }
        if didChange { annotations = kept }
    }

    /// Pushes the current document onto the undo history so the next edit
    /// clears the redo stack, mirroring standard text-editor behavior.
    private func recordUndo() {
        undoStack.append(currentSnapshot)
        if undoStack.count > maxUndoDepth { undoStack.removeFirst() }
        redoStack.removeAll()
        openEditSessionBase = nil
        undoGeneration += 1
    }

    /// Coalesces a continuous edit (inline typing) into a single undo step.
    /// `beginEditSession()` arms a checkpoint of the document; the first real
    /// change inside the session pushes that checkpoint onto the undo stack,
    /// and later changes fold into the same step.
    private var openEditSessionBase: HistoryEntry?

    func beginEditSession() {
        if openEditSessionBase == nil {
            openEditSessionBase = currentSnapshot
        }
    }

    /// Renames a node inside the open editing session. When no session is
    /// open, behaves like a discrete, individually undoable rename.
    @discardableResult
    func rename(_ nodeID: UUID, to title: String, inEditSession: Bool) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return false }
        guard node(nodeID) != nil else { return false }
        if node(nodeID)?.title == normalizedTitle { return true }
        if inEditSession, let base = openEditSessionBase {
            undoStack.append(base)
            if undoStack.count > maxUndoDepth { undoStack.removeFirst() }
            redoStack.removeAll()
            openEditSessionBase = nil
        } else {
            recordUndo()
        }
        return update(nodeID, in: &root) { $0.title = normalizedTitle }
    }

    @discardableResult
    func undo() -> Bool {
        guard !undoStack.isEmpty else { return false }
        let previous = undoStack.removeLast()
        redoStack.append(currentSnapshot)
        openEditSessionBase = nil
        root = previous.root
        annotations = previous.annotations
        if node(selectedID) == nil { selectedID = root.id }
        focusRequest = CanvasFocusRequest(nodeID: root.id, activateCanvas: true)
        undoGeneration += 1
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard !redoStack.isEmpty else { return false }
        let next = redoStack.removeLast()
        undoStack.append(currentSnapshot)
        openEditSessionBase = nil
        root = next.root
        annotations = next.annotations
        if node(selectedID) == nil { selectedID = root.id }
        focusRequest = CanvasFocusRequest(nodeID: root.id, activateCanvas: true)
        undoGeneration += 1
        return true
    }

    private struct Document: Codable {
        var root: MindNode
        var annotations: [GroupAnnotation]
    }

    func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let document = Document(root: root, annotations: annotations)
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    func open(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoded: Document
        if let document = try? JSONDecoder().decode(Document.self, from: data) {
            decoded = document
        } else if let legacyRoot = try? JSONDecoder().decode(MindNode.self, from: data) {
            // Documents saved before group annotations stored the bare root node.
            decoded = Document(root: legacyRoot, annotations: [])
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
        recordUndo()
        root = decoded.root
        annotations = decoded.annotations
        selectedID = decoded.root.id
        requestFocus(on: decoded.root.id)
    }

    private func find(_ id: UUID, in node: MindNode) -> MindNode? {
        if node.id == id { return node }
        for child in node.children {
            if let result = find(id, in: child) {
                return result
            }
        }
        return nil
    }

    private func parentID(of childID: UUID) -> UUID? {
        func search(_ node: MindNode) -> UUID? {
            if node.children.contains(where: { $0.id == childID }) {
                return node.id
            }
            for child in node.children {
                if let result = search(child) {
                    return result
                }
            }
            return nil
        }

        return search(root)
    }

    /// Parent lookup against a working tree being assembled by a multi-move.
    private func parent(of childID: UUID, in tree: MindNode) -> MindNode? {
        func search(_ node: MindNode) -> MindNode? {
            if node.children.contains(where: { $0.id == childID }) { return node }
            for child in node.children {
                if let result = search(child) { return result }
            }
            return nil
        }
        return search(tree)
    }

    private func contains(_ id: UUID, in node: MindNode) -> Bool {
        find(id, in: node) != nil
    }

    @discardableResult
    private func update(
        _ id: UUID,
        in node: inout MindNode,
        _ mutation: (inout MindNode) -> Void
    ) -> Bool {
        if node.id == id {
            mutation(&node)
            return true
        }

        for index in node.children.indices {
            if update(id, in: &node.children[index], mutation) {
                return true
            }
        }
        return false
    }

    private func remove(_ id: UUID, from node: inout MindNode) -> MindNode? {
        if let index = node.children.firstIndex(where: { $0.id == id }) {
            return node.children.remove(at: index)
        }

        for index in node.children.indices {
            if let removed = remove(id, from: &node.children[index]) {
                return removed
            }
        }
        return nil
    }

    @discardableResult
    private func insert(
        _ child: MindNode,
        under parentID: UUID,
        at index: Int,
        in node: inout MindNode
    ) -> Bool {
        if node.id == parentID {
            node.children.insert(child, at: min(max(index, 0), node.children.count))
            return true
        }

        for childIndex in node.children.indices {
            if insert(child, under: parentID, at: index, in: &node.children[childIndex]) {
                return true
            }
        }
        return false
    }

    private func leafTitles(in node: MindNode) -> [String] {
        node.children.isEmpty ? [node.title] : node.children.flatMap(leafTitles)
    }
}
