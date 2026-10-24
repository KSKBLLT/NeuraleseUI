from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Optional

import numpy as np


@dataclass
class ArrayDataset:
    name: str
    x: np.ndarray
    y: np.ndarray
    val_x: Optional[np.ndarray] = None
    val_y: Optional[np.ndarray] = None
    meta: Optional[Dict[str, Any]] = None
    materialize_x: bool = True
    x_scale: float = 1.0
    _val_scaled: Optional[np.ndarray] = None

    def __post_init__(self) -> None:
        if self.materialize_x:
            self.x = np.asarray(self.x, dtype=np.float32)
            if self.x_scale != 1.0:
                self.x = self.x * np.float32(self.x_scale)
        else:
            self.x = np.asanyarray(self.x)
        self.y = _normalize_targets(self.y)
        if self.val_x is not None:
            if self.materialize_x:
                self.val_x = np.asarray(self.val_x, dtype=np.float32)
                if self.x_scale != 1.0:
                    self.val_x = self.val_x * np.float32(self.x_scale)
            else:
                self.val_x = np.asanyarray(self.val_x)
        if self.val_y is not None:
            self.val_y = _normalize_targets(self.val_y)

    def __len__(self) -> int:
        return int(self.x.shape[0])

    def batch(self, start: int, end: int) -> tuple[np.ndarray, np.ndarray]:
        if self.materialize_x:
            return self.x[start:end], self.y[start:end]
        return self._convert_batch(self.x[start:end], self.y[start:end])

    def batch_view(self, start: int, end: int) -> tuple[np.ndarray, np.ndarray]:
        if not self.materialize_x:
            raise ValueError("lazy datasets cannot expose normalized zero-copy batch views")
        return self.x[start:end], self.y[start:end]

    def batch_indices(
        self,
        indices: Any,
        out_x: Optional[np.ndarray] = None,
        out_y: Optional[np.ndarray] = None,
    ) -> tuple[np.ndarray, np.ndarray]:
        if out_x is None or out_y is None:
            return self._convert_batch(self.x[indices], self.y[indices], out_x, out_y)
        expected_x = (len(indices), *self.x.shape[1:])
        expected_y = (len(indices), *self.y.shape[1:])
        if out_x.shape != expected_x or out_y.shape != expected_y:
            raise ValueError(
                f"batch buffers {out_x.shape}/{out_y.shape} do not match "
                f"{expected_x}/{expected_y}"
            )
        if self.x.dtype == out_x.dtype:
            np.take(self.x, indices, axis=0, out=out_x)
        else:
            np.copyto(out_x, self.x[indices], casting="unsafe")
        if not self.materialize_x and self.x_scale != 1.0:
            np.multiply(out_x, np.float32(self.x_scale), out=out_x)
        if self.y.dtype == out_y.dtype:
            np.take(self.y, indices, axis=0, out=out_y)
        else:
            np.copyto(out_y, self.y[indices], casting="unsafe")
        return out_x, out_y

    def _convert_batch(
        self,
        source_x: np.ndarray,
        source_y: np.ndarray,
        out_x: Optional[np.ndarray] = None,
        out_y: Optional[np.ndarray] = None,
    ) -> tuple[np.ndarray, np.ndarray]:
        batch_scale = self.x_scale if not self.materialize_x else 1.0
        if out_x is None:
            batch_x = np.asarray(source_x, dtype=np.float32)
            if batch_scale != 1.0:
                batch_x = batch_x * np.float32(batch_scale)
        else:
            if out_x.shape != source_x.shape:
                raise ValueError(f"out_x shape {out_x.shape} does not match batch {source_x.shape}")
            np.copyto(out_x, source_x, casting="unsafe")
            if batch_scale != 1.0:
                np.multiply(out_x, np.float32(batch_scale), out=out_x)
            batch_x = out_x

        if out_y is None:
            batch_y = np.asarray(source_y)
        else:
            if out_y.shape != source_y.shape:
                raise ValueError(f"out_y shape {out_y.shape} does not match batch {source_y.shape}")
            np.copyto(out_y, source_y, casting="unsafe")
            batch_y = out_y
        return batch_x, batch_y

    def validation_arrays(self) -> tuple[np.ndarray, np.ndarray]:
        if self.val_x is not None and self.val_y is not None and len(self.val_x) > 0:
            if self.materialize_x:
                return self.val_x, self.val_y
            # Pictures kept as bytes: the validation set (much smaller than
            # the training set) is scaled once, the way every batch is.
            if self._val_scaled is None:
                self._val_scaled = self._convert_batch(self.val_x, self.val_y)[0]
            return self._val_scaled, self.val_y
        if self.materialize_x:
            return self.x, self.y
        return self._convert_batch(self.x, self.y)


