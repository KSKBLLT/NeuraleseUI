"""Copy verified offline inference assets into an export's local_runtime.

Uses only the standard library. Never installs packages or downloads weights.
The destination's packaged Python runs check_language_runtime.py afterwards.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stage(source: Path, destination: Path, platform: str):
    source, destination = source.resolve(), destination.resolve()
    if source == destination:
        raise ValueError("Source and export runtime must be separate")
    bundle = source / "models/clean1000"
    manifest = json.loads((bundle / "language_bundle.json").read_text(encoding="utf-8"))
    if not {"decoder.onnx", "config.json", "tokenizer.json", "chat_template.jinja"} <= manifest["files"].keys():
        raise ValueError("Incomplete inference bundle")
    for name, record in manifest["files"].items():
        path = bundle / name
        if Path(name).name != name or not path.is_file() or path.stat().st_size != record["size"] or digest(path) != record["sha256"]:
            raise ValueError(f"Inference asset missing or corrupt: {name}")
    vendor_root = source / "language_vendor"
    vendor = json.loads((vendor_root / "manifest.json").read_text(encoding="utf-8"))
    selected = [record for record in vendor["packages"] if record["platform"] in ("common", platform)]
    if not any(record["platform"] == platform for record in selected):
        raise ValueError(f"No bundled tokenizer binary for {platform}")
    for package in selected:
        for name, record in package["files"].items():
            relative = Path(name)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Unsafe dependency manifest path")
            path = vendor_root / package["platform"] / relative
            if not path.is_file() or path.stat().st_size != record["bytes"] or digest(path) != record["sha256"]:
                raise ValueError(f"Bundled dependency missing or corrupt: {name}")
    # All source files are checked before publishing any destination files.
    out_bundle = destination / "models/clean1000"
    out_bundle.mkdir(parents=True, exist_ok=True)
    for name in [*manifest["files"], "language_bundle.json"]:
        shutil.copyfile(bundle / name, out_bundle / name)
    out_vendor = destination / "language_vendor"
    if out_vendor.exists():
        shutil.rmtree(out_vendor)
    out_vendor.mkdir(parents=True)
    for package in selected:
        for name in package["files"]:
            target = out_vendor / package["platform"] / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(vendor_root / package["platform"] / name, target)
    vendor["packages"] = selected
    (out_vendor / "manifest.json").write_text(json.dumps(vendor, indent=2) + "\n", encoding="utf-8")
    return {"model_id": manifest["model_id"], "source_hash": manifest["source_hash"], "platform": platform,
            "dependency_bytes": sum(r["bytes"] for p in selected for r in p["files"].values())}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-runtime", type=Path, required=True)
    parser.add_argument("--destination-runtime", type=Path, required=True)
    parser.add_argument("--platform", required=True)
    args = parser.parse_args()
    print(json.dumps(stage(args.source_runtime, args.destination_runtime, args.platform)))
