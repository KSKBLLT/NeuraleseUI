"""Research only: verify physical MLP export, lossless deduplication and ORT PTQ.

Run after compression_study.py. All derived ONNX files stay below --cache.
This does not replace the checkpoint or enable profiles in Neuralese.
"""
from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path
import shutil
import statistics
import sys
import time

import numpy as np
import onnx
from onnx import helper, numpy_helper
import onnxruntime as ort
import torch
import torch.nn.functional as F

from tools.language_models.compression_study import grade, restore_candidate, sha256


def session(path):
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    return ort.InferenceSession(str(path), sess_options=options, providers=["CPUExecutionProvider"])


def forward(engine, ids, cache=None):
    names = [v.name for v in engine.get_inputs()]
    layers = (len(names) - 3) // 2
    ids = np.array([ids], np.int64)
    cache = cache if cache is not None else [np.zeros((1, 2, 0, 64), np.float32) for _ in range(2 * layers)]
    past = cache[0].shape[2]
    feed = dict(zip(names, [ids, np.ones((1, past + ids.shape[1]), np.int64),
                            np.arange(past, past + ids.shape[1], dtype=np.int64)[None], *cache]))
    result = engine.run(None, feed)
    return result[0], result[1:1 + 2 * layers]


def quality(engine, teacher, rows, tok):
    total = kl = agreed = count = correct = 0
    details = []
    for row in rows:
        logits, _ = forward(engine, row["full_ids"])
        reference, _ = forward(teacher, row["full_ids"])
        start = len(row["prompt_ids"]) - 1
        actual = torch.from_numpy(logits[0, start:-1]).float()
        expected = torch.from_numpy(reference[0, start:-1]).float()
        labels = torch.tensor(row["full_ids"][start + 1:])
        total += float(F.cross_entropy(actual, labels, reduction="sum"))
        a, e = actual.log_softmax(-1), expected.log_softmax(-1)
        kl += float((e.exp() * (e - a)).sum())
        agreed += int((actual.argmax(-1) == expected.argmax(-1)).sum())
        count += len(labels)
        generated = []
        current = row["prompt_ids"]
        cache = None
        for _ in range(192):
            value, cache = forward(engine, current, cache)
            token = int(value[0, -1].argmax())
            if token == tok.eos_token_id:
                break
            generated.append(token)
            current = [token]
        text = tok.decode(generated, skip_special_tokens=True)
        passed = bool(grade(row, text))
        correct += int(passed)
        details.append(dict(id=row["id"], skill=row["skill"], correct=passed, output=text, generated_tokens=len(generated)))
    return dict(nll=total / count, teacher_kl=kl / count, teacher_top1_agreement=agreed / count,
                correct=correct, tasks=len(rows), assistant_tokens=count, examples=details)


