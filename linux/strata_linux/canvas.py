from __future__ import annotations

from PySide6.QtCore import QPointF, QRectF, Qt, Signal
from PySide6.QtGui import QColor, QFont, QPainter, QPen
from PySide6.QtWidgets import (
    QGraphicsItem, QGraphicsRectItem, QGraphicsScene, QGraphicsTextItem,
    QGraphicsView, QLineEdit,
)


class _Editor(QLineEdit):
    def __init__(self, canvas):
        super().__init__(canvas.viewport())
        self.canvas = canvas

    def keyPressEvent(self, event):
        if event.key() == Qt.Key_Escape:
            self.canvas.finish_edit(False); return
        if event.key() == Qt.Key_Tab:
            ident = self.canvas.editing_id
            self.canvas.finish_edit(True)
            if ident:
                child = self.canvas.store.add_child(ident)
                self.canvas.refresh(focus=child)
                self.canvas.begin_edit(child)
                self.canvas.changed.emit()
            return
        super().keyPressEvent(event)


class _NodeItem(QGraphicsRectItem):
    def __init__(self, canvas, ident, rect, title):
        super().__init__(rect)
        self.canvas, self.ident = canvas, ident
        self.setBrush(QColor("#ffffff")); self.setPen(QPen(QColor("#aeb8c4"), 1.2))
        self.setFlag(QGraphicsItem.ItemIsSelectable, True)
        text = QGraphicsTextItem(title, self)
        text.setDefaultTextColor(QColor("#182230")); text.setFont(QFont(".AppleSystemUIFont", 14))
        text.setTextWidth(max(1, rect.width() - 20)); text.setPos(10, 8)
        self.text_item = text

    def mousePressEvent(self, event):
        additive = bool(event.modifiers() & (Qt.ControlModifier | Qt.MetaModifier))
        self.canvas.select_id(self.ident, additive)
        super().mousePressEvent(event)

    def mouseDoubleClickEvent(self, event):
        self.canvas.begin_edit(self.ident)
        event.accept()


