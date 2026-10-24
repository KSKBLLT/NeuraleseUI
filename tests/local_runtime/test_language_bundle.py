from pathlib import Path
import json
import os

import pytest

from neuralese_local.language.model_bundle import load_bundle


KIT = Path(os.environ.get("NEURALESE_LANGUAGE_MODEL_DIR", Path.home() / ".cache/neuralese-language-models/exports/Neuralese-Model-Kit-20261020"))


@pytest.mark.parametrize("suffix", ["", "models/clean1000", "onnx/clean1000"])
def test_checkpoint_directory_resolves_real_model_and_tokenizer(suffix):
    bundle = load_bundle(KIT / suffix)
    assert bundle.vocab_size == 20002
    assert (bundle.layers, bundle.width, bundle.heads, bundle.kv_heads) == (10, 256, 4, 2)
    assert bundle.decoder.is_file() and bundle.tokenizer.is_file()
    assert len(bundle.source_hash) == 64


def test_bundle_rejects_unsupported_head_geometry(tmp_path):
    (tmp_path / "config.json").write_text(json.dumps({"vocab_size": 20002, "hidden_size": 256, "num_hidden_layers": 10, "num_attention_heads": 3, "num_key_value_heads": 2, "head_dim": 64}))
    with pytest.raises(ValueError, match="head"):
        load_bundle(tmp_path)


def test_missing_checkpoint_is_an_error(tmp_path):
    with pytest.raises((ValueError, FileNotFoundError)):
        load_bundle(tmp_path)
