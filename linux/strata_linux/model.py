"""Pure-Python tree model shared by Linux front ends."""
from __future__ import annotations

import copy
import json
import os
import tempfile
import uuid
from pathlib import Path
from typing import Any, Iterable


def node(title: str = "主题", children: list[dict] | None = None) -> dict:
    return {"id": str(uuid.uuid4()), "title": str(title),
            "children": copy.deepcopy(children or []), "isCollapsed": False}


def validate_tree(value: Any, ai: bool = False) -> dict:
    max_count, max_depth, max_title = ((500, 12, 2000) if ai else (10000, 100, 10000))
    seen: set[str] = set()
    count = 0

    def visit(item: Any, depth: int) -> dict:
        nonlocal count
        if not isinstance(item, dict): raise ValueError("node must be an object")
        if depth > max_depth: raise ValueError("tree depth limit exceeded")
        ident, title, children = item.get("id"), item.get("title"), item.get("children")
        if not isinstance(ident, str) or not ident: raise ValueError("invalid node id")
        if ident in seen: raise ValueError("duplicate node id")
        if not isinstance(title, str) or len(title) > max_title: raise ValueError("invalid title")
        if not isinstance(children, list): raise ValueError("children must be a list")
        seen.add(ident); count += 1
        if count > max_count: raise ValueError("node count limit exceeded")
        return {"id": ident, "title": title,
                "children": [visit(child, depth + 1) for child in children],
                "isCollapsed": item.get("isCollapsed", False) if isinstance(item.get("isCollapsed", False), bool) else (_ for _ in ()).throw(ValueError("invalid collapse flag"))}

    return visit(value, 0)


