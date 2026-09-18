import Foundation
import CFNetwork

struct AIConfiguration: Codable, Equatable, Sendable {
    var baseURL = "https://api.openai.com/v1"
    var model = ""
    var proxyURL = ""

    enum CodingKeys: String, CodingKey { case baseURL, model, proxyURL }

    init(baseURL: String = "https://api.openai.com/v1", model: String = "", proxyURL: String = "") {
        self.baseURL = baseURL; self.model = model; self.proxyURL = proxyURL
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        proxyURL = try values.decodeIfPresent(String.self, forKey: .proxyURL) ?? ""
    }

    func endpoint(_ resource: String) throws -> URL {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme, ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw AIError.message("请输入有效的 API 基础地址，不要包含密钥、查询参数或接口名称。")
        }
        guard scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
            throw AIError.message("远程 API 请使用 HTTPS，避免明文传输密钥。")
        }
        guard !url.path.hasSuffix("/chat/completions"), !url.path.hasSuffix("/models") else {
            throw AIError.message("请填写 API 基础地址，例如 https://api.openai.com/v1。")
        }
        return url.appendingPathComponent(resource)
    }
}

enum AIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

// Never forward credentials or prompts through an HTTP redirect.
final class AIRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AIClient: Sendable {
    let session: URLSession?

    init(session: URLSession? = nil) { self.session = session }

