#!/usr/bin/env python3
"""Build a Linux-only, dynamically linked Qt desktop distribution."""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata

from pathlib import Path
import platform
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent
VERSION = "1.0.0-linux.1"
DEB_VERSION = "1.0.0~linux.1"


def stage_deb(bundle: Path, stage: Path, version: str) -> Path:
    stage.mkdir(parents=True, exist_ok=False)
    shutil.copytree(bundle, stage / "opt/strata")
    binary = stage / "usr/bin/strata"
    binary.parent.mkdir(parents=True)
    binary.symlink_to("../../opt/strata/strata")
    for source, relative in [
        ("design.wisepulse.strata.desktop", "usr/share/applications"),
        ("design.wisepulse.strata.svg", "usr/share/icons/hicolor/scalable/apps"),
    ]:
        destination = stage / relative
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / "packaging" / source, destination / source)
    control_dir = stage / "DEBIAN"
    control_dir.mkdir()
    (control_dir / "control").write_text(
        f"Package: strata\nVersion: {version}\nArchitecture: amd64\n"
        "Maintainer: Strata contributors <noreply@wisepulse.design>\n"
        "Section: editors\nPriority: optional\n"
        "Depends: libc6 (>= 2.39), libstdc++6, libgcc-s1, libegl1, libgl1, "
        "libxkbcommon0, libxkbcommon-x11-0, libxcb-cursor0, libxcb-icccm4, "
        "libxcb-image0, libxcb-keysyms1, libxcb-randr0, libxcb-render-util0, "
        "libxcb-shape0, libxcb-xfixes0, libxcb-sync1, libxcb-xinerama0, "
        "libxcb-xkb1, libdbus-1-3, libfontconfig1, libglib2.0-0t64\n"
        "Recommends: libsecret-tools, gnome-keyring, fonts-noto-cjk\n"
        "Homepage: https://github.com/makocult/Strata\n"
        "Description: Local-first native mind map editor\n"
        " Native Qt Linux edition with JSON interchange, keyboard-first tree\n"
        " editing, materials and optional OpenAI-compatible AI assistance.\n",
        encoding="utf-8",
    )
    return stage


def collect_notices(bundle: Path) -> None:
    licenses = bundle / "licenses"
    licenses.mkdir(exist_ok=True)
    shutil.copytree(ROOT / "packaging/licenses", licenses, dirs_exist_ok=True)
    for name in ("PySide6-Essentials", "shiboken6", "pyinstaller"):
        distribution = importlib.metadata.distribution(name)
        for entry in distribution.files or []:
            if any(part.lower() in {"licenses", "license", "copying"} for part in entry.parts) or entry.name.lower().startswith(("license", "copying")):
                source = Path(str(distribution.locate_file(entry)))
                if source.is_file():
                    target = licenses / name / str(entry).replace("../", "")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, target)
    shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", bundle)
    shutil.copy2(ROOT / "README.md", bundle / "README-Linux.md")
    shutil.copy2(ROOT / "packaging/design.wisepulse.strata.svg", bundle)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        parser.error("Build on Linux x86_64 (Ubuntu 24.04 builder), not on macOS.")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    work = output / "work"
    work.mkdir(exist_ok=True)
    subprocess.run([
        "python", "-m", "PyInstaller", "--noconfirm", "--clean", "--onedir",
        "--name", "strata", "--paths", str(ROOT),
        "--distpath", str(output / "bundle"), "--workpath", str(work / "pyinstaller"),
        "--specpath", str(work), "--collect-submodules", "strata_linux",
        str(ROOT / "strata-launcher.py"),
    ], check=True)
    bundle = output / "bundle/strata"
    collect_notices(bundle)
    stage = work / "deb-stage"
    if stage.exists():
        shutil.rmtree(stage)
    stage_deb(bundle, stage, DEB_VERSION)
    subprocess.run(["desktop-file-validate", str(stage / "usr/share/applications/design.wisepulse.strata.desktop")], check=True)
    deb = output / f"strata_{DEB_VERSION}_amd64.deb"
    subprocess.run(["dpkg-deb", "--root-owner-group", "--build", str(stage), str(deb)], check=True)
    archive = output / f"Strata-{VERSION}-linux-x86_64.tar.gz"
    with tarfile.open(archive, "w:gz") as handle:
        handle.add(bundle, arcname="Strata")
    manifest = output / "SHA256SUMS"
    manifest.write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
        for path in (deb, archive)
    ))
    print(manifest.read_text(), end="")


if __name__ == "__main__":
    main()
