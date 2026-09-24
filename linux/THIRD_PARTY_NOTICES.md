# Third-party notices — Linux distribution

Strata Linux is a Python application using the native Qt Widgets toolkit. This
package does not change the license of the pre-existing Strata source repository.

## Qt / PySide6 / Shiboken6 6.11.2

Copyright (C) The Qt Company Ltd. and other contributors.
The LGPLv3 option applies to the Qt Core/Gui/Widgets libraries and Python bindings
used here. Full GPLv3 and LGPLv3 texts are included in `licenses/`. Third-party
components retain their own licenses and notices in the upstream source trees.

- Qt licensing: https://doc.qt.io/qt-6/licensing.html
- Qt for Python licensing: https://doc.qt.io/qtforpython-6/licenses.html
- Corresponding Qt source: https://download.qt.io/archive/qt/6.11/6.11.2/single/
- Corresponding binding source: https://download.qt.io/official_releases/QtForPython/pyside6/PySide6-6.11.2-src/
- Source repositories: https://code.qt.io/cgit/qt/qtbase.git/ and
  https://code.qt.io/cgit/pyside/pyside-setup.git/ (tag `v6.11.2`).

The included shared libraries are dynamically loaded from `_internal/` in the
installed `strata` directory. You may replace them with compatible modified
versions, or run the published Strata Python source with your own compatible Qt
installation. Reverse engineering for debugging modifications to LGPL-covered
libraries is permitted; Strata imposes no restriction on that right. No Qt
commercial license or GPL-only Qt module is required by this application.

## Python 3.12

Copyright Python Software Foundation and contributors. PSF license and bundled
component notices are included in `licenses/Python-LICENSE.txt`.
Source: https://www.python.org/downloads/source/

## PyInstaller 6.22.3

Copyright PyInstaller contributors. GPLv2-or-later with the PyInstaller bootloader
exception permits packaging independent applications without imposing the GPL
on them. Its distribution license files are copied into `licenses/`.
Source: https://github.com/pyinstaller/pyinstaller/tree/v6.22.3

## Rebuilding / library replacement

The exact Strata source and build recipe accompany this GitHub release. Install
`linux/requirements-build.txt` in a virtual environment and run
`python linux/build.py --output YOUR_OUTPUT_DIRECTORY` on Ubuntu 24.04 x86_64.
For an unfrozen run use `PYTHONPATH=linux python -m strata_linux`. Library users
can replace the pinned Qt version with an ABI-compatible build. The application
is distributed as an unpacked directory rather than encrypted or statically
linked code, and does not verify or prohibit such replacements.