def _normalize_targets(y: Any) -> np.ndarray:
    arr = np.asarray(y)
    if arr.ndim > 1 and arr.shape[-1] == 1:
        arr = arr.reshape((-1,))
    if arr.dtype.kind == "f":
        return arr.astype(np.float32)
    if arr.dtype.kind in {"i", "u", "b"}:
        if arr.ndim == 1:
            return arr.astype(np.int64)
        return arr.astype(np.float32)
    return arr.astype(np.int64)


def _load_meta(base: Path) -> Dict[str, Any]:
    meta_path = base / "meta.json"
    if not meta_path.exists():
        return {}
    with meta_path.open("r", encoding="utf-8") as f:
        return json.load(f)


def load_builtin_dataset(runtime_root: str | Path, name: str) -> ArrayDataset:
    base = Path(runtime_root) / "datasets" / name
    if not base.exists():
        raise FileNotFoundError(
            f"Builtin dataset '{name}' is not installed at {base}. "
            "Expected train.npz or train_x.npy/train_y.npy."
        )

    meta = _load_meta(base)

    train_npz = base / "train.npz"
    if train_npz.exists():
        with np.load(train_npz, allow_pickle=False) as data:
            x = data["x"] if "x" in data else data["train_x"]
            y = data["y"] if "y" in data else data["train_y"]
            val_x = data["val_x"] if "val_x" in data else (data["test_x"] if "test_x" in data else None)
            val_y = data["val_y"] if "val_y" in data else (data["test_y"] if "test_y" in data else None)
        if x.dtype == np.uint8:
            # Pictures shipped as bytes (CIFAR-10 is 184 MB so, 737 MB as
            # float32) stay bytes in memory; each batch becomes 0..1.
            return ArrayDataset(name=name, x=x, y=y, val_x=val_x, val_y=val_y, meta=meta,
                                materialize_x=False, x_scale=1.0 / 255.0)
        return ArrayDataset(name=name, x=x, y=y, val_x=val_x, val_y=val_y, meta=meta)

    x_path = base / "train_x.npy"
    y_path = base / "train_y.npy"
    if not x_path.exists() or not y_path.exists():
        # CIFAR-10 is not in git: a checkout builds it once before running the app.
        raise FileNotFoundError(
            f"Builtin dataset '{name}' is not built: {base} has no train.npz "
            f"(or {x_path.name} and {y_path.name}). Build it with "
            f"python local_runtime/tools/build_builtin_datasets.py {name}"
        )

    val_x = np.load(base / "val_x.npy", allow_pickle=False) if (base / "val_x.npy").exists() else None
    val_y = np.load(base / "val_y.npy", allow_pickle=False) if (base / "val_y.npy").exists() else None
    test_x = np.load(base / "test_x.npy", allow_pickle=False) if (base / "test_x.npy").exists() else None
    test_y = np.load(base / "test_y.npy", allow_pickle=False) if (base / "test_y.npy").exists() else None

    return ArrayDataset(
        name=name,
        x=np.load(x_path, allow_pickle=False),
        y=np.load(y_path, allow_pickle=False),
        val_x=val_x if val_x is not None else test_x,
        val_y=val_y if val_y is not None else test_y,
        meta=meta,
    )


def load_godot_json_dataset(path: str | Path, name: str = "") -> ArrayDataset:
    dataset_path = Path(path)
    if not dataset_path.exists():
        raise FileNotFoundError(f"Local Godot dataset JSON does not exist: {dataset_path}")

    with dataset_path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    x = data.get("x")
    y = data.get("y")
    if x is None or y is None:
        raise ValueError(f"Local Godot dataset JSON is missing x/y arrays: {dataset_path}")

    dataset_name = name or str(data.get("name") or dataset_path.stem)
    return ArrayDataset(
        name=dataset_name,
        x=np.asarray(x, dtype=np.float32),
        y=np.asarray(y),
        meta=data.get("meta") or {},
    )
