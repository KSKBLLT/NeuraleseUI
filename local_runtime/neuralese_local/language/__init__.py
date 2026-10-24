"""Offline language-model inference and inspectable educational views."""

from pathlib import Path
import platform
import sys


def _use_bundled_dependencies():
    root = Path(__file__).resolve().parents[2] / "language_vendor"
    target = "windows-x64" if sys.platform == "win32" else "macos-arm64" if sys.platform == "darwin" and platform.machine().lower() in {"arm64", "aarch64"} else ""
    # These are shipped files, never downloaded or installed on the user's PC.
    for directory in (root / "common", root / target if target else root / "unsupported"):
        if directory.is_dir() and str(directory) not in sys.path:
            sys.path.insert(0, str(directory))


_use_bundled_dependencies()
