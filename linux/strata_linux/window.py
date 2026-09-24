from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, Signal
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtWidgets import (QDialog, QDialogButtonBox, QDockWidget, QFileDialog,
    QLabel, QLineEdit, QListWidget, QMainWindow, QMessageBox, QPushButton,
    QPlainTextEdit, QToolBar, QVBoxLayout, QWidget)

from .canvas import Canvas
from .model import Store
from .services import AIClient, Library, Settings, data_dir


class TextDialog(QDialog):
    def __init__(self, title, label, parent=None):
        super().__init__(parent); self.setWindowTitle(title); self.text = QPlainTextEdit(self)
        layout = QVBoxLayout(self); layout.addWidget(QLabel(label)); layout.addWidget(self.text)
        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept); buttons.rejected.connect(self.reject); layout.addWidget(buttons)


class _Signals(QObject):
    finished = Signal(object); failed = Signal(str)


class _AIWorker(QRunnable):
    def __init__(self, fn):
        super().__init__(); self.fn = fn; self.signals = _Signals()
    def run(self):
        try: self.signals.finished.emit(self.fn())
        except Exception as exc: self.signals.failed.emit(str(exc))


class Window(QMainWindow):
    def __init__(self, store=None, data_path=None):
        super().__init__(); self.setWindowTitle("Strata"); self.resize(1100, 720)
        self.data_path = Path(data_path) if data_path else Path(data_dir()); self.data_path.mkdir(parents=True, exist_ok=True)
        self.store = store or Store(); self.canvas = Canvas(self.store, self); self.setCentralWidget(self.canvas)
        self.library = Library(self.data_path / "material-library.json")
        self.settings = Settings(self.data_path / "ai-settings.json"); self._dirty = False
        self._build_toolbar(); self._build_library(); self.canvas.changed.connect(self._mark_dirty)

    def _build_toolbar(self):
        bar = QToolBar("Strata"); self.addToolBar(bar)
        for label, slot, shortcut in (("新建", self.new_document, QKeySequence.New), ("打开", self.open_document, QKeySequence.Open), ("保存", self.save_document, QKeySequence.Save)):
            action = QAction(label, self); action.triggered.connect(slot); action.setShortcut(shortcut); bar.addAction(action)
        bar.addSeparator()
        for label, orientation in (("横向", "horizontal"), ("纵向", "vertical")):
            action = QAction(label, self); action.triggered.connect(lambda checked=False, value=orientation: self.canvas.set_orientation(value)); bar.addAction(action)
        bar.addSeparator()
        action = QAction("素材库", self); action.triggered.connect(lambda: self.library_dock.setVisible(not self.library_dock.isVisible())); bar.addAction(action)
        action = QAction("AI 整理", self); action.triggered.connect(self.ai_dialog); bar.addAction(action)

    def _build_library(self):
        self.library_dock = QDockWidget("素材库", self); body = QWidget(); layout = QVBoxLayout(body)
        self.library_search = QLineEdit(); self.library_search.setPlaceholderText("搜索标题或正文"); self.library_list = QListWidget(); add = QPushButton("新增素材")
        add.clicked.connect(self.add_material); layout.addWidget(self.library_search); layout.addWidget(self.library_list); layout.addWidget(add)
        self.library_dock.setWidget(body); self.addDockWidget(Qt.RightDockWidgetArea, self.library_dock); self.library_dock.hide()
        self.library_search.textChanged.connect(self.reload_library); self.reload_library()

    def reload_library(self):
        self.library_list.clear()
        for material in self.library.matching(self.library_search.text()): self.library_list.addItem(material["title"])

    def add_material(self):
        dialog = TextDialog("新增素材", "正文", self)
        if dialog.exec():
            try: self.library.save("未命名素材", dialog.text.toPlainText()); self.reload_library()
            except Exception as exc: QMessageBox.warning(self, "素材保存失败", str(exc))

    def _mark_dirty(self): self._dirty = True; self.setWindowTitle("Strata *")

    def new_document(self):
        self.store.replace({"id": "root", "title": "主题", "children": [], "isCollapsed": False}); self.canvas.refresh(); self._mark_dirty()

    def open_document(self):
        path, _ = QFileDialog.getOpenFileName(self, "打开", str(self.data_path), "JSON (*.json)")
        if path: self.store.open(path); self.canvas.refresh(); self._dirty = False; self.setWindowTitle("Strata")

    def save_document(self):
        path, _ = QFileDialog.getSaveFileName(self, "保存", str(self.data_path / "Strata.json"), "JSON (*.json)")
        if path: self.store.save(path); self._dirty = False; self.setWindowTitle("Strata")

    def ai_dialog(self):
        dialog = TextDialog("AI 整理", "输入整理需求", self)
        if not dialog.exec(): return
        try: client = AIClient(self.settings.configuration, self.settings.key(self.settings.configuration["baseURL"]))
        except Exception as exc: QMessageBox.warning(self, "AI 设置错误", str(exc)); return
        revision = self.store.revision; worker = _AIWorker(lambda: client.generate(dialog.text.toPlainText()))
        worker.signals.finished.connect(lambda root: self._apply_ai(root, revision)); worker.signals.failed.connect(lambda error: QMessageBox.warning(self, "AI 整理失败", error)); QThreadPool.globalInstance().start(worker)

    def _apply_ai(self, root, revision):
        if self.store.revision != revision: return
        self.store.replace(root); self.canvas.refresh(); self._mark_dirty()

    def closeEvent(self, event):
        if not self._dirty: event.accept(); return
        answer = QMessageBox.question(self, "未保存内容", "保存当前内容？", QMessageBox.Save | QMessageBox.Discard | QMessageBox.Cancel)
        if answer == QMessageBox.Save: self.save_document(); event.accept()
        elif answer == QMessageBox.Discard: event.accept()
        else: event.ignore()
