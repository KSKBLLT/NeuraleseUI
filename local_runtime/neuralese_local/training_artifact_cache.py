from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import time
from contextlib import contextmanager
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any, Callable, Dict, Iterator


CACHE_SCHEMA_VERSION = 4


def required_artifacts(artifact_format: str = "onnx") -> Dict[str, str]:
    extension = "ort" if artifact_format == "ort" else "onnx"
    return {
        "training_model": f"training_model.{extension}",
        "eval_model": f"eval_model.{extension}",
        "optimizer_model": f"optimizer_model.{extension}",
        "checkpoint": "checkpoint",
    }


@dataclass(frozen=True)
class ArtifactEntry:
    key: str
    directory: Path
    training_model: Path
    eval_model: Path
    optimizer_model: Path
    checkpoint: Path
    manifest: Path
    cache_hit: bool


def _json_default(value: Any) -> Any:
    if isinstance(value, Path):
        return str(value)
    if hasattr(value, "name") and hasattr(value, "value"):
        return str(value.name)
    return str(value)


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=True,
        allow_nan=False,
        default=_json_default,
    ).encode("utf-8")


def _model_structure(model: Any) -> Any:
    if isinstance(model, (dict, list, tuple, str, int, float, bool)) or model is None:
        return model
    if not hasattr(model, "SerializeToString") or not hasattr(model, "graph"):
        return str(model)

    structural = type(model)()
    structural.CopyFrom(model)
    for tensor in structural.graph.initializer:
        for field in (
            "raw_data",
            "float_data",
            "int32_data",
            "string_data",
            "int64_data",
            "double_data",
            "uint64_data",
            "external_data",
        ):
            tensor.ClearField(field)
        tensor.ClearField("data_location")
    return {
        "protobuf_sha256": hashlib.sha256(
            structural.SerializeToString(deterministic=True)
        ).hexdigest()
    }


def default_capability() -> Dict[str, str]:
    try:
        import onnxruntime as ort

        ort_version = str(ort.__version__)
    except Exception:
        ort_version = "unavailable"
    return {
        "ort_version": ort_version,
        "platform": platform.system().lower(),
        "architecture": platform.machine().lower(),
        "processor": platform.processor().lower(),
    }


def artifact_fingerprint(
    model: Any,
    trainable_params: Any,
    loss: Any,
    optimizer: Any,
    capability: Any = None,
) -> str:
    contract = {
        "schema": CACHE_SCHEMA_VERSION,
        "model": _model_structure(model),
        "trainable_params": sorted(str(value) for value in trainable_params),
        "loss": str(getattr(loss, "name", loss)),
        "optimizer": str(getattr(optimizer, "name", optimizer)),
        "capability": capability if capability is not None else default_capability(),
    }
    return hashlib.sha256(_canonical_json(contract)).hexdigest()


class ArtifactCache:
    def __init__(self, root: str | Path, stale_lock_seconds: float = 120.0) -> None:
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.stale_lock_seconds = float(stale_lock_seconds)

    def get_or_create(
        self,
        spec: Dict[str, Any],
        builder: Callable[[Path], None],
    ) -> ArtifactEntry:
        key = str(spec.get("fingerprint") or "")
        if not key or any(not (character.isalnum() or character in "-_") for character in key):
            raise ValueError("artifact spec requires a filesystem-safe fingerprint")
        target = self.root / key
        entry = self._validated_entry(key, target)
        if entry is not None:
            return replace(entry, cache_hit=True)

        with self._lock(key):
            entry = self._validated_entry(key, target)
            if entry is not None:
                return replace(entry, cache_hit=True)

            if target.exists():
                shutil.rmtree(target)
            building = self.root / f"{key}.building.{os.getpid()}"
            if building.exists():
                shutil.rmtree(building)
            building.mkdir(parents=True)
            try:
                builder(building)
                artifact_format = str(spec.get("artifact_format") or "onnx")
                files = self._hash_required_files(building, artifact_format)
                manifest_data = {
                    "schema": CACHE_SCHEMA_VERSION,
                    "fingerprint": key,
                    "spec": spec,
                    "files": files,
                }
                manifest_path = building / "manifest.json"
                with manifest_path.open("w", encoding="utf-8") as handle:
                    json.dump(manifest_data, handle, sort_keys=True, indent=2, default=_json_default)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(building, target)
            except Exception:
                if building.exists():
                    shutil.rmtree(building)
                raise

            entry = self._validated_entry(key, target)
            if entry is None:
                raise RuntimeError(f"artifact cache entry '{key}' failed validation after build")
            return replace(entry, cache_hit=False)

    def _validated_entry(self, key: str, directory: Path) -> ArtifactEntry | None:
        manifest_path = directory / "manifest.json"
        if not manifest_path.is_file():
            return None
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        if manifest.get("schema") != CACHE_SCHEMA_VERSION or manifest.get("fingerprint") != key:
            return None
        hashes = manifest.get("files")
        if not isinstance(hashes, dict):
            return None
        spec = manifest.get("spec") if isinstance(manifest.get("spec"), dict) else {}
        names = required_artifacts(str(spec.get("artifact_format") or "onnx"))
        for filename in names.values():
            path = directory / filename
            expected = hashes.get(filename)
            if not path.is_file() or not isinstance(expected, str):
                return None
            if _sha256_file(path) != expected:
                return None
        return ArtifactEntry(
            key=key,
            directory=directory,
            training_model=directory / names["training_model"],
            eval_model=directory / names["eval_model"],
            optimizer_model=directory / names["optimizer_model"],
            checkpoint=directory / names["checkpoint"],
            manifest=manifest_path,
            cache_hit=False,
        )

    @staticmethod
    def _hash_required_files(directory: Path, artifact_format: str = "onnx") -> Dict[str, str]:
        hashes: Dict[str, str] = {}
        for filename in required_artifacts(artifact_format).values():
            path = directory / filename
            if not path.is_file():
                raise FileNotFoundError(f"artifact builder did not create '{filename}'")
            hashes[filename] = _sha256_file(path)
        return hashes

    @contextmanager
    def _lock(self, key: str) -> Iterator[None]:
        lock_path = self.root / f"{key}.lock"
        deadline = time.monotonic() + 30.0
        while True:
            try:
                descriptor = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                    json.dump({"pid": os.getpid(), "created": time.time()}, handle)
                break
            except FileExistsError:
                if self._lock_is_stale(lock_path):
                    try:
                        lock_path.unlink()
                    except FileNotFoundError:
                        pass
                    continue
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"timed out waiting for artifact cache lock '{key}'")
                time.sleep(0.025)
        try:
            yield
        finally:
            try:
                lock_path.unlink()
            except FileNotFoundError:
                pass

    def _lock_is_stale(self, lock_path: Path) -> bool:
        try:
            data = json.loads(lock_path.read_text(encoding="utf-8"))
            created = float(data.get("created", 0.0))
            pid = int(data.get("pid", -1))
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            return True
        if time.time() - created > self.stale_lock_seconds:
            return True
        return not _process_exists(pid)


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _process_exists(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True
