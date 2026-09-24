from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PySide6.QtWidgets import QApplication

from .window import Window

VERSION = "1.0.0-linux.1"


def main(argv=None):
    parser = argparse.ArgumentParser(prog="strata")
    parser.add_argument("--version", action="version", version=VERSION)
    parser.add_argument("--smoke-test", metavar="RESULT_JSON_PATH")
    parser.add_argument("--data-dir", metavar="DATA_DIR")
    parser.add_argument("path", nargs="?")
    args = parser.parse_args(argv)
    app = QApplication.instance() or QApplication(sys.argv[:1])
    app.setApplicationName("Strata")
    app.setOrganizationName("design.wisepulse")
    app.setApplicationDisplayName("Strata")
    window = Window(data_path=args.data_dir)
    if args.path:
        window.store.open(args.path)
        window.canvas.refresh()
    window.show()
    if args.smoke_test:
        return _smoke(app, window, Path(args.smoke_test))
    return app.exec()


def _smoke(app, window, result_path):
    from PySide6.QtCore import QTimer
    result_path.parent.mkdir(parents=True, exist_ok=True)
    output = {"ok": False, "roundtrip": False}
    try:
        root = getattr(window.store, "root", None)
        selected = getattr(window.store, "selected", None)
        if selected is None and isinstance(root, dict): selected = root.get("id")
        if selected is not None:
            window.canvas.begin_edit(selected, "Smoke document")
            window.canvas.finish_edit()
        json_path = result_path.with_suffix(".json")
        window.store.save(json_path)
        reopened = type(window.store)()
        reopened.open(json_path)
        document_roundtrip = getattr(reopened, "root", None) == getattr(window.store, "root", None)
        library_roundtrip = True
        if getattr(window, "library", None) is not None:
            library = window.library
            try:
                material = library.save("Smoke material", "Smoke body")
                library.reload()
                library_roundtrip = any(item.get("id") == material.get("id") for item in library.materials)
            except Exception as exc:
                library_roundtrip = False
                output["library_error"] = str(exc)
        output["roundtrip"] = bool(document_roundtrip and library_roundtrip)
        png_path = result_path.with_suffix(".png")
        window.grab().save(str(png_path), "PNG")
        output["screenshot"] = str(png_path)
        output["ok"] = bool(output["roundtrip"] and png_path.exists())
    except Exception as exc:
        output["error"] = str(exc)
    result_path.write_text(__import__("json").dumps(output, ensure_ascii=False), encoding="utf-8")
    app.processEvents()
    app.quit()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
