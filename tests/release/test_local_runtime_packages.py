from __future__ import annotations

import email
import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "local_runtime"
LOCK = RUNTIME / "runtime_packages.lock.json"
REQUIREMENTS = RUNTIME / "requirements.txt"


def _normalize(name: str) -> str:
    return name.lower().replace("_", "-").replace(".", "-")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _site_packages() -> Path | None:
    embedded = RUNTIME / "python" / "Lib" / "site-packages"
    return embedded if embedded.is_dir() else None


def _installed_metadata(site_packages: Path) -> list[dict[str, str | Path]]:
    result = []
    for path in site_packages.glob("*.dist-info/METADATA"):
        message = email.message_from_bytes(path.read_bytes())
        result.append(
            {
                "name": message.get("Name", ""),
                "version": message.get("Version", ""),
                "path": path,
            }
        )
    return result


def test_embedded_runtime_has_one_locked_ort_training_distribution():
    manifest = json.loads(LOCK.read_text(encoding="utf-8"))
    assert manifest["schema"] == 1
    assert manifest["python"]["major_minor"] == "3.11"
    assert manifest["requirements_sha256"] == _sha256(REQUIREMENTS)

    packages = {_normalize(item["name"]): item for item in manifest["packages"]}
    assert packages["onnxruntime-training-cpu"]["version"] == "1.19.2"
    vendor = json.loads((RUNTIME / "language_vendor/manifest.json").read_text(encoding="utf-8"))
    assert any(p["wheel"] == "tokenizers-0.22.2-cp39-abi3-win_amd64.whl" for p in vendor["packages"])
    assert any(p["wheel"] == "jinja2-3.1.6-py3-none-any.whl" for p in vendor["packages"])
    assert "tokenizers" not in packages and "jinja2" not in packages
    assert "onnxruntime" not in packages

    site_packages = _site_packages()
    if site_packages is None:
        return
    installed = _installed_metadata(site_packages)
    ort_training = [
        item
        for item in installed
        if _normalize(str(item["name"])).startswith("onnxruntime-training")
    ]
    assert [(item["name"], item["version"]) for item in ort_training] == [
        ("onnxruntime-training-cpu", "1.19.2")
    ]

    by_name = {_normalize(str(item["name"])): item for item in installed}
    for name, locked in packages.items():
        current = by_name[name]
        assert current["version"] == locked["version"]
        assert _sha256(Path(current["path"])) == locked["metadata_sha256"]

    python_exe = RUNTIME / "python" / "python.exe"
    imported = json.loads(
        subprocess.check_output(
            [
                str(python_exe),
                "-c",
                (
                    "import json,numpy,onnx,onnxruntime;"
                    "print(json.dumps({'numpy':numpy.__version__,'onnx':onnx.__version__,"
                    "'onnxruntime-training-cpu':onnxruntime.__version__}))"
                ),
            ],
            text=True,
        )
    )
    for name, version in imported.items():
        assert version == packages[name]["version"]
