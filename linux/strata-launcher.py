#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
LINUX = ROOT / "linux"
if str(LINUX) not in sys.path:
    sys.path.insert(0, str(LINUX))

from strata_linux.__main__ import main

if __name__ == "__main__":
    raise SystemExit(main())
