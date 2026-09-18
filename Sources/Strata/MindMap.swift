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
    @Published var root: MindNode
    @Published var selectedID: UUID?
    @Published private(set) var focusRequest: CanvasFocusRequest?

    init(root: MindNode = MindNode(title: "主题")) {
        self.root = root
        selectedID = root.id
    }

    var isEmptyDocument: Bool {
        root.title == "主题" && root.children.isEmpty
    }

    func reset() {
        let root = MindNode(title: "主题")
        self.root = root
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
        guard update(parentID, in: &root, { $0.children.insert(sibling, at: index + 1) }) else {
            return nil
        }
        selectedID = sibling.id
        requestFocus(on: sibling.id)
        return sibling.id
    }

    @discardableResult
    func rename(_ nodeID: UUID, to title: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return false }
        return update(nodeID, in: &root) { $0.title = normalizedTitle }
    }

    /// Keeps a surviving selection, otherwise selects the last leaf in tree order.
    @discardableResult
    func delete(_ nodeID: UUID) -> UUID? {
        guard nodeID != root.id else { return nil }

        var candidate = root
        guard remove(nodeID, from: &candidate) != nil else { return nil }
        root = candidate
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
        guard let removed = remove(sourceID, from: &candidate),
              insert(removed, under: destinationParentID, at: insertionIndex, in: &candidate)
        else {
            return false
        }

        root = candidate
        selectedID = sourceID
        revealAncestors(of: sourceID)
        return true
    }

    /// Kept for callers that need only the leaves.
    func leaves() -> String {
        leafTitles(in: root).joined(separator: "\n")
    }

    func textExport() -> String {
        func sections(_ node: MindNode, depth: Int) -> [String] {
            let lines = node.title.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let title = lines.joined(separator: node.children.isEmpty ? "\n" : " ")
            if node.children.isEmpty { return [title] }
            return [String(repeating: "#", count: depth) + " " + title]
                + node.children.flatMap { sections($0, depth: depth + 1) }
        }
        return sections(root, depth: 1).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func replaceRoot(with root: MindNode) {
        self.root = root
        selectedID = root.id
        requestFocus(on: root.id)
    }

    func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(root).write(to: url, options: .atomic)
    }

    func open(_ url: URL) throws {
        let decoded = try JSONDecoder().decode(MindNode.self, from: Data(contentsOf: url))
        root = decoded
        selectedID = decoded.id
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
