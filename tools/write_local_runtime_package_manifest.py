from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import sys
from pathlib import Path


SCHEMA_VERSION = 1
REQUIRED_DISTRIBUTIONS = (
    "numpy",
    "onnx",
    "onnxruntime-training-cpu",
    "lmdb",
    "pyserial",
    "tokenizers",
    "jinja2",
)


def _normalize(name: str) -> str:
    return name.lower().replace("_", "-").replace(".", "-")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(requirements: Path, site_packages: Path | None = None) -> dict:
    distributions = list(importlib.metadata.distributions(**({"path":[str(site_packages)]} if site_packages else {})))
    if any(_normalize(item.metadata.get("Name") or "") in {"onnxruntime", "onnxruntime-gpu"} for item in distributions):
        raise RuntimeError("Do not install a second ONNX Runtime distribution beside training-cpu")
    ort_training = [
        distribution
        for distribution in distributions
        if _normalize(distribution.metadata.get("Name") or "").startswith(
            "onnxruntime-training"
        )
    ]
    if len(ort_training) != 1:
        installed = [
            f"{item.metadata.get('Name')}=={item.version}" for item in ort_training
        ]
        raise RuntimeError(
            "Expected exactly one ONNX Runtime Training distribution; found "
            + repr(installed)
        )

    packages = []
    by_name = {
        _normalize(distribution.metadata.get("Name") or ""): distribution
        for distribution in distributions
    }
    for name in REQUIRED_DISTRIBUTIONS:
        distribution = by_name.get(_normalize(name))
        if distribution is None:
            raise RuntimeError(f"Required local runtime distribution is missing: {name}")
        metadata_path = Path(distribution._path) / "METADATA"
        if not metadata_path.is_file():
            raise RuntimeError(f"Distribution metadata is missing: {metadata_path}")
        packages.append(
            {
                "name": name,
                "version": distribution.version,
                "metadata_sha256": _sha256(metadata_path),
            }
        )

    return {
        "schema": SCHEMA_VERSION,
        "python": {
            "implementation": sys.implementation.name,
            "major_minor": f"{sys.version_info.major}.{sys.version_info.minor}",
        },
        "requirements_sha256": _sha256(requirements),
        "packages": packages,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requirements", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--site-packages", type=Path, help="Inspect staged target-platform distribution metadata")
    args = parser.parse_args(argv)
    manifest = build_manifest(args.requirements.resolve(), args.site_packages)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(
        json.dumps(manifest, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
