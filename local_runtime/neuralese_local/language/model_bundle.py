from __future__ import annotations

from dataclasses import dataclass
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path


@lru_cache(maxsize=16)
def _digest(path: str, size: int, modified: int) -> str:
    value = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def file_hash(path: Path) -> str:
    stat = path.stat()
    return _digest(str(path.resolve()), stat.st_size, stat.st_mtime_ns)


@dataclass(frozen=True)
class ModelBundle:
    root: Path
    decoder: Path
    tokenizer: Path
    config: dict
    source_hash: str
    vocab_size: int
    layers: int
    width: int
    heads: int
    kv_heads: int
    head_dim: int
    max_context: int = 512

    @property
    def model_id(self) -> str:
        return "clean1000-" + self.source_hash[:16]


def default_model_path() -> Path:
    configured = os.environ.get("NEURALESE_LANGUAGE_MODEL_DIR")
    if configured:
        return Path(configured).expanduser()
    packaged = Path(__file__).resolve().parents[2] / "models" / "clean1000"
    if packaged.is_dir():
        return packaged
    raise FileNotFoundError("В local_runtime отсутствует комплект языковой модели. Переустановите Neuralese.")


def load_bundle(path: Path | str | None = None) -> ModelBundle:
    root = Path(path).expanduser().resolve() if path is not None else default_model_path()
    if (root / "onnx/clean1000/decoder.onnx").is_file():
        root = root / "onnx/clean1000"
    elif (root / "model.safetensors").is_file() and not (root / "decoder.onnx").exists():
        root = root.parent.parent / "onnx" / root.name
    cfg_path = root / "config.json"
    if not cfg_path.is_file():
        raise FileNotFoundError(f"Не найдена конфигурация языковой модели: {root}")
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    width = int(cfg.get("hidden_size", 0))
    heads = int(cfg.get("num_attention_heads", 0))
    kv = int(cfg.get("num_key_value_heads", 0))
    head_dim = int(cfg.get("head_dim", 0))
    if heads < 1 or kv < 1 or heads % kv or width != heads * head_dim:
        raise ValueError("Unsupported attention head geometry")
    layers = int(cfg.get("num_hidden_layers", 0))
    vocabulary = int(cfg.get("vocab_size", 0))
    if layers < 1 or vocabulary < 2 or cfg.get("use_sliding_window", False):
        raise ValueError("Unsupported language model configuration")
    decoder, tokenizer = root / "decoder.onnx", root / "tokenizer.json"
    for resource in (decoder, tokenizer):
        if not resource.is_file():
            raise FileNotFoundError(f"Не найден файл модели: {resource}")
    digest = file_hash(decoder)
    manifest_path = root / "language_bundle.json"
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if manifest.get("schema_version") != 1 or manifest.get("source_hash") != digest:
            raise ValueError("Language model manifest/hash mismatch")
        files = manifest.get("files", {})
        if files and not {"decoder.onnx", "tokenizer.json", "config.json", "chat_template.jinja"} <= files.keys():
            raise ValueError("Language model manifest is incomplete")
        for name, record in files.items():
            resource = root / name
            if Path(name).name != name or not resource.is_file() or resource.stat().st_size != record.get("size") or file_hash(resource) != record.get("sha256"):
                raise ValueError(f"Language model manifest/hash mismatch: {name}")
    return ModelBundle(root, decoder, tokenizer, cfg, digest, vocabulary, layers, width, heads, kv, head_dim)
