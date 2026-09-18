import Foundation

// Protocol fixtures exercise the actual URLSession path, not a live AI service.
final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path.contains("slow") { return }
        if request.url!.path.contains("tls-failure") {
            client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed))
            return
        }
        let status = request.url!.path.contains("unauthorized") ? 401 : 200
        let payload = request.url!.path.hasSuffix("models")
            ? #"{"data":[{"id":"b"},{"id":"a"},{"id":"a"}]}"#
            : #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"title\":\"Generated\",\"children\":[{\"title\":\"Editable\"}]}"}}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct AISmoke {
    @MainActor static func main() async throws {
        let configuration = AIConfiguration(baseURL: "https://example.com/v1", model: "test-model")
        let client = AIClient()
        let proxyJSON = Data(#"{"baseURL":"https://example.com/v1","model":"test-model","proxyURL":"http://127.0.0.1:7897"}"#.utf8)
        let proxied = try JSONDecoder().decode(AIConfiguration.self, from: proxyJSON)
        let proxyRoundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proxied)) as! [String: Any]
        assert(proxyRoundTrip["proxyURL"] as? String == "http://127.0.0.1:7897", "Explicit proxy must survive settings persistence")
        let legacy = try JSONDecoder().decode(AIConfiguration.self, from: Data(#"{"baseURL":"https://example.com/v1","model":"test-model"}"#.utf8))
        assert(legacy == configuration && legacy.proxyURL.isEmpty)
        let transport = try AIClient.sessionConfiguration(for: proxied)
        assert(transport.connectionProxyDictionary?["HTTPSProxy"] as? String == "127.0.0.1")
        assert(transport.connectionProxyDictionary?["HTTPSPort"] as? Int == 7897)
        assert(transport.connectionProxyDictionary?["HTTPSEnable"] as? Int == 1)
        let systemTransport = try AIClient.sessionConfiguration(for: legacy)
        assert(systemTransport.connectionProxyDictionary == nil)
        for address in ["socks5://localhost:7897", "http://localhost", "http://localhost:0", "http://localhost:70000", "http://user:password@localhost:7897", "http://localhost:7897/path", "http://localhost:7897?key=fixture"] {
            do {
                _ = try AIClient.sessionConfiguration(for: AIConfiguration(proxyURL: address))
                assertionFailure("Invalid proxy accepted")
            } catch {}
        }
        print("PASS: proxy persistence, legacy settings migration, HTTPS proxy routing, invalid proxy rejection")
        let prompt = String(repeating: "Long prompt\n", count: 10000)
        let request = try client.generationRequest(configuration: configuration, key: "fixture-token", prompt: prompt)
        assert(request.url?.absoluteString == "https://example.com/v1/chat/completions")
        assert(request.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        assert(messages.last?["content"] == prompt)
        assert(body["model"] as? String == "test-model")
        assert(body["stream"] as? Bool == false)

        let thoughtTree = MindNode(title: "设计一个会员方案", children: [
            MindNode(title: "目标", children: [MindNode(title: "提高续费率")]),
            MindNode(title: "限制", children: [MindNode(title: "不能增加客服人力")])
        ])
        let optimization = try client.optimizationRequest(
            configuration: configuration,
            key: "fixture-token",
            root: thoughtTree
        )
        let optimizationBody = try JSONSerialization.jsonObject(with: optimization.httpBody!) as! [String: Any]
        let optimizationMessages = optimizationBody["messages"] as! [[String: String]]
        let optimizationInstruction = optimizationMessages[0]["content"]!
        assert(optimizationInstruction.contains("工具无关"))
        assert(optimizationInstruction.contains("思考逻辑"))
        assert(optimizationInstruction.contains("待补充"))
        assert(optimizationInstruction.contains("验收标准"))
        assert(optimizationInstruction.contains("不得编造"))
        assert(!optimizationInstruction.contains("目标工具"))
        let optimizationSource = optimizationMessages[1]["content"]!
        assert(optimizationSource.contains("设计一个会员方案"))
        assert(optimizationSource.contains("提高续费率"))
        assert(optimizationSource.contains("不能增加客服人力"))
        print("PASS: optimization is tool-agnostic, preserves thought structure, exposes critical gaps, and defines quality checks")

        let response = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"{\"title\":\"Plan\",\"children\":[{\"title\":\"First\",\"children\":[{\"title\":\"Task\"}]}]}"}}]}"#.utf8)
        let root = try client.parseGeneration(response)
        assert(root.title == "Plan" && root.children.first?.children.first?.title == "Task")
        assert(root.id != root.children.first?.id)
        print("PASS: OpenAI-compatible request, full long prompt, recursive editable tree")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let settingsURL = directory.appendingPathComponent("ai.json")
        let credentials = AICredentials(service: "design.wisepulse.strata.test." + UUID().uuidString)
        defer {
            try? credentials.save("", account: configuration.baseURL)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AISettingsStorage(url: settingsURL, credentials: credentials)
        try settings.save(configuration, key: "fixture-token")
        let reopened = AISettingsStorage(url: settingsURL, credentials: credentials)
        let loaded = try reopened.load()
        let loadedKey = try reopened.key(for: configuration)
        let otherKey = try reopened.key(for: AIConfiguration(baseURL: "https://other.example/v1"))
        assert(loaded == configuration)
        assert(loadedKey == "fixture-token")
        assert(otherKey == "")
        let persisted = try String(contentsOf: settingsURL, encoding: .utf8)
        assert(!persisted.contains("fixture-token"))
        try settings.save(proxied, key: "fixture-token")
        let savedProxy = try reopened.load()
        let preservedKey = try reopened.key(for: savedProxy)
        assert(savedProxy == proxied && preservedKey == "fixture-token")
        print("PASS: settings reload, Keychain round trip, endpoint credential isolation, no plaintext key in settings")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FixtureProtocol.self]
        let network = AIClient(session: URLSession(configuration: sessionConfiguration))
        do {
            _ = try await network.models(configuration: AIConfiguration(baseURL: "https://example.com/tls-failure"), key: "")
            assertionFailure("TLS failure swallowed")
        } catch {
            assert(error.localizedDescription.contains("TLS") && error.localizedDescription.contains("代理"))
        }
        print("PASS: TLS failure gives actionable feedback")
        let models = try await network.models(configuration: configuration, key: "fixture-token")
        assert(models == ["a", "b"])
        let workflow = AIWorkflow(storage: settings, client: network)
        workflow.prompt = "Organize the requirements"
        let store = MindMapStore()
        let succeeded = await workflow.generate(into: store)
        assert(succeeded && store.root.title == "Generated")
        assert(store.rename(store.root.children[0].id, to: "Changed"))
        assert(store.selectedID == store.root.id && !workflow.isGenerating)
        let beforeFailure = store.root
        workflow.configuration.baseURL = "https://example.com/unauthorized"
        let failed = await workflow.generate(into: store)
        assert(!failed && store.root == beforeFailure && !workflow.error.isEmpty)
        print("PASS: model list, async generation into editable canvas model, failure preserves document (HTTP fixtures)")
        workflow.configuration.baseURL = "https://example.com/slow"
        let task = Task { await workflow.generate(into: store) }
        while !workflow.isGenerating { await Task.yield() }
        task.cancel()
        let cancelled = await task.value
        assert(!cancelled && store.root == beforeFailure && !workflow.isGenerating)
        for json in [
            #"{"choices":[]}"#,
            #"{"choices":[{"finish_reason":"length","message":{"content":"{}"}}]}"#,
            #"{"choices":[{"message":{"content":"not JSON"}}]}"#,
            #"{"choices":[{"message":{"content":"{\"title\":\"\"}"}}]}"#,
            #"{"choices":[{"message":{"content":"{\"title\":\"Root\",\"children\":{}}"}}]}"#
        ] {
            do { _ = try client.parseGeneration(Data(json.utf8)); assertionFailure("Invalid output accepted") }
            catch {}
        }
        for address in ["file:///tmp/test", "http://remote.example/v1", "https://example.com/v1?key=fixture", "https://example.com/v1/chat/completions"] {
            do { _ = try AIConfiguration(baseURL: address).endpoint("models"); assertionFailure("Unsafe URL accepted") }
            catch {}
        }
        print("PASS: cancellation preserves tree, invalid/truncated output and unsafe API URLs rejected")
    }
}