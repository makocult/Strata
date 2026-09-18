import SwiftUI

@MainActor
enum MaterialInsertion {
    @discardableResult
    static func insert(_ material: LibraryMaterial, into store: MindMapStore) -> UUID? {
        guard let parentID = store.selectedID else { return nil }
        return store.createChild(of: parentID, title: material.content)
    }
}

struct MaterialLibraryPanel: View {
    @ObservedObject var library: MaterialLibraryStore
    @ObservedObject var store: MindMapStore
    let close: () -> Void
    @State private var query = ""
    @State private var draft: MaterialDraft?
    @State private var deleting: LibraryMaterial?
    @State private var error = ""

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("素材库").font(.headline)
                Spacer()
                Button {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    draft = MaterialDraft()
                } label: { Label("新增", systemImage: "plus") }
                    .disabled(!library.loadError.isEmpty)
                    .accessibilityIdentifier("material-add")
                Button(action: close) { Image(systemName: "sidebar.right") }
                    .help("收起素材库")
                    .accessibilityLabel("收起素材库")
            }
            .padding(16)
            TextField("搜索标题或内容", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("material-search")
                .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            if !library.loadError.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(library.loadError).foregroundStyle(.red).textSelection(.enabled)
                    Button("重新读取") { library.reload() }
                }.padding(16)
                Spacer()
            } else {
                ScrollView {
                    if library.matching(query).isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.tertiary)
                            Text(query.isEmpty ? "还没有素材" : "没有找到匹配素材").foregroundStyle(.secondary)
                            if query.isEmpty { Text("点击顶部「新增」，保存常用文本。") .font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(library.matching(query)) { material in
                                MaterialCard(material: material, canInsert: store.node(store.selectedID) != nil, insert: {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                    if MaterialInsertion.insert(material, into: store) == nil {
                                        error = "请先在画布中选中一个节点。"
                                    }
                                }, edit: {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                    draft = MaterialDraft(material: material)
                                }, delete: { deleting = material })
                            }
                        }.padding(16)
                    }
                }
                Divider()
                Text(store.node(store.selectedID) == nil ? "先选中画布节点，再点击素材插入。" : "点击卡片，将正文添加为选中节点的子节点。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(16)
            }
        }
        .frame(width: 332)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("material-library-panel")
        .sheet(item: $draft) { draft in
            MaterialEditorSheet(library: library, draft: draft) { query = "" }
        }
        .alert("删除素材？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                guard let material = deleting else { return }
                do { try library.delete(material.id) } catch { self.error = error.localizedDescription }
                deleting = nil
            }
        } message: { Text("删除「\(deleting?.title ?? "")」？已插入导图的内容会保留。") }
        .alert("素材操作失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
            Button("好") { error = "" }
        } message: { Text(error) }
    }
}

struct MaterialCard: View {
    let material: LibraryMaterial
    let canInsert: Bool
    let insert: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Button(action: insert) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: material.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2).padding(.trailing, 20)
                        Text(verbatim: material.content)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(5)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canInsert)
                .accessibilityLabel("插入素材：\(material.title)")
                .accessibilityIdentifier("material-card-\(material.id)")
            }
            .background(hovering ? Color.accentColor.opacity(0.08) : Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hovering ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor)))
            .overlay(alignment: .topTrailing) {
                Menu {
                    Button("查看／编辑", action: edit)
                    Button("删除", role: .destructive, action: delete)
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize().padding(7)
                    .accessibilityLabel("素材操作：\(material.title)")
            }
            .contextMenu {
                Button("查看／编辑", action: edit)
                Button("删除", role: .destructive, action: delete)
            }
            .onHover { hovering = $0 }
            .help(canInsert ? "点击插入正文；通过右上角菜单查看、编辑或删除。" : "请先在画布中选中一个节点。")
    }
}

struct MaterialDraft: Identifiable {
    let id = UUID()
    var materialID: UUID?
    var title = ""
    var content = ""

    init(material: LibraryMaterial? = nil) {
        materialID = material?.id
        title = material?.title ?? ""
        content = material?.content ?? ""
    }
}

struct MaterialEditorSheet: View {
    @ObservedObject var library: MaterialLibraryStore
    @State var draft: MaterialDraft
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.materialID == nil ? "新增素材" : "编辑素材").font(.headline)
            Text("标题").font(.subheadline)
            TextField("便于查找的素材标题", text: $draft.title)
                .textFieldStyle(.roundedBorder).focused($titleFocused)
                .accessibilityIdentifier("material-title")
            Text("内容").font(.subheadline)
            TextEditor(text: $draft.content)
                .font(.body).padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                .accessibilityLabel("素材正文")
                .accessibilityIdentifier("material-content")
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("插入节点时只使用正文。") .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try library.save(id: draft.materialID, title: draft.title, content: draft.content)
                        saved(); dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("material-save")
            }
        }
        .padding(24).frame(width: 520, height: 460)
        .onAppear { titleFocused = true }
    }
}