class Canvas(QGraphicsView):
    changed = Signal()
    selection_changed = Signal()

    def __init__(self, store, parent=None):
        super().__init__(parent)
        self.store = store
        self.scene_obj = QGraphicsScene(self)
        self.setScene(self.scene_obj)
        self.setRenderHint(QPainter.Antialiasing)
        self.setDragMode(QGraphicsView.NoDrag)
        self.setViewportUpdateMode(QGraphicsView.FullViewportUpdate)
        self.orientation = "horizontal"
        self.zoom = 1.0
        self.items: dict[str, _NodeItem] = {}
        self.editor = None
        self.editing_id = None
        self._editing_original = None
        self._last_enter = None
        self._pan_start = None
        self._rubber_origin = None
        self._rubber = None
        self.refresh()

    def _children(self, node):
        return node.get("children", [])

    def _visible(self):
        result = []
        def visit(n, depth=0):
            result.append((n, depth))
            if not n.get("isCollapsed", False):
                for child in self._children(n): visit(child, depth + 1)
        visit(self.store.root)
        return result

    def _size(self, title):
        lines = str(title or "新节点").splitlines() or ["新节点"]
        width = min(300, max(88, max(len(x) for x in lines) * 8 + 28))
        return width, max(40, len(lines) * 20 + 16)

    def refresh(self, focus=None):
        old_zoom = self.zoom
        active = self.editing_id
        self.scene_obj.clear(); self.items.clear()
        nodes = self._visible()
        positions = {}
        if self.orientation == "horizontal":
            levels = {}
            for n, d in nodes: levels.setdefault(d, []).append(n)
            for d, group in levels.items():
                y = 0
                for n in group:
                    w, h = self._size(n.get("title", "")); positions[n["id"]] = (d * 220, y, w, h); y += h + 24
        else:
            levels = {}
            for n, d in nodes: levels.setdefault(d, []).append(n)
            for d, group in levels.items():
                x = 0
                for n in group:
                    w, h = self._size(n.get("title", "")); positions[n["id"]] = (x, d * 130, w, h); x += w + 24
        for n, _ in nodes:
            ident = n["id"]; x, y, w, h = positions[ident]
            item = _NodeItem(self, ident, QRectF(0, 0, w, h), n.get("title", "")); item.setPos(x, y)
            self.scene_obj.addItem(item); self.items[ident] = item
        self.scene_obj.setSceneRect(self.scene_obj.itemsBoundingRect().adjusted(-80, -80, 80, 80))
        self.zoom = old_zoom
        self.resetTransform(); self.scale(self.zoom, self.zoom)
        if active and active in self.items and self.editor:
            self._place_editor()
        self._apply_selection()
        if focus and focus in self.items: self.centerOn(self.items[focus])

    def _apply_selection(self):
        selected = getattr(self.store, "selection", set())
        for ident, item in self.items.items(): item.setSelected(ident in selected)

    def select_id(self, ident, additive=False):
        self.store.select(ident, additive=additive)
        self._apply_selection(); self.selection_changed.emit()

    def set_zoom(self, value):
        self.zoom = max(.25, min(3.0, float(value))); self.resetTransform(); self.scale(self.zoom, self.zoom)

    def set_orientation(self, orientation):
        if orientation not in ("horizontal", "vertical"): return
        self.orientation = orientation; self.refresh()

    def begin_edit(self, ident, replacement=None):
        if ident not in self.items: return
        self.finish_edit(True)
        self.editing_id = ident; self._editing_original = self.store.node(ident).get("title", "")
        self.editor = _Editor(self); self.editor.setText(self._editing_original if replacement is None else replacement)
        self.editor.selectAll(); self.editor.setFocus(); self.editor.returnPressed.connect(lambda: self.finish_edit(True)); self._place_editor()

    def _place_editor(self):
        if not self.editor or self.editing_id not in self.items: return
        r = self.items[self.editing_id].sceneBoundingRect(); p = self.mapFromScene(r.topLeft())
        self.editor.setGeometry(p.x() + 6, p.y() + 4, max(40, int(r.width() - 12)), max(28, int(r.height() - 8))); self.editor.show()

    def finish_edit(self, commit=True):
        if not self.editor: return False
        ident, editor = self.editing_id, self.editor; text = editor.text()
        editor.hide(); editor.deleteLater(); self.editor = None; self.editing_id = None
        if commit and ident and self.store.node(ident) is not None:
            changed = self.store.rename(ident, text)
            self.changed.emit(); self.refresh(focus=ident)
            return changed
        return bool(not commit)

    def toggle(self, ident):
        if self.store.toggle(ident): self.changed.emit(); self.refresh(focus=ident)

    def keyPressEvent(self, event):
        if self.editor:
            if event.key() == Qt.Key_Escape: self.finish_edit(False); return
            if event.key() == Qt.Key_Tab:
                ident = self.editing_id; self.finish_edit(True)
                if ident: self.begin_edit(self.store.add_child(ident)); self.changed.emit()
                return
            if event.key() in (Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down):
                self.editor.keyPressEvent(event); return
        if event.key() == Qt.Key_Delete:
            ids = list(getattr(self.store, "selection", set()))
            ids = [x for x in ids if x != self.store.root["id"]]
            if ids: self.store.delete(ids); self.changed.emit(); self.refresh();
            return
        if event.key() == Qt.Key_Space and getattr(self.store, "selected", None): self.toggle(self.store.selected); return
        super().keyPressEvent(event)

    def wheelEvent(self, event):
        factor = 1.1 if event.angleDelta().y() > 0 else 1 / 1.1
        self.set_zoom(self.zoom * factor); event.accept()

    def mousePressEvent(self, event):
        if event.button() == Qt.MiddleButton or (event.button() == Qt.LeftButton and not self.itemAt(event.position().toPoint())):
            self._pan_start = event.position(); self.setCursor(Qt.ClosedHandCursor)
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        if self._pan_start is not None:
            delta = event.position() - self._pan_start; self._pan_start = event.position()
            self.horizontalScrollBar().setValue(self.horizontalScrollBar().value() - int(delta.x()))
            self.verticalScrollBar().setValue(self.verticalScrollBar().value() - int(delta.y()))
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        if self._pan_start is not None: self._pan_start = None; self.setCursor(Qt.ArrowCursor)
        super().mouseReleaseEvent(event)
