"""Publish existing ONNX values, keeping every original operator and weight."""
from __future__ import annotations

import json
import os
from pathlib import Path
import onnx
from onnx import TensorProto, helper

from .model_bundle import ModelBundle


TRACE_VERSION = 1


def ensure_trace_model(bundle: ModelBundle, cache_dir: Path | None = None) -> tuple[Path, dict]:
    base = cache_dir or Path(os.environ.get("NEURALESE_LANGUAGE_CACHE_DIR", Path.home() / ".cache/neuralese-language-models/runtime"))
    directory = base / f"{bundle.source_hash}-trace{TRACE_VERSION}"
    target, manifest_file = directory / "decoder-trace.onnx", directory / "trace.json"
    if target.is_file() and manifest_file.is_file():
        manifest = json.loads(manifest_file.read_text())
        if manifest.get("source_hash") == bundle.source_hash and manifest.get("version") == TRACE_VERSION:
            return target, manifest
    directory.mkdir(parents=True, exist_ok=True)
    model = onnx.load(bundle.decoder)
    nodes = list(model.graph.node)
    embedding = next((n.output[0] for n in nodes if n.op_type == "Gather" and len(n.input) > 1 and n.input[1] == "input_ids"), None)
    attentions = [n for n in nodes if n.op_type == "Softmax"]
    hidden = [n.output[0] for n in nodes if n.op_type == "Add" and any("/mlp/down_proj" in value for value in n.input)]
    if embedding is None or len(attentions) != bundle.layers or len(hidden) != bundle.layers:
        raise ValueError("This ONNX layout cannot expose verified attention/block outputs")
    outputs = {"embeddings": embedding, "attention": [], "head_outputs": [], "hidden": hidden}
    for attention in attentions:
        value = attention.output[0]
        outputs["attention"].append(value)
        while True:
            consumers = [n for n in nodes if n.input and n.input[0] == value]
            matmul = next((n for n in consumers if n.op_type == "MatMul"), None)
            if matmul is not None:
                outputs["head_outputs"].append(matmul.output[0])
                break
            passthrough = next((n for n in consumers if n.op_type in {"Cast", "Identity"}), None)
            if passthrough is None:
                raise ValueError("Cannot locate the real attention-weighted values")
            value = passthrough.output[0]
    existing = {v.name for v in model.graph.output}
    shapes = [(embedding, ["batch", "query", bundle.width])]
    shapes += [(name, ["batch", bundle.heads, "query", "key"]) for name in outputs["attention"]]
    shapes += [(name, ["batch", bundle.heads, "query", bundle.head_dim]) for name in outputs["head_outputs"]]
    shapes += [(name, ["batch", "query", bundle.width]) for name in hidden]
    for name, shape in shapes:
        if name not in existing:
            model.graph.output.append(helper.make_tensor_value_info(name, TensorProto.FLOAT, shape))
            existing.add(name)
    onnx.checker.check_model(model)
    temporary = target.with_name(f"decoder-trace.{os.getpid()}.tmp.onnx")
    onnx.save(model, temporary)
    os.replace(temporary, target)
    manifest = {"version": TRACE_VERSION, "source_hash": bundle.source_hash, "outputs": outputs}
    temp_manifest = manifest_file.with_suffix(f".{os.getpid()}.tmp")
    temp_manifest.write_text(json.dumps(manifest, indent=2))
    os.replace(temp_manifest, manifest_file)
    return target, manifest
