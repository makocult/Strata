import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @ObservedObject var store: MindMapStore
    @ObservedObject var library: MaterialLibraryStore

    @State private var orientation = StrataLayoutOrientation.horizontal
    @State private var showLibrary = false
    @State private var showAI = false
    @State private var error = ""
    @State private var copied = false
    @State private var resetAction: ResetAction?
    @State private var confirmOptimize = false
    @State private var optimizeTask: Task<Void, Never>?
    @StateObject private var ai = AIWorkflow()
    @StateObject private var canvasBridge = CanvasBridge()

    enum ResetAction: String, Identifiable {
        case new = "新建工作"
        case clear = "清空画布"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTopBar(
                store: store,
                orientation: $orientation,
                libraryVisible: showLibrary,
                isGenerating: ai.isGenerating,
                isOptimizing: ai.isOptimizing,
                canOptimize: !store.isEmptyDocument && !ai.isGenerating && !ai.isOptimizing && !ai.configuration.model.isEmpty,
                canCopy: !store.isEmptyDocument,
                canAnnotate: canvasBridge.selectedNodeCount >= 2,
                annotate: { canvasBridge.requestAnnotation() },
                newDocument: { requestReset(.new) },
                clearDocument: { requestReset(.clear) },
                openDocument: open,
                saveDocument: save,
                toggleLibrary: toggleLibrary,
                generateWithAI: openAI,
                optimizeWithAI: { confirmOptimize = true },
                copyPrompt: copyPrompt
            )

            Divider()

            HStack(spacing: 0) {
                WorkspaceSidebar(
                    libraryVisible: showLibrary,
                    openLibrary: { if !showLibrary { toggleLibrary() } },
                    openAI: openAI
                )

                Divider()

                ZStack(alignment: .bottomLeading) {
                    NativeCanvas(store: store, orientation: orientation, bridge: canvasBridge)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    CanvasHint()
                        .padding(16)
                }

                if showLibrary {
                    Divider()
                    MaterialLibraryPanel(library: library, store: store) { showLibrary = false }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.18), value: showLibrary)
        .sheet(isPresented: $showAI) {
            AIGenerationSheet(workflow: ai, store: store)
        }
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
            if copied {
                Label("已复制提示词", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
                    .padding(.top, 84)
                    .allowsHitTesting(false)
                    .task {
                        do { try await Task.sleep(for: .seconds(1.8)) } catch { return }
                        copied = false
                    }
            }
        }
        .overlay {
            if ai.isOptimizing {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("AI 正在优化提示词").font(.headline)
                    }
                    AIElapsedStatus(title: "正在调整结构与表达", startedAt: ai.startedAt)
                        .frame(width: 280)
                    HStack {
                        Spacer()
                        Button("取消") { optimizeTask?.cancel() }
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.08))
                }
                .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
            }
        }
        .alert("操作失败", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
            Button("好") { error = "" }
        } message: {
            Text(error)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newStrataDocument)) { _ in requestReset(.new) }
        .onReceive(NotificationCenter.default.publisher(for: .clearStrataDocument)) { _ in requestReset(.clear) }
    }

    private func toggleLibrary() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        showLibrary.toggle()
    }

    private func openAI() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        showAI = true
    }

    private func requestReset(_ action: ResetAction) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if store.isEmptyDocument {
            reset()
        } else {
            resetAction = action
        }
    }

    private func reset() {
        resetAction = nil
        copied = false
        showAI = false
        optimizeTask?.cancel()
        store.reset()
    }

    private func copyPrompt() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let text = store.textExport()
        guard pasteboard.setString(text, forType: .string), pasteboard.string(forType: .string) == text else {
            error = "复制失败，请重试。"
            return
        }
        copied = true
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.open(url) } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Strata.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.save(url) } catch { self.error = error.localizedDescription }
        }
    }
}

private struct WorkspaceTopBar: View {
    @ObservedObject var store: MindMapStore
    @Binding var orientation: StrataLayoutOrientation
    let libraryVisible: Bool
    let isGenerating: Bool
    let isOptimizing: Bool
    let canOptimize: Bool
    let canCopy: Bool
    let canAnnotate: Bool
    let annotate: () -> Void
    let newDocument: () -> Void
    let clearDocument: () -> Void
    let openDocument: () -> Void
    let saveDocument: () -> Void
    let toggleLibrary: () -> Void
    let generateWithAI: () -> Void
    let optimizeWithAI: () -> Void
    let copyPrompt: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Strata")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("专注思考 · 让想法层层展开")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 190, alignment: .leading)

            Spacer(minLength: 12)