    static func sessionConfiguration(for settings: AIConfiguration) throws -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        let address = settings.proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty {
            guard let proxy = URLComponents(string: address), proxy.scheme == "http",
                  let host = proxy.host, !host.isEmpty, let port = proxy.port, (1...65535).contains(port),
                  proxy.user == nil, proxy.password == nil, proxy.query == nil, proxy.fragment == nil,
                  proxy.path.isEmpty || proxy.path == "/" else {
                throw AIError.message("代理地址需为 http://主机:端口，不包含账号、密码或路径。")
            }
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port
            ]
        }
        return configuration
    }

    func request(configuration: AIConfiguration, key: String, resource: String) throws -> URLRequest {
        var request = URLRequest(url: try configuration.endpoint(resource))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 180
        return request
    }

    func generationRequest(configuration: AIConfiguration, key: String, prompt: String) throws -> URLRequest {
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.message("请先在设置中选择模型。")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.message("请输入整理需求。")
        }
        var request = try request(configuration: configuration, key: key, resource: "chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let instruction = """
        根据用户的材料和要求整理一棵完整、清晰、有层级的思维导图，使用用户的语言。
        只返回一个 JSON 对象，不要解释，不要 Markdown 代码围栏。
        格式：{"title":"主题","children":[{"title":"分支","children":[{"title":"末级","children":[]}]}]}。
        每个节点只包含 title 和 children。title 必须是非空字符串；children 必须是数组。
        保留关键细节，合理拆分节点，不生成 ID。最多 500 个节点、12 层，每个标题最多 2000 字。
        """
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "stream": false,
            "messages": [["role": "system", "content": instruction], ["role": "user", "content": prompt]]
        ])
        return request
    }

    func optimizationRequest(configuration: AIConfiguration, key: String, root: MindNode) throws -> URLRequest {
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.message("请先在 AI 整理的设置中选择模型。")
        }
        func payload(_ node: MindNode) -> [String: Any] {
            ["title": node.title, "children": node.children.map(payload)]
        }
        let source = try JSONSerialization.data(withJSONObject: payload(root))
        guard let sourceText = String(data: source, encoding: .utf8) else {
            throw AIError.message("无法读取当前导图。")
        }
        let instruction = """
        你是通用提示词编辑器。输入是一棵记录用户思考逻辑和内容结构的思维导图，不是需要机械套用固定模板的成品提示词。

        任务：将整棵思维导图整理为工具无关、可直接复制使用的高质量提示词，同时保持为可继续编辑的树结构，使用用户的语言。

        编辑原则：
        1. 保留用户的核心意图、事实、术语、例子、限制、优先级，以及有意义的父子关系。可以重排、合并和拆分节点以提高逻辑性，但不得改变原意或遗漏有效信息。
        2. 根据内容实际需要组织任务、背景、输入、受众、约束、执行要求、输出形式、例子和验收标准。只使用有助于完成任务的部分，不强行套用完整章节，也不假定提示词会交给某个特定模型或工具。
        3. 用具体动作替换含糊表达，消除无意义重复。发现冲突时不要擅自选择一方，应写成“待确认：……”并保留冲突双方。
        4. 缺失信息不等于必须补齐。只有缺失会直接阻碍任务正确执行时，才在最相关位置加入“待补充：……”；最多三项，并说明需要补充什么。不得编造事实、身份、数据、受众、工具、技术选择或用户未表达的要求。
        5. 能从现有内容可靠推导时，补足明确的输出要求和可检查的验收标准；无法可靠推导时使用“待补充”，不要伪造精确数字或格式。
        6. 节点文字应清楚、自足、可执行。角色设定仅在确实能改善专业判断时使用；不要添加空泛的专家身份、提示词理论、解释、分析过程或隐藏思考要求。

        输出要求：
        - 必须重写根节点，根据完整内容生成具体、准确的任务标题，不得保留“主题”“新节点”等占位标题。
        - 直接返回编辑后的树，不附带修改说明。
        - 只返回一个 JSON 对象，不要 Markdown 代码围栏。格式：{"title":"具体任务标题","children":[{"title":"分支","children":[]}]}。
        - 每个节点只包含 title 和 children。title 必须是非空字符串；children 必须是数组。不生成 ID。最多 500 个节点、12 层，每个标题最多 2000 字。
        """
        var request = try request(configuration: configuration, key: key, resource: "chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "stream": false,
            "messages": [["role": "system", "content": instruction], ["role": "user", "content": sourceText]]
        ])
        return request
    }

    func response(for request: URLRequest, configuration: AIConfiguration) async throws -> Data {
        let transport = try Self.sessionConfiguration(for: configuration)
        let activeSession = session ?? URLSession(configuration: transport, delegate: AIRedirectPolicy(), delegateQueue: nil)
        defer { if session == nil { activeSession.finishTasksAndInvalidate() } }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await activeSession.data(for: request)
        } catch let failure as URLError where failure.code == .secureConnectionFailed {
            throw AIError.message("TLS 安全连接失败。请检查网络或在 API 设置中填写可用代理地址；系统代理关闭时不会自动使用 Clash。")
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw AIError.message("API 未返回 HTTP 响应。") }
        guard (200..<300).contains(response.statusCode) else {
            let reason: String
            switch response.statusCode {
            case 401, 403: reason = "认证失败，请检查密钥和模型权限。"
            case 404: reason = "接口不存在，请检查 API 基础地址与模型名称。"
            case 429: reason = "请求受限或余额不足，请稍后重试并检查账户。"
            case 300..<400: reason = "API 返回重定向；为保护密钥，请直接填写最终 API 地址。"
            case 500...599: reason = "AI 服务暂时不可用，请稍后重试。"
            default: reason = "请求被拒绝，请检查服务是否兼容 Chat Completions 接口。"
            }
            throw AIError.message("HTTP \(response.statusCode)：\(reason)")
        }
        guard data.count <= 4_000_000 else { throw AIError.message("API 返回内容过大，请缩小整理范围。") }
        return data
    }

    func models(configuration: AIConfiguration, key: String) async throws -> [String] {
        var request = try request(configuration: configuration, key: key, resource: "models")
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        struct Models: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let data = try await response(for: request, configuration: configuration)
        guard let decoded = try? JSONDecoder().decode(Models.self, from: data) else {
            throw AIError.message("模型列表格式不兼容；可手动填写模型名称。")
        }
        let models = Array(Set(decoded.data.map(\.id).filter { !$0.isEmpty })).sorted()
        guard !models.isEmpty else { throw AIError.message("服务没有返回可用模型；可手动填写模型名称。") }
        return models
    }

    func generate(configuration: AIConfiguration, key: String, prompt: String) async throws -> MindNode {
        let data = try await response(for: generationRequest(configuration: configuration, key: key, prompt: prompt), configuration: configuration)
        return try parseGeneration(data)
    }

    func optimize(configuration: AIConfiguration, key: String, root: MindNode) async throws -> MindNode {
        let data = try await response(for: optimizationRequest(configuration: configuration, key: key, root: root), configuration: configuration)
        return try parseGeneration(data)
    }

    func parseGeneration(_ data: Data) throws -> MindNode {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String?; let refusal: String? }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data), let choice = completion.choices.first else {
            throw AIError.message("AI 响应格式不兼容，原导图未改变。")
        }
        if choice.finish_reason == "length" { throw AIError.message("生成内容被截断，请缩小整理范围后重试。") }
        guard choice.message.refusal == nil, var content = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw AIError.message("模型未生成内容或拒绝了请求，原导图未改变。")
        }
        if content.hasPrefix("```"), content.hasSuffix("```"), let newline = content.firstIndex(of: "\n") {
            content = String(content[content.index(after: newline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) else {
            throw AIError.message("模型未返回有效的导图 JSON，请重试。原导图未改变。")
        }
        var count = 0
        func node(_ value: Any, depth: Int) throws -> MindNode {
            count += 1
            guard depth <= 12, count <= 500,
                  let object = value as? [String: Any], let title = object["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 2000 else {
                throw AIError.message("导图结构不完整或超出限制（500 节点、12 层），请缩小范围重试。")
            }
            let children: [Any]
            if let value = object["children"] {
                guard let array = value as? [Any] else { throw AIError.message("模型返回的子节点格式无效。") }
                children = array
            } else { children = [] }
            return MindNode(title: title, children: try children.map { try node($0, depth: depth + 1) })
        }
        return try node(object, depth: 1)
    }
}