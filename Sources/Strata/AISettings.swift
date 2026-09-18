import Foundation
import Security

struct AICredentials {
    var service = "design.wisepulse.strata.ai"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(account: String) throws -> String {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AIError.message("无法读取钥匙串（\(status)）。请授权 Strata 访问保存的 API 密钥。")
        }
        return key
    }

    func save(_ key: String, account: String) throws {
        let query = query(account)
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AIError.message("无法删除钥匙串中的密钥（\(status)）。")
            }
            return
        }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIError.message("密钥保存失败（\(status)），请检查钥匙串是否已解锁。") }
        guard try read(account: account) == key else { throw AIError.message("密钥保存校验失败。") }
    }
}

struct AISettingsStorage {
    var url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Strata/ai-settings.json")
    var credentials = AICredentials()

    func load() throws -> AIConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return AIConfiguration() }
        return try JSONDecoder().decode(AIConfiguration.self, from: Data(contentsOf: url))
    }

    func key(for configuration: AIConfiguration) throws -> String {
        _ = try configuration.endpoint("models")
        return try credentials.read(account: configuration.baseURL)
    }

    func save(_ configuration: AIConfiguration, key: String) throws {
        _ = try configuration.endpoint("models")
        _ = try AIClient.sessionConfiguration(for: configuration)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(configuration)
        try credentials.save(key, account: configuration.baseURL)
        try data.write(to: url, options: .atomic)
    }
}