            HStack(spacing: 4) {
                ToolbarAction(title: "添加", systemImage: "plus", action: newDocument)
                    .help("新建工作（⌘N）")
                    .accessibilityIdentifier("new-document")
                ToolbarAction(title: "清空", systemImage: "trash", action: clearDocument)
                    .help("清空当前画布")
                    .accessibilityIdentifier("clear-document")
                ToolbarAction(title: "撤销", systemImage: "arrow.uturn.left", disabled: !store.canUndo, action: { store.undo() })
                    .help("撤销上一步（⌘Z）")
                ToolbarAction(title: "重做", systemImage: "arrow.uturn.right", disabled: !store.canRedo, action: { store.redo() })
                    .help("重复上一步（⌘Shift+Z）")
            }

            ToolbarSeparator()

            HStack(spacing: 4) {
                ToolbarAction(title: "打开", systemImage: "folder", action: openDocument)
                ToolbarAction(title: "保存", systemImage: "square.and.arrow.down", action: saveDocument)
            }

            ToolbarSeparator()

            LayoutControl(orientation: $orientation)

            ToolbarSeparator()

            HStack(spacing: 4) {
                ToolbarAction(title: "素材", systemImage: "square.grid.2x2", isActive: libraryVisible, action: toggleLibrary)
                    .accessibilityIdentifier("material-library-toggle")
                ToolbarAction(title: "整理", systemImage: "sparkles", disabled: isOptimizing, action: generateWithAI)
                    .help("根据材料生成思维导图")
                ToolbarAction(title: "优化", systemImage: "wand.and.stars", disabled: !canOptimize, action: optimizeWithAI)
                    .help("将当前思考结构整理为可直接使用的提示词")
            }

            ToolbarSeparator()

            HStack(spacing: 4) {
                ToolbarAction(title: "标注", systemImage: "text.badge.plus", disabled: !canAnnotate, action: annotate)
                    .help("为选中的多个节点添加大括号备注")
            }

            CopyPromptButton(disabled: !canCopy, action: copyPrompt)
        }
        .padding(.leading, 82)
        .padding(.trailing, 16)
        .frame(height: 72)
        .background(.ultraThinMaterial)
    }
}

private struct ToolbarAction: View {
    let title: String
    let systemImage: String
    var isActive = false
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 17)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(isActive ? Color.accentColor : Color.primary.opacity(disabled ? 0.38 : 0.8))
            .frame(width: 48, height: 46)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.11) : hovering ? Color.primary.opacity(0.055) : .clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}

private struct ToolbarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 30)
            .padding(.horizontal, 1)
    }
}

private struct LayoutControl: View {
    @Binding var orientation: StrataLayoutOrientation

    var body: some View {
        HStack(spacing: 2) {
            LayoutChoice(
                title: "横向",
                systemImage: "arrow.left.and.right",
                selected: orientation == .horizontal,
                action: { orientation = .horizontal }
            )
            LayoutChoice(
                title: "纵向",
                systemImage: "arrow.up.and.down",
                selected: orientation == .vertical,
                action: { orientation = .vertical }
            )
        }
        .padding(3)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct LayoutChoice: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11.5, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color(nsColor: .windowBackgroundColor) : .clear)
                    .shadow(color: selected ? .black.opacity(0.08) : .clear, radius: 2, y: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct CopyPromptButton: View {
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "doc.on.doc")
                Text("复制提示词")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(disabled ? Color.secondary.opacity(0.55) : Color.primary.opacity(0.86))
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering && !disabled ? Color.primary.opacity(0.055) : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(0.07))
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help("复制当前导图的文本提示词")
    }
}

private struct WorkspaceSidebar: View {
    let libraryVisible: Bool
    let openLibrary: () -> Void
    let openAI: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SidebarItem(title: "思维导图", systemImage: "point.3.connected.trianglepath.dotted", selected: true, action: {})
            SidebarItem(title: "素材库", systemImage: "square.grid.2x2", selected: libraryVisible, action: openLibrary)
            SidebarItem(title: "AI 整理", systemImage: "sparkles", selected: false, action: openAI)

            Spacer()

            Divider().padding(.bottom, 4)

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("快捷提示")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("⌘Z 撤销 · ⌘Shift+Z 重做 · Tab 新建子级")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .padding(12)
        .frame(width: 216)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }
}

private struct SidebarItem: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                Spacer()
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.75))
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.11) : hovering ? Color.primary.opacity(0.045) : .clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct CanvasHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.motionlines")
            Text("拖动空白处平移 · 滚轮缩放")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(Color.primary.opacity(0.06)) }
        .allowsHitTesting(false)
    }
}
