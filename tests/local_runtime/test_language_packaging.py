import json
import os
from pathlib import Path

import pytest

from neuralese_local.language.model_bundle import load_bundle
from tools.language_models.prepare_bundle import prepare_bundle

KIT = Path(os.environ.get("NEURALESE_LANGUAGE_MODEL_DIR", Path.home() / ".cache/neuralese-language-models/exports/Neuralese-Model-Kit-20261020"))
if not KIT.is_dir():
    KIT = Path(__file__).resolve().parents[2] / "local_runtime/models/clean1000"


def test_required_inference_assets_are_not_gitignored():
    import subprocess
    root = Path(__file__).resolve().parents[2]
    names = ["decoder.onnx", "tokenizer.json", "config.json", "chat_template.jinja", "language_bundle.json"]
    paths = ["local_runtime/models/clean1000/" + name for name in names]
    # Bytes, not text: text-mode stdin turns \n into \r\n on Windows, and git then
    # checks paths ending in \r, which the clean1000/* ignore rule matches.
    result = subprocess.run(["git", "check-ignore", "--no-index", "--stdin"],
                            input=("\n".join(paths) + "\n").encode(), cwd=root, capture_output=True)
    assert result.returncode in (0, 1), result.stderr
    assert not result.stdout.strip(), "Required inference assets would disappear after pull: " + result.stdout.decode()


def test_git_preserves_exact_manifested_bytes_on_windows():
    import subprocess
    root = Path(__file__).resolve().parents[2]
    paths = ["local_runtime/models/clean1000/config.json", "local_runtime/models/clean1000/chat_template.jinja",
             "local_runtime/language_vendor/windows-x64/tokenizers/__init__.py"]
    result = subprocess.run(["git", "check-attr", "text", "--", *paths], cwd=root, text=True, capture_output=True, check=True)
    assert all(line.endswith(": text: unset") for line in result.stdout.splitlines()), result.stdout


def test_portable_bundle_contains_only_inference_assets_and_verifies_all_hashes(tmp_path):
    output = tmp_path / "runtime/models/clean1000"
    manifest = prepare_bundle(KIT, output)
    assert load_bundle(output).source_hash == load_bundle(KIT).source_hash
    assert {"decoder.onnx", "tokenizer.json", "config.json", "chat_template.jinja"} <= manifest["files"].keys()
    assert not list(output.rglob("*.safetensors")) and not list(output.rglob("*.py"))
    assert str(Path.home()) not in json.dumps(manifest)
    (output / "tokenizer.json").write_text("{}")
    with pytest.raises(ValueError, match="hash|manifest"):
        load_bundle(output)


def test_bundle_worker_runs_from_compiled_package_without_torch(tmp_path):
    from tools.stage_runtime_code import stage_runtime_code
    import subprocess
    import sys
    import shutil

    runtime = tmp_path / "runtime"
    prepare_bundle(KIT, runtime / "models/clean1000")
    stage_runtime_code(Path(__file__).resolve().parents[2] / "local_runtime/neuralese_local", runtime)
    shutil.copytree(Path(__file__).resolve().parents[2] / "local_runtime/language_vendor", runtime / "language_vendor")
    result = subprocess.run([sys.executable, "-I", "-c", "import sys; sys.path.insert(0, sys.argv[1]); "
        "from neuralese_local.language.engine import LanguageEngine; "
        "engine=LanguageEngine(); print(engine.bundle.vocab_size); "
        "assert 'torch' not in sys.modules; assert 'transformers' not in sys.modules; "
        "assert 'huggingface_hub' not in sys.modules; "
        "from pathlib import Path; "
        "assert all(Path(sys.modules[n].__file__).resolve().is_relative_to(Path(sys.argv[1])) for n in ('tokenizers','jinja2','markupsafe'))", str(runtime)],
        capture_output=True, text=True, timeout=30, check=True, env={k:v for k,v in os.environ.items() if k != "NEURALESE_LANGUAGE_MODEL_DIR"})
    assert result.stdout.strip() == "20002"
