import Foundation
import SwiftUI

struct LibraryMaterial: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String

    init(id: UUID = UUID(), title: String, content: String) {
        self.id = id
        self.title = title
        self.content = content
    }
}

enum MaterialLibraryError: LocalizedError, Equatable {
    case invalidTitle
    case invalidContent
    case materialNotFound
    case writesBlocked
    case loadFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidTitle:
            return "标题不能为空。"
        case .invalidContent:
            return "内容不能为空。"
        case .materialNotFound:
            return "未找到指定素材。"
        case .writesBlocked:
            return "素材库当前无法写入，请先重新加载。"
        case .loadFailed:
            return "素材库读取失败，文件可能已损坏或不可访问。"
        case .writeFailed:
            return "素材库保存失败，原有内容未改变。"
        }
    }
}

@MainActor
final class MaterialLibraryStore: ObservableObject {
    @Published private(set) var materials: [LibraryMaterial] = []
    @Published private(set) var loadError = ""

    private let url: URL
    private var writesBlocked = false

    init(url: URL) {
        self.url = url
        reload()
    }

    static var defaultURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        return applicationSupport
            .appendingPathComponent("Strata", isDirectory: true)
            .appendingPathComponent("material-library.json", isDirectory: false)
    }

    func reload() {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                materials = []
                loadError = ""
                writesBlocked = false
                return
            }

            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([LibraryMaterial].self, from: data)
            materials = decoded
            loadError = ""
            writesBlocked = false
        } catch {
            // Keep the last known in-memory state and refuse writes until a
            // successful reload, so a bad file can never be overwritten by
            // accident.
            loadError = MaterialLibraryError.loadFailed.localizedDescription
            writesBlocked = true
        }
    }

    func matching(_ query: String) -> [LibraryMaterial] {
        guard !query.isEmpty else { return materials }
        return materials.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.content.localizedCaseInsensitiveContains(query)
        }
    }

    @discardableResult
    func save(id: UUID? = nil, title: String, content: String) throws -> LibraryMaterial {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MaterialLibraryError.invalidTitle
        }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MaterialLibraryError.invalidContent
        }
        guard !writesBlocked else {
            throw MaterialLibraryError.writesBlocked
        }

        var candidate = materials
        let material: LibraryMaterial

        if let id {
            guard let index = candidate.firstIndex(where: { $0.id == id }) else {
                throw MaterialLibraryError.materialNotFound
            }
            material = LibraryMaterial(id: id, title: title, content: content)
            candidate[index] = material
        } else {
            material = LibraryMaterial(title: title, content: content)
            candidate.insert(material, at: 0)
        }

        try persist(candidate)
        materials = candidate
        loadError = ""
        return material
    }

    func delete(_ id: UUID) throws {
        guard !writesBlocked else {
            throw MaterialLibraryError.writesBlocked
        }
        guard let index = materials.firstIndex(where: { $0.id == id }) else {
            throw MaterialLibraryError.materialNotFound
        }

        var candidate = materials
        candidate.remove(at: index)
        try persist(candidate)
        materials = candidate
        loadError = ""
    }

    private func persist(_ candidate: [LibraryMaterial]) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(candidate)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            throw MaterialLibraryError.writeFailed
        }
    }
}
