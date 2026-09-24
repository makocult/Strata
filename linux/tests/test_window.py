import json
import os
import sys
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtWidgets import QApplication

from strata_linux.window import Canvas, Window


@pytest.fixture(scope="session")
def app():
    return QApplication.instance() or QApplication([])


def test_window_exposes_store_canvas_library_and_title(app, tmp_path):
    window = Window(data_path=tmp_path)
    assert window.store is not None
    assert isinstance(window.canvas, Canvas)
    assert window.library is not None
    assert window.windowTitle().startswith("Strata")


def test_canvas_edit_emits_changed_and_updates_store(app, tmp_path):
    window = Window(data_path=tmp_path)
    node_id = window.store.selected
    changed = []
    window.canvas.changed.connect(lambda: changed.append(True))
    window.canvas.begin_edit(node_id)
    window.canvas.editor.setText("新标题")
    assert window.canvas.finish_edit()
    assert window.store.node(node_id)["title"] == "新标题"
    assert changed


def test_launcher_smoke_roundtrip(tmp_path):
    result = tmp_path / "smoke.json"
    data_dir = tmp_path / "data"
    launcher = Path(__file__).parents[1] / "strata-launcher.py"
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen")
    import subprocess

    completed = subprocess.run(
        [sys.executable, str(launcher), "--smoke-test", str(result), "--data-dir", str(data_dir)],
        env=env,
        capture_output=True,
        text=True,
        timeout=20,
    )
    assert completed.returncode == 0, completed.stderr
    payload = json.loads(result.read_text())
    assert payload["ok"] is True
    assert payload["roundtrip"] is True
    assert Path(payload["screenshot"]).exists()


def test_launcher_version_is_headless():
    launcher = Path(__file__).parents[1] / "strata-launcher.py"
    import subprocess

    completed = subprocess.run([sys.executable, str(launcher), "--version"], capture_output=True, text=True)
    assert completed.returncode == 0
    assert completed.stdout.strip() == "1.0.0-linux.1"
