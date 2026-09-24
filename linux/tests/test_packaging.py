"""Packaging contracts; no real package build or home-directory writes."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


class PackagingTests(unittest.TestCase):
    def test_staging_creates_valid_desktop_package(self):
        script = Path(__file__).parents[1] / "build.py"
        self.assertTrue(script.exists(), "Linux packaging implementation is missing")
        spec = importlib.util.spec_from_file_location("strata_build", script)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            bundle = base / "bundle"
            bundle.mkdir()
            (bundle / "strata").write_text("#!/bin/sh\nexit 0\n")
            (bundle / "strata").chmod(0o755)
            package = module.stage_deb(bundle, base / "stage", "1.0.0~linux.1")
            control = (package / "DEBIAN/control").read_text()
            self.assertIn("Architecture: amd64", control)
            self.assertIn("libc6 (>= 2.39)", control)
            self.assertIn("Package: strata", control)
            self.assertTrue((package / "usr/bin/strata").is_symlink())
            self.assertEqual((package / "usr/bin/strata").readlink().as_posix(), "../../opt/strata/strata")
            self.assertTrue((package / "opt/strata/strata").exists())
            desktop = (package / "usr/share/applications/design.wisepulse.strata.desktop").read_text()
            self.assertIn("Exec=strata %f", desktop)
            self.assertIn("Terminal=false", desktop)
            self.assertNotIn("application/json", desktop)


if __name__ == "__main__":
    unittest.main()
