import AppKit
import SwiftUI

@main
struct MaterialCanvasSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MaterialLibraryStore(url: directory.appendingPathComponent("materials.json"))
        let body = "  第一段正文\n\n第二段正文\n末行  "
        let material = try library.save(title: "只在素材库显示的标题", content: body)
        let existing = MindNode(title: "Existing child")
        let branch = MindNode(title: "Selected", children: [existing], isCollapsed: true)
        let store = MindMapStore(root: MindNode(title: "Root", children: [branch]))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = CanvasScrollView(frame: window.contentView!.bounds)
        let canvas = MindCanvas(store: store)
        window.contentView = scroll; scroll.documentView = canvas; canvas.refresh()
        for scale: CGFloat in [0.25, 1, 3] {
            for orientation in [StrataLayoutOrientation.horizontal, .vertical] {
                canvas.orientation = orientation; canvas.refresh()
                scroll.zoom(to: scale, at: CGPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY))
                store.select(branch.id)
                window.makeFirstResponder(nil)
                let inserted = MaterialInsertion.insert(material, into: store)!
                canvas.refresh()
                assert(store.node(inserted)!.title == body, "Material insertion must copy only the exact full body")
                assert(store.node(branch.id)!.children.last!.id == inserted)
                assert(!store.node(branch.id)!.isCollapsed)
                assert(store.selectedID == inserted && window.firstResponder === canvas && canvas.editor == nil)
                assert(scroll.magnification == scale)
                let rect = canvas.card(inserted)!
                assert(abs(rect.midX - scroll.contentView.bounds.midX) < 2 && abs(rect.midY - scroll.contentView.bounds.midY) < 2)
                let export = store.textExport()
                assert(export.contains("第一段正文\n第二段正文\n末行") && !export.contains(material.title))
                let document = directory.appendingPathComponent("map.json")
                try store.save(document)
                let reopened = MindMapStore(); try reopened.open(document)
                assert(reopened.node(inserted)?.title == body)
            }
        }
        let original = store.root
        store.selectedID = nil
        assert(MaterialInsertion.insert(material, into: store) == nil && store.root == original)
        store.selectedID = UUID()
        assert(MaterialInsertion.insert(material, into: store) == nil && store.root == original)
        try library.save(id: material.id, title: "Updated", content: "Updated text")
        assert(store.root == original, "Editing a material must not mutate inserted copies")
        try library.delete(material.id)
        assert(store.root == original, "Deleting a material must not remove inserted nodes")
        print("PASS: exact content-only insertion, append order, collapsed parent, focus ownership, centered at fixed zoom, JSON/export, nil selection, copy independence")

        for scale: CGFloat in [0.25, 1, 3] {
            scroll.zoom(to: scale, at: CGPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY))
            canvas.centerNode(branch.id)
            for width: CGFloat in [667, 1000] {
                scroll.setFrameSize(CGSize(width: width, height: 700))
                scroll.layoutSubtreeIfNeeded()
                let rect = canvas.card(branch.id)!
                assert(abs(rect.midX - scroll.contentView.bounds.midX) < 2 && abs(rect.midY - scroll.contentView.bounds.midY) < 2, "Opening and closing the sidebar must preserve the canvas center")
                assert(scroll.magnification == scale)
            }
        }
        print("PASS: sidebar width changes preserve the canvas center and magnification")

        let card = NSHostingView(rootView: MaterialCard(material: material, canInsert: true, insert: {}, edit: {}, delete: {}).frame(width: 144))
        let size = card.fittingSize
        assert(abs(size.width - 144) < 1 && abs(size.height - 144) < 1, "Material cards must stay 1:1 regardless of text length")
        let longMaterial = LibraryMaterial(title: String(repeating: "很长的标题", count: 50), content: String(repeating: "很长的正文\n", count: 500))
        let longCard = NSHostingView(rootView: MaterialCard(material: longMaterial, canInsert: false, insert: {}, edit: {}, delete: {}).frame(width: 144))
        assert(abs(longCard.fittingSize.height - 144) < 1, "Long text must not stretch the square card")
        let sheet = NSHostingView(rootView: MaterialEditorSheet(library: library, draft: MaterialDraft(material: material), saved: {}))
        assert(sheet.fittingSize.width >= 520 && sheet.fittingSize.height >= 460)
        let panel = NSHostingView(rootView: MaterialLibraryPanel(library: library, store: store, close: {}).frame(height: 620))
        assert(abs(panel.fittingSize.width - 332) < 1)
        print("PASS: native SwiftUI layout for square cards, long-text clipping, editor sheet and sidebar width")
    }
}
