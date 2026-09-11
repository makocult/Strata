import XCTest
@testable import Strata

final class StrataTests: XCTestCase {
    @MainActor
    func testNodesAtDepthPreservesAncestorPath() {
        let store = MindMapStore()
        store.root = MindNode(title: "主题", children: [
            MindNode(title: "分支 A", children: [MindNode(title: "A-第二层")]),
            MindNode(title: "分支 B", children: [MindNode(title: "B-第二层")])
        ])

        let result = store.nodes(at: 2)

        XCTAssertEqual(result.map { $0.node.title }, ["A-第二层", "B-第二层"])
        XCTAssertEqual(result.map { $0.path.map(\.title) }, [["主题", "分支 A", "A-第二层"], ["主题", "分支 B", "B-第二层"]])
    }
}
