import Foundation

@main
struct AIPersistence {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { fatalError("Expected mode, directory, test service") }
        let storage = AISettingsStorage(
            url: URL(fileURLWithPath: arguments[2]).appendingPathComponent("settings.json"),
            credentials: AICredentials(service: arguments[3])
        )
        let configuration = AIConfiguration(baseURL: "https://fixture.example/v1", model: "fixture-model")
        switch arguments[1] {
        case "write":
            try storage.save(configuration, key: "persistence-test-only")
            print("PASS: isolated fixture configuration written")
        case "read":
            let restored = try storage.load()
            let key = try storage.key(for: restored)
            guard restored == configuration, key == "persistence-test-only" else { fatalError("Persistence mismatch") }
            print("PASS: configuration and Keychain survived process restart and executable rebuild")
        case "cleanup":
            try storage.credentials.save("", account: configuration.baseURL)
            try FileManager.default.removeItem(at: URL(fileURLWithPath: arguments[2]))
        default: fatalError("Unknown mode")
        }
    }
}