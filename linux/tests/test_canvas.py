import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import pytest
from PySide6.QtCore import Qt, QPoint
from PySide6.QtGui import QWheelEvent
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication

from strata_linux.canvas import Canvas


@pytest.fixture(scope="session")
def app():
    return QApplication.instance() or QApplication([])


class Store:
    def __init__(self):
        self.root = {"id": "root", "title": "主题", "children": [], "isCollapsed": False}
        self.selected = "root"
        self.selection = {"root"}
        self.revision = 0

    def node(self, ident):
        def walk(n):
            if n["id"] == ident: return n
            for c in n["children"]:
                found = walk(c)
                if found: return found
        return walk(self.root)

    def parent(self, ident):
        def walk(n):
            for c in n["children"]:
                if c["id"] == ident: return n
                found = walk(c)
                if found: return found
        return walk(self.root)

    def select(self, ident, additive=False):
        if not additive: self.selection.clear()
        self.selection.add(ident); self.selected = ident

    def add_child(self, parent_id, title="新节点"):
        n = {"id": f"n{self.revision + 1}", "title": title, "children": [], "isCollapsed": False}
        self.revision += 1; self.node(parent_id)["children"].append(n); return n["id"]

    def add_sibling(self, ident):
        p = self.parent(ident)
        return self.add_child(p["id"], "新节点") if p else self.add_child(ident, "新节点")

    def rename(self, ident, title): self.node(ident)["title"] = title; self.revision += 1; return True
    def delete(self, ids):
        for ident in list(ids):
            p = self.parent(ident)
            if p: p["children"] = [x for x in p["children"] if x["id"] != ident]
        self.revision += 1; return True
    def toggle(self, ident): self.node(ident)["isCollapsed"] = not self.node(ident)["isCollapsed"]; self.revision += 1; return True
    def reveal(self, ident): return None
    def navigate(self, direction): return self.selected


def make_store():
    s = Store(); a = s.add_child("root", "Alpha"); s.add_child(a, "Alpha child"); s.add_child("root", "Beta"); return s


def test_canvas_builds_and_refresh_preserves_zoom(app):
    s = make_store(); c = Canvas(s); c.resize(800, 600); c.show(); c.refresh()
    c.set_zoom(1.7); c.refresh(focus="root")
    assert c.zoom == pytest.approx(1.7)
    assert set(c.items) >= {"root", "n1", "n2", "n3"}


def test_click_selects_and_ctrl_click_adds(app):
    s = make_store(); c = Canvas(s); c.resize(800, 600); c.show(); c.refresh()
    c.items["n1"].setFocus()
    pos = c.mapFromScene(c.items["n1"].sceneBoundingRect().center())
    QTest.mouseClick(c.viewport(), Qt.LeftButton, pos=pos)
    assert s.selected == "n1"
    pos2 = c.mapFromScene(c.items["n2"].sceneBoundingRect().center())
    QTest.mouseClick(c.viewport(), Qt.LeftButton, Qt.ControlModifier, pos2)
    assert s.selection == {"n1", "n2"}


def test_edit_commit_and_escape(app):
    s = make_store(); c = Canvas(s); c.resize(800, 600); c.show(); c.refresh()
    c.begin_edit("n1", "Changed"); assert c.editor is not None
    c.finish_edit(); assert s.node("n1")["title"] == "Changed"
    c.begin_edit("n1", "Temporary"); c.finish_edit(False)
    assert s.node("n1")["title"] == "Changed"


def test_orientation_and_collapse_emit_changed(app):
    s = make_store(); c = Canvas(s); c.resize(800, 600); c.show(); c.refresh(); seen=[]
    c.changed.connect(lambda: seen.append(True))
    c.set_orientation("vertical"); assert c.orientation == "vertical"
    c.begin_edit("root"); c.finish_edit(); assert seen
    before = len(c.items); c.toggle("n1"); assert len(c.items) < before


def test_keyboard_enter_tab_delete(app):
    s = make_store(); c = Canvas(s); c.resize(800, 600); c.show(); c.refresh(); c.setFocus()
    c.begin_edit("n1", "A"); c.editor.keyPressEvent(__import__("PySide6.QtGui", fromlist=["QKeyEvent"]).QKeyEvent(__import__("PySide6.QtCore", fromlist=["QEvent"]).QEvent.KeyPress, Qt.Key_Tab, Qt.NoModifier))
    assert c.editor is not None and s.parent(c.editing_id)["id"] == "n1"
    editing = c.editing_id; QTest.keyClick(c.editor, Qt.Key_Escape); c.select_id(editing)
    QTest.keyClick(c, Qt.Key_Delete); assert s.node(editing) is None