class Store:
    def __init__(self, root: dict | None = None):
        self.root = validate_tree(root if root is not None else node())
        self.selected: str | None = self.root["id"]
        self.selection: set[str] = {self.root["id"]}
        self.undo_stack: list[dict] = []
        self.redo_stack: list[dict] = []
        self.revision = 0

    @property
    def is_empty(self) -> bool:
        return self.root["title"] == "主题" and not self.root["children"]

    @property
    def selected_id(self) -> str | None:
        """Compatibility name used by the Qt window and smoke harness."""
        return self.selected

    def node(self, ident: str | None) -> dict | None:
        if ident is None: return None
        def walk(n):
            if n["id"] == ident: return n
            for child in n["children"]:
                found = walk(child)
                if found: return found
            return None
        return walk(self.root)

    def parent(self, ident: str | None) -> dict | None:
        if ident is None: return None
        def walk(n):
            for child in n["children"]:
                if child["id"] == ident: return n
                found = walk(child)
                if found: return found
            return None
        return walk(self.root)

    def _record(self):
        self.undo_stack.append(copy.deepcopy(self.root))
        if len(self.undo_stack) > 100: self.undo_stack.pop(0)
        self.redo_stack.clear(); self.revision += 1

    def _finish(self, selection: str | None = None):
        self.selected = selection if self.node(selection) else self.root["id"]
        self.selection = {x for x in self.selection if self.node(x)} or {self.selected}

    def _mutate(self, fn) -> bool:
        candidate = copy.deepcopy(self.root)
        if not fn(candidate): return False
        self._record(); self.root = candidate; return True

    def add_child(self, parent_id: str, title: str = "新节点") -> str:
        ident = str(uuid.uuid4()); child = {"id": ident, "title": title, "children": [], "isCollapsed": False}
        def f(root):
            p = self._find(root, parent_id)
            if not p: return False
            p["children"].append(child); return True
        if not self._mutate(f): raise ValueError("parent not found")
        self.select(ident); self.reveal(ident); return ident

    def add_sibling(self, ident: str) -> str:
        p = self.parent(ident)
        return self.add_child(p["id"], "新节点") if p else self.add_child(ident, "新节点")

    def rename(self, ident: str, title: str) -> bool:
        def f(root):
            n = self._find(root, ident)
            if not n or not isinstance(title, str) or not title.strip(): return False
            n["title"] = title.strip(); return True
        return self._mutate(f)

    def delete(self, ids: Iterable[str]) -> bool:
        targets = set(ids) - {self.root["id"]}
        if not targets: return False
        old = self.root
        def f(root):
            changed = False
            def prune(n):
                nonlocal changed
                kept = []
                for c in n["children"]:
                    if c["id"] in targets: changed = True
                    else: prune(c); kept.append(c)
                n["children"] = kept
            prune(root); return changed
        if not self._mutate(f): return False
        surviving = self.selected if self.node(self.selected) else None
        if surviving is None:
            n = self.root
            while n["children"]: n = n["children"][-1]
            surviving = n["id"]
        self._finish(surviving); return True

    def move(self, source: str, target: str, placement: str) -> bool:
        if placement not in {"before", "inside", "after"} or source == self.root["id"] or source == target: return False
        moving = self.node(source)
        if not moving or not self.node(target) or self.node(target) is moving: return False
        def contains(n, ident): return n["id"] == ident or any(contains(c, ident) for c in n["children"])
        if contains(moving, target): return False
        source_parent = self.parent(source)
        if placement == "inside": dest_id, index = target, None
        else:
            dest = self.parent(target)
            if not dest: return False
            dest_id = dest["id"]; index = next(i for i,c in enumerate(dest["children"]) if c["id"] == target) + (placement == "after")
        def f(root):
            srcp = self._find(root, source_parent["id"])
            item = next((c for c in srcp["children"] if c["id"] == source), None)
            if item is None: return False
            srcp["children"].remove(item)
            dp = self._find(root, dest_id)
            if not dp: return False
            if index is None: dp["children"].append(item)
            else:
                actual = index - (1 if srcp["id"] == dp["id"] and source_parent["id"] == dest_id and index > next((i for i,c in enumerate(srcp["children"]) if c["id"] == source), -1) else 0)
                dp["children"].insert(max(0, min(actual, len(dp["children"]))), item)
            return True
        ok = self._mutate(f)
        if ok: self.select(source); self.reveal(source)
        return ok

    def toggle(self, ident: str) -> bool:
        return self._mutate(lambda r: self._toggle(r, ident))

    def _toggle(self, root, ident):
        n = self._find(root, ident)
        if not n or not n["children"]: return False
        n["isCollapsed"] = not n["isCollapsed"]; return True

    def select(self, ident: str, additive: bool = False):
        if not self.node(ident): return
        if not additive: self.selection.clear()
        self.selection.add(ident); self.selected = ident

    def reveal(self, ident: str):
        changed = False
        current = self.node(ident)
        if current and current["isCollapsed"]:
            current["isCollapsed"] = False
            changed = True
        p = self.parent(ident)
        while p:
            if p["isCollapsed"]:
                p["isCollapsed"] = False
                changed = True
            p = self.parent(p["id"])
        if changed:
            self.revision += 1

    def navigate(self, direction: str) -> str:
        current = self.selected or self.root["id"]; n = self.node(current)
        dest = current
        if direction == "parent": dest = self.parent(current)["id"] if self.parent(current) else current
        elif direction == "child": dest = n["children"][0]["id"] if n and n["children"] else current
        elif direction in {"previous", "next"}:
            cursor = current
            while (p := self.parent(cursor)):
                i = next(i for i,c in enumerate(p["children"]) if c["id"] == cursor)
                j = i + (-1 if direction == "previous" else 1)
                if 0 <= j < len(p["children"]): dest = p["children"][j]["id"]; break
                cursor = p["id"]
        self.reveal(dest); self.select(dest); return dest

    def replace(self, root: dict) -> None:
        checked = validate_tree(root)
        self._record(); self.root = checked; self.selected = checked["id"]; self.selection = {checked["id"]}

    def undo(self) -> bool:
        if not self.undo_stack: return False
        self.redo_stack.append(copy.deepcopy(self.root)); self.root = self.undo_stack.pop(); self.revision += 1; self._finish(); return True

    def redo(self) -> bool:
        if not self.redo_stack: return False
        self.undo_stack.append(copy.deepcopy(self.root)); self.root = self.redo_stack.pop(); self.revision += 1; self._finish(); return True

    def save(self, path):
        data = json.dumps(self.root, ensure_ascii=False, indent=2, sort_keys=True).encode()
        directory = str(Path(path).parent); fd, tmp = tempfile.mkstemp(prefix=".strata-", dir=directory)
        try:
            with os.fdopen(fd, "wb") as f: f.write(data); f.flush(); os.fsync(f.fileno())
            os.replace(tmp, path)
        except Exception:
            try: os.unlink(tmp)
            except OSError: pass
            raise

    def open(self, path):
        with open(path, encoding="utf-8") as f: checked = validate_tree(json.load(f))
        self._record(); self.root = checked; self.selected = checked["id"]; self.selection = {checked["id"]}

    def text_export(self) -> str:
        lines = []
        def visit(n, depth):
            title = n["title"].replace("\n", " ")
            if n["children"]: lines.append("#" * depth + " " + title)
            else: lines.extend(n["title"].splitlines() or [""])
            for c in n["children"]: visit(c, depth + 1)
        visit(self.root, 1); return "\n".join(lines)

    @staticmethod
    def _find(root, ident):
        if root["id"] == ident: return root
        for c in root["children"]:
            found = Store._find(c, ident)
            if found: return found
        return None
