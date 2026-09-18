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

    private var results: [LibraryMaterial] { library.matching(query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("素材库")
                        .font(.system(size: 17, weight: .semibold))
                    Text("保存并复用常用内容")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    draft = MaterialDraft()
                } label: {
                    Label("新增", systemImage: "plus")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                }
                .buttonStyle(.bordered)
                .disabled(!library.loadError.isEmpty)
                .accessibilityIdentifier("material-add")

                Button(action: close) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help("收起素材库")
                .accessibilityLabel("收起素材库")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("搜索标题或内容", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("material-search")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.07))
            }
            .padding(.horizontal, 16)

            HStack {
                Text(query.isEmpty ? "全部素材" : "搜索结果")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(results.count) 项")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if !library.loadError.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label(library.loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("重新读取") { library.reload() }
                }
                .font(.system(size: 12))
                .padding(16)
                Spacer()
            } else {
                ScrollView {
                    if results.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: query.isEmpty ? "square.grid.2x2" : "magnifyingglass")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text(query.isEmpty ? "还没有素材" : "没有找到匹配素材")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)
                            if query.isEmpty {
                                Text("点击顶部「新增」，保存常用文本。")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 54)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(results) { material in
                                MaterialCard(
                                    material: material,
                                    canInsert: store.node(store.selectedID) != nil,
                                    insert: {
                                        NSApp.keyWindow?.makeFirstResponder(nil)
                                        if MaterialInsertion.insert(material, into: store) == nil {
                                            error = "请先在画布中选中一个节点。"
                                        }
                                    },
                                    edit: {
                                        NSApp.keyWindow?.makeFirstResponder(nil)
                                        draft = MaterialDraft(material: material)
                                    },
                                    delete: { deleting = material }
                                )
                            }
                        }
                        .padding(12)
                    }
                }

                Divider()

                HStack(spacing: 7) {
                    Image(systemName: store.node(store.selectedID) == nil ? "cursorarrow.click" : "plus.circle")
                    Text(store.node(store.selectedID) == nil ? "先选中画布节点，再点击素材插入。" : "点击素材，将正文添加为选中节点的子节点。")
                        .lineLimit(2)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
            }
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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
        } message: {
            Text("删除「\(deleting?.title ?? "")」？已插入导图的内容会保留。")
        }
        .alert("素材操作失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
            Button("好") { error = "" }
        } message: {
            Text(error)
        }
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
        Button(action: insert) {
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                    Image(systemName: "doc.text")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: material.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .padding(.trailing, 22)
                    Text(verbatim: material.content)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canInsert)
        .opacity(canInsert ? 1 : 0.72)
        .background(
            hovering && canInsert ? Color.accentColor.opacity(0.055) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(hovering && canInsert ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.07))
        }
        .overlay(alignment: .topTrailing) {
            Menu {
                Button("查看／编辑", action: edit)
                Button("删除", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(7)
            .accessibilityLabel("素材操作：\(material.title)")
        }
        .contextMenu {
            Button("查看／编辑", action: edit)
            Button("删除", role: .destructive, action: delete)
        }
        .onHover { hovering = $0 }
        .help(canInsert ? "点击插入正文；通过右上角菜单查看、编辑或删除。" : "请先在画布中选中一个节点。")
        .accessibilityLabel("插入素材：\(material.title)")
        .accessibilityIdentifier("material-card-\(material.id)")
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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.materialID == nil ? "新增素材" : "编辑素材")
                    .font(.system(size: 18, weight: .semibold))
                Text("标题用于查找；插入节点时只使用正文。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)

            Text("标题")
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.bottom, 7)
            TextField("便于查找的素材标题", text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .accessibilityIdentifier("material-title")

            Text("内容")
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.top, 16)
                .padding(.bottom, 7)
            TextEditor(text: $draft.content)
                .font(.system(size: 12.5))
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                }
                .accessibilityLabel("素材正文")
                .accessibilityIdentifier("material-content")

            if !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try library.save(id: draft.materialID, title: draft.title, content: draft.content)
                        saved()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(
                    draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityIdentifier("material-save")
            }
            .padding(.top, 18)
        }
        .padding(24)
        .frame(width: 540, height: 480)
        .onAppear { titleFocused = true }
    }
}
