import Foundation
import SwiftUI

struct MindNode: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var children: [MindNode]

    init(id: UUID = UUID(), title: String, children: [MindNode] = []) {
        self.id = id
        self.title = title
        self.children = children
    }
}

@MainActor
final class MindMapStore: ObservableObject {
    @Published var root = MindNode(title: "新思维导图")
    @Published var selectedID: UUID?
    @Published var comparisonDepth = 1

    private var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Strata", isDirectory: true)
            .appendingPathComponent("map.json")
    }

    init() {
        load()
        selectedID = root.id
    }

    var selectedPath: [MindNode] {
        path(to: selectedID, in: root) ?? [root]
    }

    func addChild() {
        guard let id = selectedID else { return }
        updateNode(id) { node in node.children.append(MindNode(title: "新节点")) }
        selectedID = nodeChildren(of: id).last?.id
        save()
    }

    func addSibling() {
        guard let id = selectedID, id != root.id else { addChild(); return }
        guard let parentID = parentID(of: id, in: root) else { return }
        updateNode(parentID) { parent in
            guard let index = parent.children.firstIndex(where: { $0.id == id }) else { return }
            parent.children.insert(MindNode(title: "新节点"), at: index + 1)
        }
        selectedID = children(of: parentID).last(where: { $0.title == "新节点" })?.id
        save()
    }

    func updateTitle(_ title: String) {
        guard let id = selectedID else { return }
        updateNode(id) { $0.title = title }
        save()
    }

    func deleteSelected() {
        guard let id = selectedID, id != root.id, let parent = parentID(of: id, in: root) else { return }
        updateNode(parent) { $0.children.removeAll { $0.id == id } }
        selectedID = parent
        save()
    }

    func nodes(at depth: Int) -> [(node: MindNode, path: [MindNode])] {
        var result: [(MindNode, [MindNode])] = []
        collect(root, path: [root], depth: 0, target: depth, into: &result)
        return result
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(root).write(to: fileURL, options: .atomic)
        } catch { print("Strata save failed: \(error)") }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), let value = try? JSONDecoder().decode(MindNode.self, from: data) else { return }
        root = value
    }

    private func children(of id: UUID) -> [MindNode] { node(with: id, in: root)?.children ?? [] }
    private func nodeChildren(of id: UUID) -> [MindNode] { children(of: id) }

    private func updateNode(_ id: UUID, _ change: (inout MindNode) -> Void) {
        func walk(_ node: inout MindNode) {
            if node.id == id { change(&node); return }
            for index in node.children.indices { walk(&node.children[index]) }
        }
        walk(&root)
    }

    private func node(with id: UUID, in node: MindNode) -> MindNode? {
        if node.id == id { return node }
        for child in node.children { if let found = self.node(with: id, in: child) { return found } }
        return nil
    }

    private func parentID(of id: UUID, in node: MindNode) -> UUID? {
        if node.children.contains(where: { $0.id == id }) { return node.id }
        for child in node.children { if let found = parentID(of: id, in: child) { return found } }
        return nil
    }

    func path(to id: UUID?, in node: MindNode) -> [MindNode]? {
        guard let id else { return nil }
        if node.id == id { return [node] }
        for child in node.children { if let path = path(to: id, in: child) { return [node] + path } }
        return nil
    }

    private func collect(_ node: MindNode, path: [MindNode], depth: Int, target: Int, into result: inout [(MindNode, [MindNode])]) {
        if depth == target { result.append((node, path)); return }
        for child in node.children { collect(child, path: path + [child], depth: depth + 1, target: target, into: &result) }
    }
}

struct ContentView: View {
    @ObservedObject var store: MindMapStore
    @State private var titleDraft = ""
    @State private var mode = 0

    var body: some View {
        NavigationSplitView {
            List(selection: $store.selectedID) { NodeRow(node: store.root) }
                .navigationTitle("Strata")
                .toolbar { ToolbarItemGroup { Button("＋") { store.addChild() }; Button("−") { store.deleteSelected() } } }
        } detail: {
            VStack(spacing: 0) {
                Picker("视图", selection: $mode) { Text("结构地图").tag(0); Text("层级审查").tag(1) }.pickerStyle(.segmented).padding()
                if mode == 0 { StructureView(store: store) } else { LevelView(store: store) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: store.selectedID) { _, id in titleDraft = store.path(to: id, in: store.root)?.last?.title ?? "" }
    }
}

struct NodeRow: View {
    let node: MindNode
    var body: some View {
        DisclosureGroup(node.title) { ForEach(node.children) { NodeRow(node: $0) } }
            .tag(node.id)
    }
}

struct StructureView: View {
    @ObservedObject var store: MindMapStore
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 32) { NodeCard(node: store.root, store: store) }
                .padding(40)
        }
    }
}

struct NodeCard: View {
    let node: MindNode
    @ObservedObject var store: MindMapStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(node.title).font(.headline).padding(10).background(node.id == store.selectedID ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8)).onTapGesture { store.selectedID = node.id }
            if !node.children.isEmpty { HStack(alignment: .top, spacing: 18) { ForEach(node.children) { NodeCard(node: $0, store: store) } } }
        }
    }
}

struct LevelView: View {
    @ObservedObject var store: MindMapStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Stepper("查看第 \(store.comparisonDepth) 层", value: $store.comparisonDepth, in: 1...12).padding(.horizontal)
            Text("同一层级的节点横向排列，保留祖先路径用于比较。") .foregroundStyle(.secondary).padding(.horizontal)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(store.nodes(at: store.comparisonDepth).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 16) {
                            Text(item.path.dropLast().map(\.title).joined(separator: " › "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 260, alignment: .leading)
                            Text(item.node.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .onTapGesture { store.selectedID = item.node.id }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
