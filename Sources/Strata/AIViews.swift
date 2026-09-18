import SwiftUI

@MainActor
final class AIWorkflow: ObservableObject {
    @Published var configuration = AIConfiguration()
    @Published var prompt = ""
    @Published var isGenerating = false
    @Published var isOptimizing = false
    @Published private(set) var startedAt: Date?
    @Published var error = ""
    let storage: AISettingsStorage
    let client: AIClient

    init(storage: AISettingsStorage = AISettingsStorage(), client: AIClient = AIClient()) {
        self.storage = storage
        self.client = client
        do { configuration = try storage.load() }
        catch { self.error = "无法读取 AI 设置：\(error.localizedDescription)" }
    }

    func generate(into store: MindMapStore) async -> Bool {
        guard !isGenerating && !isOptimizing else { return false }
        isGenerating = true; startedAt = Date(); error = ""
        defer { isGenerating = false; startedAt = nil }
        let original = store.root
        do {
            let configuration = configuration
            let key = try storage.key(for: configuration)
            let root = try await client.generate(configuration: configuration, key: key, prompt: prompt)
            try Task.checkCancellation()
            guard store.root == original else { throw AIError.message("当前导图已改变，未覆盖内容，请重新生成。") }
            store.replaceRoot(with: root)
            return true
        } catch is CancellationError {
            return false
        } catch let failure as URLError where failure.code == .cancelled {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func optimize(_ store: MindMapStore) async -> Bool {
        guard !isGenerating && !isOptimizing else { return false }
        isOptimizing = true; startedAt = Date(); error = ""
        defer { isOptimizing = false; startedAt = nil }
        let original = store.root
        do {
            let configuration = configuration
            let key = try storage.key(for: configuration)
            let root = try await client.optimize(configuration: configuration, key: key, root: original)
            try Task.checkCancellation()
            guard store.root == original else { throw AIError.message("当前导图已改变，未覆盖内容，请重新优化。") }
            store.replaceRoot(with: root)
            return true
        } catch is CancellationError {
            return false
        } catch let failure as URLError where failure.code == .cancelled {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct AIElapsedStatus: View {
    let title: String
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt ?? context.date)))
            VStack(alignment: .leading, spacing: 6) {
                ProgressView().progressViewStyle(.linear)
                Text("\(title) · 已等待 \(seconds) 秒").foregroundStyle(.secondary)
            }
        }
    }
}

struct AIGenerationSheet: View {
    @ObservedObject var workflow: AIWorkflow
    @ObservedObject var store: MindMapStore
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var confirmReplace = false
    @State private var generation: Task<Void, Never>?
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("AI 整理").font(.headline)
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("API 设置").disabled(workflow.isGenerating)
            }
            TextEditor(text: $workflow.prompt)
                .font(.body).focused($promptFocused)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                .accessibilityLabel("提示词与整理需求")
                .disabled(workflow.isGenerating)
            if !workflow.error.isEmpty {
                Text(workflow.error).foregroundStyle(.red).textSelection(.enabled).lineLimit(4)
            }
            if workflow.isGenerating {
                AIElapsedStatus(title: "正在生成导图", startedAt: workflow.startedAt)
            }
            HStack(spacing: 12) {
                if !workflow.isGenerating {
                    Text(workflow.configuration.model.isEmpty ? "未选择模型" : workflow.configuration.model)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(workflow.isGenerating ? "取消生成" : "关闭") {
                    if workflow.isGenerating { generation?.cancel() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
                Button("生成导图") {
                    if store.root.children.isEmpty && store.root.title == "主题" { start() }
                    else { confirmReplace = true }
                }
                .buttonStyle(.borderedProminent)
                .disabled(workflow.isGenerating || workflow.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workflow.configuration.model.isEmpty)
            }
        }
        .padding(24).frame(width: 680, height: 520)
        .interactiveDismissDisabled(workflow.isGenerating)
        .onAppear { promptFocused = true }
        .onDisappear { generation?.cancel() }
        .sheet(isPresented: $showSettings) { AISettingsSheet(workflow: workflow) }
        .alert("替换当前导图？", isPresented: $confirmReplace) {
            Button("取消", role: .cancel) {}
            Button("生成并替换", role: .destructive) { start() }
        } message: {
            Text("生成成功后会替换当前内容，未保存的内容将丢失。生成失败或取消不会改变当前导图。")
        }
    }

    private func start() {
        generation = Task {
            if await workflow.generate(into: store) { dismiss() }
        }
    }
}

struct AISettingsSheet: View {
    @ObservedObject var workflow: AIWorkflow
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AIConfiguration()
    @State private var key = ""
    @State private var models: [String] = []
    @State private var error = ""
    @State private var loading = false
    @State private var ready = false
    @State private var credentialLoaded = false
    @State private var modelTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("API 设置").font(.headline)
            Form {
                TextField("API URL", text: Binding(get: { draft.baseURL }, set: { value in
                    guard value != draft.baseURL else { return }
                    draft.baseURL = value
                    models = []; draft.model = ""; key = ""; credentialLoaded = true
                }), prompt: Text("https://api.openai.com/v1"))
                TextField("代理地址（可选）", text: $draft.proxyURL, prompt: Text("http://127.0.0.1:7897"))
                SecureField("API 密钥", text: $key)
                    .onChange(of: key) { _, _ in if ready { credentialLoaded = true } }
                HStack {
                    TextField("模型名称", text: $draft.model)
                    if !models.isEmpty {
                        Menu {
                            ForEach(models, id: \.self) { model in
                                Button(model) { draft.model = model }
                            }
                        } label: { Image(systemName: "chevron.down") }
                        .help("选择模型").fixedSize()
                    }
                }
            }.textFieldStyle(.roundedBorder)
                .disabled(loading)
            HStack {
                Button("读取模型") { fetchModels() }.disabled(loading || !credentialLoaded)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled).lineLimit(4) }
            HStack {
                Button("取消") { modelTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    do {
                        try workflow.storage.save(draft, key: key)
                        workflow.configuration = draft
                        workflow.error = ""
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(loading || !credentialLoaded)
            }
        }
        .padding(24).frame(width: 520)
        .onAppear {
            draft = workflow.configuration
            loadKey()
            ready = true
        }

        .onDisappear { modelTask?.cancel(); key = "" }
    }

    private func loadKey() {
        do { key = try workflow.storage.key(for: draft); credentialLoaded = true }
        catch { self.error = error.localizedDescription; credentialLoaded = false }
    }

    private func fetchModels() {
        loading = true; error = ""
        let configuration = draft, credential = key
        modelTask = Task {
            defer { loading = false }
            do {
                let fetched = try await workflow.client.models(configuration: configuration, key: credential)
                try Task.checkCancellation()
                models = fetched
                if draft.model.isEmpty { draft.model = fetched[0] }
            } catch is CancellationError {
            } catch let failure as URLError where failure.code == .cancelled {
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct LayoutSwitch: View {
    @Binding var orientation: StrataLayoutOrientation

    var body: some View {
        HStack(spacing: 2) {
            option(.horizontal, title: "横向")
            option(.vertical, title: "纵向")
        }
        .padding(3)
        .background(Color(nsColor: .quaternaryLabelColor), in: RoundedRectangle(cornerRadius: 8))
        .fixedSize()
    }

    private func option(_ value: StrataLayoutOrientation, title: String) -> some View {
        Button { orientation = value } label: {
            Text(title).font(.system(size: 12, weight: .medium))
                .frame(width: 50, height: 24)
                .background(orientation == value ? Color(nsColor: .controlBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(orientation == value ? .isSelected : [])
        .help(title + "布局")
    }
}