import XCTest
@testable import Strata

@MainActor
final class StrataTests: XCTestCase {
    func testCreateChildAndSiblingSelectsEachNewNode() {
        let store = MindMapStore()
        let rootID = store.root.id

        let childID = tryUnwrap(store.createChild(of: rootID))
        let siblingID = tryUnwrap(store.createSibling(after: childID))

        XCTAssertEqual(store.root.children.map(\.id), [childID, siblingID])
        XCTAssertEqual(store.selectedID, siblingID)
    }

    func testRenameUsesExplicitIDRatherThanCurrentSelection() {
        let first = MindNode(title: "First")
        let second = MindNode(title: "Second")
        let store = MindMapStore(root: MindNode(title: "Root", children: [first, second]))
        store.selectedID = second.id

        XCTAssertTrue(store.rename(first.id, to: "Renamed"))
        XCTAssertFalse(store.rename(first.id, to: "   \n"))

        XCTAssertEqual(store.node(first.id)?.title, "Renamed")
        XCTAssertEqual(store.node(second.id)?.title, "Second")
    }

    func testDeleteOnlySubtreeFallsBackToRoot() {
        let grandchild = MindNode(title: "Grandchild")
        let child = MindNode(title: "Child", children: [grandchild])
        let root = MindNode(title: "Root", children: [child])
        let store = MindMapStore(root: root)
        store.select(grandchild.id)

        XCTAssertEqual(store.delete(child.id), root.id)
        XCTAssertTrue(store.root.children.isEmpty)
        XCTAssertNil(store.node(grandchild.id))
        XCTAssertEqual(store.selectedID, root.id)
        XCTAssertNil(store.delete(root.id))
    }

    func testResetCreatesFreshSelectedDocument() {
        let store = MindMapStore(root: MindNode(title: "Old", children: [MindNode(title: "Work")]))
        let previousRootID = store.root.id

        XCTAssertFalse(store.isEmptyDocument)
        store.reset()

        XCTAssertNotEqual(store.root.id, previousRootID)
        XCTAssertEqual(store.root.title, "主题")
        XCTAssertTrue(store.root.children.isEmpty)
        XCTAssertEqual(store.selectedID, store.root.id)
        XCTAssertTrue(store.isEmptyDocument)
        XCTAssertEqual(store.focusRequest?.nodeID, store.root.id)
        XCTAssertEqual(store.focusRequest?.activateCanvas, false)
    }

    func testMoveBeforeAndAfterPreservesSiblingOrder() {
        let a = MindNode(title: "A")
        let b = MindNode(title: "B")
        let c = MindNode(title: "C")
        let root = MindNode(title: "Root", children: [a, b, c])
        let store = MindMapStore(root: root)

        XCTAssertTrue(store.move(c.id, relativeTo: a.id, placement: .before))
        XCTAssertEqual(store.root.children.map(\.title), ["C", "A", "B"])

        XCTAssertTrue(store.move(c.id, relativeTo: b.id, placement: .after))
        XCTAssertEqual(store.root.children.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(store.selectedID, c.id)
    }

    func testMoveInsideReparentsAndRejectsCyclesWithoutMutation() {
        let b = MindNode(title: "B")
        let a = MindNode(title: "A", children: [b])
        let c = MindNode(title: "C")
        let root = MindNode(title: "Root", children: [a, c])
        let store = MindMapStore(root: root)

        XCTAssertTrue(store.move(c.id, relativeTo: b.id, placement: .inside))
        XCTAssertEqual(store.root.children.map(\.title), ["A"])
        XCTAssertEqual(store.node(b.id)?.children.map(\.title), ["C"])

        let beforeInvalidMove = store.root
        XCTAssertFalse(store.move(a.id, relativeTo: c.id, placement: .inside))
        XCTAssertFalse(store.move(store.root.id, relativeTo: b.id, placement: .inside))
        XCTAssertEqual(store.root, beforeInvalidMove)
    }

    private func tryUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) -> T {
        guard let value else {
            XCTFail("Expected a value", file: file, line: line)
            fatalError("Test cannot continue after missing value")
        }
        return value
    }
}
