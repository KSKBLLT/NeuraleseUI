from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict

from .dataset_store import ArrayDataset, load_builtin_dataset, load_godot_json_dataset


DEFAULT_USER_BUDGET_BYTES = 512 * 1024 * 1024


@dataclass(frozen=True)
class DatasetRevision:
    kind: str
    name: str
    path: str
    revision: str
    size: int
    mtime_ns: int


class TrainingDatasetCache:
    def __init__(
        self,
        runtime_root: str | Path,
        user_budget_bytes: int = DEFAULT_USER_BUDGET_BYTES,
    ) -> None:
        self.runtime_root = Path(runtime_root).resolve()
        self.user_budget_bytes = max(0, int(user_budget_bytes))
        self._builtins: Dict[str, ArrayDataset] = {}
        self._users: OrderedDict[DatasetRevision, ArrayDataset] = OrderedDict()
        self._user_bytes = 0

    def warm_builtins(self, runtime_root: str | Path | None = None) -> Dict[str, ArrayDataset]:
        if runtime_root is not None:
            self.runtime_root = Path(runtime_root).resolve()
        datasets_dir = self.runtime_root / "datasets"
        if not datasets_dir.exists():
            return dict(self._builtins)
        for path in sorted(datasets_dir.iterdir(), key=lambda item: item.name):
            if not path.is_dir() or path.name in self._builtins:
                continue
            if not (path / "train.npz").exists() and not (path / "train_x.npy").exists():
                # Not built here (a large one such as cifar10 may be built only
                # when the app is packaged): picking it reports it missing.
                continue
            self._builtins[path.name] = load_builtin_dataset(self.runtime_root, path.name)
        return dict(self._builtins)

    def get(self, dataset_ref: Dict[str, Any]) -> ArrayDataset:
        kind = str(dataset_ref.get("kind") or "")
        if kind == "builtin_numpy":
            name = str(dataset_ref.get("name") or "")
            if not name:
                raise ValueError("builtin dataset reference is missing name")
            dataset = self._builtins.get(name)
            if dataset is None:
                dataset = load_builtin_dataset(self.runtime_root, name)
                self._builtins[name] = dataset
            return dataset

        if kind == "godot_json":
            key = self._user_revision(dataset_ref)
            cached = self._users.pop(key, None)
            if cached is not None:
                self._users[key] = cached
                return cached

            self._remove_stale_path_entries(key.path)
            dataset = load_godot_json_dataset(key.path, name=key.name)
            dataset_bytes = self._dataset_bytes(dataset)
            if dataset_bytes <= self.user_budget_bytes:
                self._users[key] = dataset
                self._user_bytes += dataset_bytes
                self.evict_user_lru()
            return dataset

        raise ValueError(f"Unsupported local dataset kind: {kind}")

    def evict_user_lru(self) -> None:
        while self._users and self._user_bytes > self.user_budget_bytes:
            _, dataset = self._users.popitem(last=False)
            self._user_bytes -= self._dataset_bytes(dataset)

    def clear_users(self) -> None:
        self._users.clear()
        self._user_bytes = 0

    @staticmethod
    def _dataset_bytes(dataset: ArrayDataset) -> int:
        arrays = (dataset.x, dataset.y, dataset.val_x, dataset.val_y)
        return sum(int(array.nbytes) for array in arrays if array is not None)

    @staticmethod
    def _user_revision(dataset_ref: Dict[str, Any]) -> DatasetRevision:
        raw_path = str(dataset_ref.get("path") or "")
        if not raw_path:
            raise ValueError("Godot dataset reference is missing path")
        path = Path(raw_path).resolve()
        stat = path.stat()
        return DatasetRevision(
            kind="godot_json",
            name=str(dataset_ref.get("name") or ""),
            path=str(path),
            revision=str(dataset_ref.get("revision") or ""),
            size=int(stat.st_size),
            mtime_ns=int(stat.st_mtime_ns),
        )

    def _remove_stale_path_entries(self, path: str) -> None:
        stale = [key for key in self._users if key.path == path]
        for key in stale:
            dataset = self._users.pop(key)
            self._user_bytes -= self._dataset_bytes(dataset)
