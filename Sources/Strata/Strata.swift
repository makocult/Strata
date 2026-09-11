import Foundation
import SwiftUI

struct MindNode: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var children: [MindNode]
    init(id: UUID = UUID(), title: String, children: [MindNode] = []) { self.id = id; self.title = title; self.children = children }
}

@MainActor final class MindMapStore: ObservableObject {
    @Published var root = MindNode(title: "主题")
    @Published var selectedID: UUID?
    init() { selectedID = root.id }
    func addChild() { guard let id = selectedID else { return }; update(id) { $0.children.append(MindNode(title: "新节点")) }; selectedID = node(id)?.children.last?.id }
    func addSibling() { guard let id = selectedID, id != root.id, let parent = parent(of: id) else { return }; update(parent) { p in if let i = p.children.firstIndex(where: {$0.id == id}) { p.children.insert(MindNode(title: "新节点"), at: i + 1) } }; selectedID = node(parent)?.children.last?.id }
    func deleteSelected() { guard let id = selectedID, id != root.id, let p = parent(of: id) else { return }; update(p) { $0.children.removeAll {$0.id == id} }; selectedID = p }
    func rename(_ text: String) { guard let id = selectedID else { return }; update(id) { $0.title = text } }
    func move(_ id: UUID, to parentID: UUID) { guard id != parentID, let moving = remove(id, from: &root), node(parentID) != nil else { return }; update(parentID) { $0.children.append(moving) }; selectedID = id }
    func save(to url: URL) throws { try JSONEncoder().encode(root).write(to: url, options: .atomic) }
    func load(from url: URL) throws { root = try JSONDecoder().decode(MindNode.self, from: Data(contentsOf: url)); selectedID = root.id }
    func leafText() -> String { leaves(root).joined(separator: "\n") }
    func node(_ id: UUID) -> MindNode? { find(id, in: root) }
    private func update(_ id: UUID, _ f: (inout MindNode)->Void) { func walk(_ n: inout MindNode) { if n.id == id { f(&n); return }; for i in n.children.indices { walk(&n.children[i]) } }; walk(&root) }
    private func find(_ id: UUID, in n: MindNode) -> MindNode? { if n.id == id { return n }; for c in n.children { if let x = find(id, in: c) { return x } }; return nil }
    private func parent(of id: UUID) -> UUID? { func walk(_ n: MindNode) -> UUID? { if n.children.contains(where: {$0.id == id}) { return n.id }; for c in n.children { if let x = walk(c) { return x } }; return nil }; return walk(root) }
    private func remove(_ id: UUID, from n: inout MindNode) -> MindNode? { if let i = n.children.firstIndex(where: {$0.id == id}) { return n.children.remove(at: i) }; for i in n.children.indices { if let x = remove(id, from: &n.children[i]) { return x } }; return nil }
    private func leaves(_ n: MindNode) -> [String] { n.children.isEmpty ? [n.title] : n.children.flatMap(leaves) }
}

struct ContentView: View {
    @ObservedObject var store: MindMapStore
    @State private var draft = ""
    @State private var showText = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { Button("＋ 子节点") { store.addChild() }; Button("＋ 同级") { store.addSibling() }; Button("删除") { store.deleteSelected() }; Spacer(); Button("打开") { open() }; Button("保存") { save() }; Button("末级转纯文本") { showText = true } }.padding()
            Divider()
            ScrollView([.horizontal, .vertical]) { NodeView(node: store.root, store: store).padding(50) }
        }
        .sheet(isPresented: $showText) { VStack(alignment: .leading) { Text("末级节点").font(.headline); TextEditor(text: .constant(store.leafText())).frame(minWidth: 500, minHeight: 300); Button("关闭") { showText = false } }.padding() }
        .onChange(of: store.selectedID) { _, id in draft = store.node(id ?? store.root.id)?.title ?? "" }
    }
    private func save() { let p = NSSavePanel(); p.allowedContentTypes = [.json]; p.nameFieldStringValue = "Strata.json"; if p.runModal() == .OK, let u = p.url { try? store.save(to: u) } }
    private func open() { let p = NSOpenPanel(); p.allowedContentTypes = [.json]; if p.runModal() == .OK, let u = p.url { try? store.load(from: u) } }
}

struct NodeView: View {
    let node: MindNode; @ObservedObject var store: MindMapStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(node.title)
                .padding(10)
                .background(node.id == store.selectedID ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { store.selectedID = node.id }
            if !node.children.isEmpty {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(node.children) { child in
                        NodeView(node: child, store: store)
                            .onDrag { NSItemProvider(object: child.id.uuidString as NSString) }
                    }
                }
            }
        }
    }
}
