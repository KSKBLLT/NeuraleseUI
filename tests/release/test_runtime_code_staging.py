import importlib.util
import py_compile
import subprocess
import sys
from pathlib import Path

import pytest


TOOL = Path(__file__).resolve().parents[2] / "tools" / "stage_runtime_code.py"
spec = importlib.util.spec_from_file_location("stage_runtime_code", TOOL)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def test_staged_package_uses_fresh_bytecode_and_preserves_resources(tmp_path):
    source = tmp_path / "source"
    source.mkdir()
    (source / "__init__.py").write_text("VERSION = 'new-checkout'\n")
    (source / "old.pyc").write_bytes(b"stale bytecode")
    (source / "robot").mkdir()
    (source / "robot" / "__init__.py").write_text("")
    (source / "robot" / "template.tmpl").write_text("robot-template")
    runtime = tmp_path / "runtime"
    destination = runtime / "neuralese_local"
    destination.mkdir(parents=True)
    (destination / "obsolete.pyc").write_bytes(b"old installed module")
    fingerprint = module.stage_runtime_code(source, runtime)
    assert len(fingerprint) == 64
    assert not list(destination.rglob("*.py"))
    assert not (destination / "old.pyc").exists()
    assert not (destination / "obsolete.pyc").exists()
    result = subprocess.run(
        [sys.executable, "-I", "-c", "import sys; sys.path.insert(0, sys.argv[1]); "
         "import neuralese_local; from importlib.resources import files; "
         "print(neuralese_local.VERSION); "
         "print(files('neuralese_local.robot').joinpath('template.tmpl').read_text())", str(runtime)],
        capture_output=True, text=True, check=True, timeout=15,
    )
    assert result.stdout.splitlines() == ["new-checkout", "robot-template"]
    assert module.stage_runtime_code(source, runtime) == fingerprint
    (source / "__init__.py").write_text("VERSION = 'next-checkout'\n")
    assert module.stage_runtime_code(source, runtime) != fingerprint


def test_compile_error_does_not_replace_existing_package(tmp_path):
    source = tmp_path / "source"
    source.mkdir()
    (source / "__init__.py").write_text("def broken(\n")
    runtime = tmp_path / "runtime"
    destination = runtime / "neuralese_local"
    destination.mkdir(parents=True)
    marker = destination / "previous.pyc"
    marker.write_bytes(b"previous runtime")
    with pytest.raises(py_compile.PyCompileError):
        module.stage_runtime_code(source, runtime)
    assert marker.read_bytes() == b"previous runtime"
