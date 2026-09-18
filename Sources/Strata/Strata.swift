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
