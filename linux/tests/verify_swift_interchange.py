#!/usr/bin/env python3
"""macOS-only interoperability test using the real Swift MindNode declaration.

Run from repository root with PYTHONPATH=linux; outputs exist only in a temporary
directory. It does not compile AppKit or alter any production source file.
"""
from pathlib import Path
import json
import subprocess
import tempfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from strata_linux.model import Store

source = Path(__file__).resolve().parents[2] / "Sources/Strata/MindMap.swift"
text = source.read_text()
declaration = text[text.index("struct MindNode:"):text.index("enum DropPlacement:")]

with tempfile.TemporaryDirectory(prefix="strata-interop-") as raw:
    directory = Path(raw)
    program = directory / "interop.swift"
    program.write_text("import Foundation\n" + declaration + '''
let path = URL(fileURLWithPath: CommandLine.arguments[2])
if CommandLine.arguments[1] == "write" {
    let root = MindNode(title: "跨平台主题", children: [
        MindNode(title: "分支", children: [MindNode(title: "中文\\n第二行")], isCollapsed: true)
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(root).write(to: path)
} else {
    let root = try JSONDecoder().decode(MindNode.self, from: Data(contentsOf: path))
    precondition(root.title == "Linux 修改")
    precondition(root.children[0].isCollapsed)
    precondition(root.children[0].children[0].title == "中文\\n第二行")
    print("SWIFT_DECODE_LINUX_OK")
}
''')
    binary = directory / "interop"
    subprocess.run(["swiftc", str(program), "-o", str(binary)], check=True)
    document = directory / "document.json"
    subprocess.run([str(binary), "write", str(document)], check=True)
    original = json.loads(document.read_text())
    store = Store()
    store.open(document)
    assert store.root == original
    assert store.rename(store.root["id"], "Linux 修改")
    store.save(document)
    changed = json.loads(document.read_text())
    assert changed["id"] == original["id"]
    assert changed["children"] == original["children"]
    subprocess.run([str(binary), "read", str(document)], check=True)
    print("SWIFT_LINUX_JSON_ROUNDTRIP_OK")
