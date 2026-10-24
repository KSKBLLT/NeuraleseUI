"""Maintainer tool: extract pinned official wheels, without installing packages.

No downloader or package manager runs in the application. Only the offline
Tokenizer.from_file API is used; Hub/Transformers/Torch are not bundled.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import zipfile

WHEELS = {
    "tokenizers-0.22.2-cp39-abi3-win_amd64.whl": "windows-x64",
    "tokenizers-0.22.2-cp39-abi3-macosx_11_0_arm64.whl": "macos-arm64",
    "jinja2-3.1.6-py3-none-any.whl": "common",
    "markupsafe-3.0.3-cp311-cp311-win_amd64.whl": "common",
}


def vendor(wheels: Path, destination: Path):
    destination.mkdir(parents=True, exist_ok=True)
    records = []
    for filename, platform in WHEELS.items():
        wheel = wheels / filename
        record = {"wheel": filename, "sha256": hashlib.sha256(wheel.read_bytes()).hexdigest(),
                  "platform": platform, "files": {}}
        with zipfile.ZipFile(wheel) as archive:
            for name in sorted(archive.namelist()):
                relative = Path(name)
                if name.endswith("/") or relative.is_absolute() or ".." in relative.parts:
                    continue
                # MarkupSafe's small stdlib fallback works on both platforms;
                # its optional accelerator is not needed by the chat template.
                if filename.startswith("markupsafe-") and relative.suffix == ".pyd":
                    continue
                if relative.suffix in {".pyi", ".c", ".h"} or relative.name in {"RECORD", "WHEEL", "py.typed"}:
                    continue
                data = archive.read(name)
                target = destination / platform / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                record["files"][name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        if filename.startswith("tokenizers-"):
            # The official wheel declares Apache-2.0 but omits the license text.
            # Carry the exact upstream v0.22.2 LICENSE into each native package.
            license_text = (Path(__file__).resolve().parents[2] / "docs/licenses/Tokenizers.txt").read_bytes()
            if hashlib.sha256(license_text).hexdigest() != "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4":
                raise ValueError("Unexpected upstream tokenizers license")
            name = "tokenizers-0.22.2.dist-info/licenses/LICENSE"
            target = destination / platform / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(license_text)
            record["files"][name] = {"bytes": len(license_text), "sha256": hashlib.sha256(license_text).hexdigest()}
            record["license_source"] = "https://github.com/huggingface/tokenizers/blob/v0.22.2/LICENSE"
        records.append(record)
    manifest = {"schema_version": 1, "python": "CPython 3.11", "packages": records,
                "offline_api": "Tokenizer.from_file, Jinja2 sandbox; no Hub, Torch or Transformers"}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wheels", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[2] / "local_runtime/language_vendor")
    args = parser.parse_args()
    vendor(args.wheels, args.output)
