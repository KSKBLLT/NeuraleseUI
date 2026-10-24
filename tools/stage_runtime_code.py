"""Compile checkout code with the destination runtime's Python interpreter."""
from __future__ import annotations

import argparse
import hashlib
import py_compile
import shutil
import tempfile
from pathlib import Path


def stage_runtime_code(source: Path, runtime: Path) -> str:
    source = source.resolve()
    runtime = runtime.resolve()
    destination = runtime / "neuralese_local"
    if not (source / "__init__.py").is_file():
        raise ValueError(f"Runtime source package is missing: {source}")
    if source == destination or source.is_relative_to(destination):
        raise ValueError("Runtime source and destination must be separate")
    digest = hashlib.sha256()
    with tempfile.TemporaryDirectory(prefix=".runtime-code-", dir=runtime) as directory:
        compiled = Path(directory) / "neuralese_local"
        compiled.mkdir()
        for path in sorted(source.rglob("*")):
            relative = path.relative_to(source)
            if not path.is_file() or "__pycache__" in relative.parts or path.suffix in {".pyc", ".pyo"} or path.name == ".DS_Store":
                continue
            digest.update(relative.as_posix().encode("utf-8") + b"\0" + path.read_bytes() + b"\0")
            target = compiled / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if path.suffix == ".py":
                py_compile.compile(str(path), cfile=str(target.with_suffix(".pyc")),
                                   dfile="neuralese_local/" + relative.as_posix(), doraise=True,
                                   invalidation_mode=py_compile.PycInvalidationMode.CHECKED_HASH)
            else:
                shutil.copy2(path, target)
        if destination.exists():
            shutil.rmtree(destination)
        compiled.replace(destination)
    return digest.hexdigest()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("runtime", type=Path)
    args = parser.parse_args()
    print(stage_runtime_code(args.source, args.runtime))
