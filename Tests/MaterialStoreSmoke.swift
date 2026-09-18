import Foundation

@main
struct MaterialStoreSmoke {
    @MainActor
    static func main() {
        do {
            try run()
            print("PASS: material CRUD, exact multiline content, localized search, atomic failure safety, and corrupt-file recovery")
        } catch {
            fatalError("Material store smoke failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func run() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("strata-material-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("material-library.json")
        let store = MaterialLibraryStore(url: url)
        check(store.materials.isEmpty, "a missing file should load as an empty library")
        check(store.loadError.isEmpty, "a missing file should not report an error")

        let exactContent = "  第一行\n第二行\n\n末尾空格  "
        let first = try store.save(title: "中文标题", content: exactContent)
        check(store.materials == [first], "new materials should be stored")
        check(first.content == exactContent, "content whitespace and newlines must be exact")

        let second = try store.save(title: "Case Card", content: "Mixed body 内容")
        check(store.materials.map(\.id) == [second.id, first.id], "new materials should be prepended")
        check(store.matching("case").map(\.id) == [second.id], "search should be case-insensitive")
        check(store.matching("内容").map(\.id) == [second.id], "search should support localized content")
        check(store.matching("第一行").map(\.id) == [first.id], "search should match multiline content")
        check(store.matching("").map(\.id) == [second.id, first.id], "empty search should preserve order")

        let edited = try store.save(id: first.id, title: "编辑后", content: exactContent)
        check(edited.id == first.id, "editing should preserve the material ID")
        check(store.materials.map(\.id) == [second.id, first.id], "editing should preserve order")
        check(store.materials.last?.content == exactContent, "editing should preserve exact content")

        try store.delete(second.id)
        check(store.materials.map(\.id) == [first.id], "deletion should remove the requested material")
        check(store.matching("编辑").count == 1, "CRUD should remain usable after searching")

        try expectError(MaterialLibraryError.invalidTitle) {
            _ = try store.save(title: " \n\t ", content: "body")
        }
        try expectError(MaterialLibraryError.invalidContent) {
            _ = try store.save(title: "title", content: " \n\t ")
        }
        try expectError(MaterialLibraryError.materialNotFound) {
            _ = try store.save(id: UUID(), title: "missing", content: "body")
        }
        try expectError(MaterialLibraryError.materialNotFound) {
            try store.delete(UUID())
        }
        check(store.materials.count == 1, "rejected CRUD operations must not change memory")

        let roundTrip = MaterialLibraryStore(url: url)
        check(roundTrip.loadError.isEmpty, "a saved file should reload without an error")
        check(roundTrip.materials == store.materials, "disk round trip should preserve materials")

        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        let failedWriteURL = blocker.appendingPathComponent("library.json")
        let failedWriteStore = MaterialLibraryStore(url: failedWriteURL)
        let beforeFailedWrite = failedWriteStore.materials
        try expectError(MaterialLibraryError.writeFailed) {
            _ = try failedWriteStore.save(title: "不会写入", content: "body")
        }
        check(failedWriteStore.materials == beforeFailedWrite, "failed writes must not publish memory")
        check(!FileManager.default.fileExists(atPath: failedWriteURL.path), "failed writes must not create a partial target")

        let corruptURL = root.appendingPathComponent("corrupt.json")
        let corruptBytes = Data("{ definitely not valid json".utf8)
        try corruptBytes.write(to: corruptURL)
        let corruptStore = MaterialLibraryStore(url: corruptURL)
        check(!corruptStore.loadError.isEmpty, "malformed files should surface a localized load error")
        check(corruptStore.materials.isEmpty, "malformed initial loads should not invent materials")
        try expectError(MaterialLibraryError.writesBlocked) {
            _ = try corruptStore.save(title: "禁止覆盖", content: "body")
        }
        let preservedCorruptBytes = try Data(contentsOf: corruptURL)
        check(preservedCorruptBytes == corruptBytes, "corrupt files must never be overwritten silently")

        let recovered = LibraryMaterial(title: "恢复", content: "恢复内容")
        try JSONEncoder().encode([recovered]).write(to: corruptURL, options: [.atomic])
        corruptStore.reload()
        check(corruptStore.loadError.isEmpty, "successful reload should clear the load error")
        check(corruptStore.materials == [recovered], "successful reload should recover valid disk data")
        let addedAfterRecovery = try corruptStore.save(title: "恢复后新增", content: "可写")
        check(corruptStore.materials.first == addedAfterRecovery, "writes should resume after successful reload")
    }

    @MainActor
    private static func expectError(
        _ expected: MaterialLibraryError,
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
            fatalError("Expected error \(expected), but operation succeeded")
        } catch let error as MaterialLibraryError {
            check(error == expected, "expected \(expected), got \(error)")
        }
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
