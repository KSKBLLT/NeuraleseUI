"""Fails when a builtin dataset the app trains on is missing.

Every dataset the app lists (FULLY_LOCAL_DATASET_NAMES in scripts/run_manager.gd)
and every folder under the datasets directory must hold its training arrays:
train.npz with x and y, or train_x.npy and train_y.npy.

Some datasets are too large for git (CIFAR-10's train.npz is 170 MB, GitHub
refuses files over 100 MB), so each checkout builds them once with
local_runtime/tools/build_builtin_datasets.py. Every script that packages the
runtime, and every CI build, runs this check first, so an app is never built
without them.

Standard library only: it runs on any Python, including a packaged runtime's.
"""
from __future__ import annotations

import argparse
import re
import sys
import zipfile
from pathlib import Path

RUNTIME_ROOT = Path(__file__).resolve().parents[1]
PROJECT_ROOT = RUNTIME_ROOT.parent

# Not in git: built on each checkout, and what building downloads.
BUILT_ON_CHECKOUT = {
    "cifar10": "downloads the official CIFAR-10 archive, 162 MB, from www.cs.toronto.edu",
}


def app_dataset_names(project_root: Path) -> list[str]:
    source = project_root / "scripts" / "run_manager.gd"
    if not source.is_file():
        return []
    block = re.search(r"FULLY_LOCAL_DATASET_NAMES\s*:=\s*\{(.*?)\}", source.read_text(encoding="utf-8"), re.S)
    return re.findall(r'"([^"]+)"\s*:', block.group(1)) if block else []


def has_training_arrays(base: Path) -> bool:
    archive_path = base / "train.npz"
    if archive_path.is_file():
        try:
            with zipfile.ZipFile(archive_path) as archive:
                names = set(archive.namelist())
        except zipfile.BadZipFile:
            return False
        return {"x.npy", "y.npy"} <= names or {"train_x.npy", "train_y.npy"} <= names
    return (base / "train_x.npy").is_file() and (base / "train_y.npy").is_file()


def missing_datasets(datasets: Path, project_root: Path = PROJECT_ROOT) -> list[str]:
    names = set(app_dataset_names(project_root))
    if datasets.is_dir():
        names.update(path.name for path in datasets.iterdir()
                     if path.is_dir() and not path.name.startswith((".", "_")))
    return sorted(name for name in names if not has_training_arrays(datasets / name))


def explain(missing: list[str], datasets: Path) -> str:
    lines = [f"Builtin datasets are missing from {datasets}: {', '.join(missing)}.",
             "The app ships every builtin dataset; build them before building the app."]
    built = [name for name in missing if name in BUILT_ON_CHECKOUT]
    if built:
        lines.append("From the repository root, with a Python that has numpy (local_runtime/python/python.exe has it):")
        lines.append(f"    python local_runtime/tools/build_builtin_datasets.py {' '.join(built)}")
        lines.extend(f"  {name}: {BUILT_ON_CHECKOUT[name]}." for name in built)
    for name in missing:
        if name not in BUILT_ON_CHECKOUT:
            lines.append(f"  {name} comes with the repository: git checkout -- local_runtime/datasets/{name}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Check that every builtin dataset the app trains on is present.")
    parser.add_argument("--datasets", type=Path, default=RUNTIME_ROOT / "datasets",
                        help="the datasets folder to check, e.g. a packaged copy (default: local_runtime/datasets)")
    parser.add_argument("--project-root", type=Path, default=PROJECT_ROOT,
                        help="the checkout whose scripts/run_manager.gd lists the datasets")
    args = parser.parse_args(argv)
    missing = missing_datasets(args.datasets, args.project_root)
    if missing:
        print(explain(missing, args.datasets), file=sys.stderr)
        return 1
    print(f"Builtin datasets are complete in {args.datasets}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