def timings(engine, token_ids):
    result = {}
    sequence = (token_ids * (160 // len(token_ids) + 1))[:160]
    for length in (32, 128):
        for _ in range(3):
            forward(engine, sequence[:length])
        values = []
        for _ in range(12):
            start = time.perf_counter()
            forward(engine, sequence[:length])
            values.append((time.perf_counter() - start) * 1000)
        result[f"prefill_{length}_median_ms"] = statistics.median(values)
        result[f"prefill_{length}_p95_ms"] = float(np.percentile(values, 95))
    values = []
    for _ in range(8):
        _, cache = forward(engine, sequence[:128])
        start = time.perf_counter()
        # Exactly the same 32 teacher-forced decode tokens for every model;
        # early EOS and a shorter answer cannot manufacture a speedup.
        for token in sequence[128:160]:
            _, cache = forward(engine, [token], cache)
        values.append((time.perf_counter() - start) * 1000)
    result["decode_32_median_ms"] = statistics.median(values)
    result["decode_32_p95_ms"] = float(np.percentile(values, 95))
    return result


def deduplicate(source, output):
    model = onnx.load(source)
    embedding = next(t for t in model.graph.initializer if list(t.dims) == [20002, 256])
    head = next(t for t in model.graph.initializer if list(t.dims) == [256, 20002])
    assert np.array_equal(numpy_helper.to_array(embedding).T, numpy_helper.to_array(head))
    model.graph.initializer.remove(head)
    model.graph.node.insert(0, helper.make_node("Transpose", [embedding.name], [head.name], perm=[1, 0], name="SharedTiedOutputWeights"))
    onnx.checker.check_model(model)
    onnx.save(model, output)


def export_mlp(original, checkpoint, path, kit):
    from export_onnx import CachedDecoder, empty_cache
    model, _ = restore_candidate(original, checkpoint)
    c = model.config
    (path.parent / "config.json").write_text(c.to_json_string(), encoding="utf-8")
    inputs = ["input_ids", "attention_mask", "position_ids"] + [f"past_{i}_{kind}" for i in range(c.num_hidden_layers) for kind in ("key", "value")]
    outputs = ["logits"] + [f"present_{i}_{kind}" for i in range(c.num_hidden_layers) for kind in ("key", "value")]
    dynamic = {name: {0: "batch", 1: "sequence"} for name in inputs[:3] + ["logits"]}
    dynamic["attention_mask"] = {0: "batch", 1: "total_sequence"}
    for name in inputs[3:]:
        dynamic[name] = {0: "batch", 2: "past_sequence"}
    for name in outputs[1:]:
        dynamic[name] = {0: "batch", 2: "total_sequence"}
    sample = torch.tensor([[21, 32, 43]])
    torch.onnx.export(CachedDecoder(model).eval(), (sample, torch.ones_like(sample), torch.arange(3)[None], *empty_cache(c)),
                      str(path), input_names=inputs, output_names=outputs, dynamic_axes=dynamic, opset_version=17, dynamo=False)
    engine = session(path)
    checks = []
    for length in (1, 32, 128):
        ids = (torch.arange(length) % 800 + 3)[None]
        actual, cache = forward(engine, ids[0].tolist())
        expected = model(ids, use_cache=False).logits.numpy()
        np.testing.assert_allclose(actual, expected, rtol=5e-4, atol=5e-4)
        tail = [33, 34]
        actual, _ = forward(engine, tail, cache)
        expected = model(torch.cat([ids, torch.tensor([tail])], 1), use_cache=False).logits[:, -2:].numpy()
        np.testing.assert_allclose(actual, expected, rtol=5e-4, atol=5e-4)
        checks.append(dict(prefill_tokens=length, cached_tokens=2, max_abs=float(np.max(np.abs(actual - expected)))))
    return checks


def trace_check(path, source_bundle, cache):
    """Probe the existing Neuralese trace adapter without changing production."""
    from neuralese_local.language.model_bundle import load_bundle
    from neuralese_local.language.trace_model import ensure_trace_model
    for name in ("config.json", "tokenizer.json", "chat_template.jinja"):
        if not (path.parent / name).exists():
            shutil.copyfile(source_bundle / name, path.parent / name)
    try:
        traced, outputs = ensure_trace_model(load_bundle(path.parent), cache_dir=cache)
        engine = session(traced)
        base, _ = forward(session(path), [21, 32, 43])
        actual, _ = forward(engine, [21, 32, 43])
        np.testing.assert_allclose(actual, base, rtol=1e-6, atol=1e-6)
        names = [item.name for item in engine.get_inputs()]
        feed = dict(zip(names, [np.array([[21, 32, 43]], np.int64), np.ones((1, 3), np.int64),
                               np.arange(3, dtype=np.int64)[None], *[np.zeros((1, 2, 0, 64), np.float32) for _ in names[3:]]]))
        maps = engine.run(outputs["outputs"]["attention"], feed)
        for value in maps:
            assert value.shape == (1, 4, 3, 3) and np.isfinite(value).all()
            np.testing.assert_allclose(value.sum(-1), 1, atol=2e-6)
            np.testing.assert_allclose(np.triu(value, k=1), 0, atol=1e-8)
        return dict(ok=True, attention_layers=len(maps), heads_per_layer=4, normalized_causal_attention=True)
    except Exception as error:
        return dict(ok=False, error=str(error))


@torch.inference_mode()
def run(args):
    torch.set_num_threads(2)
    torch.set_num_interop_threads(1)
    sys.path.insert(0, str(args.kit / "scripts"))
    from model_io import load_model, load_tokenizer
    from onnxruntime.quantization import QuantType, quantize_dynamic
    from onnxruntime.quantization.matmul_4bits_quantizer import MatMul4BitsQuantizer
    logging.getLogger().setLevel(logging.WARNING)
    study = json.loads(args.study.read_text())
    source = args.kit / "onnx/clean1000/decoder.onnx"
    source_hash = sha256(source)
    args.cache.mkdir(parents=True, exist_ok=True)
    paths = {}
    for name in ("original", "deduplicated", "mlp_896_ridge", "int8_matmul", "int8_matmul_gather", "int4_block32"):
        directory = args.cache / name
        directory.mkdir(exist_ok=True)
        paths[name] = directory / "decoder.onnx"
    shutil.copyfile(source, paths["original"])
    deduplicate(source, paths["deduplicated"])
    original = load_model(args.kit / "models/clean1000")
    checks = export_mlp(original, args.candidates / "mlp_896_ridge.pt", paths["mlp_896_ridge"], args.kit)
    del original
    for name, ops in (("int8_matmul", ["MatMul"]), ("int8_matmul_gather", ["MatMul", "Gather"])):
        quantize_dynamic(str(source), str(paths[name]), per_channel=True, weight_type=QuantType.QInt8, op_types_to_quantize=ops)
    quantizer = MatMul4BitsQuantizer(str(source), block_size=32, is_symmetric=True, accuracy_level=0)
    quantizer.process()
    onnx.save(quantizer.model.model, paths["int4_block32"])
    tok = load_tokenizer(args.kit / "models/clean1000")
    teacher = session(source)
    report = dict(scope="research_only_not_active_in_neuralese", source_sha256=source_hash, onnx=onnx.__version__,
                  onnxruntime=ort.__version__, provider="CPUExecutionProvider", threads=2,
                  mlp_export_checks=checks, benchmark="128-token prefill + fixed 32-token cached decode; no EOS shortcuts", candidates={})
    for name, path in paths.items():
        engine = session(path)
        result = dict(bytes=path.stat().st_size, sha256=sha256(path), quality=quality(engine, teacher, study["splits"]["test"], tok),
                      timing=timings(engine, study["splits"]["test"][0]["prompt_ids"]),
                      existing_trace_adapter=trace_check(path, source.parent, args.cache / "trace-cache"))
        report["candidates"][name] = result
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(dict(event="evaluated", candidate=name, bytes=result["bytes"], correct=result["quality"]["correct"],
                              nll=result["quality"]["nll"], timing=result["timing"], trace=result["existing_trace_adapter"])), flush=True)
    report["source_unchanged"] = sha256(source) == source_hash
    assert report["source_unchanged"]
    args.report.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--kit", type=Path, required=True)
    p.add_argument("--candidates", type=Path, required=True)
    p.add_argument("--cache", type=Path, required=True)
    p.add_argument("--study", type=Path, required=True)
    p.add_argument("--report", type=Path, required=True)
    run(p.parse_args())
