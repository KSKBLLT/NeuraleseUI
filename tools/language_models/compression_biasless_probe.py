"""Research-only follow-up: biasless channel reconstruction + fresh held-out tasks.

The first ridge experiment introduced biases unsupported by the current trace
adapter. This tests a compatible algebraic reconstruction; no runtime changes.
All 80 fresh test groups are excluded from the earlier 120 selected groups.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

import torch

from tools.language_models.compression_study import (
    agreement, collect_activations, identity, load_splits, nll, parameter_count,
    restore_candidate, save_candidate, shrink_mlp, task_evaluation, write_report,
)
from tools.language_models.compression_onnx_probe import deduplicate, export_mlp, quality, session, timings, trace_check


@torch.inference_mode()
def run(args):
    torch.set_num_threads(2)
    torch.set_num_interop_threads(1)
    sys.path.insert(0, str(args.kit / "scripts"))
    from model_io import load_model, load_tokenizer
    study = json.loads(args.study.read_text())
    original = load_model(args.kit / "models/clean1000")
    original.requires_grad_(False)
    tok = load_tokenizer(args.kit / "models/clean1000")
    excluded = {identity(row) for rows in study["splits"].values() for row in rows}
    fresh = load_splits(args.kit, tok, counts=(("test", 8),), excluded_groups=excluded)["test"]
    assert not excluded.intersection(identity(row) for row in fresh)
    report = dict(scope="research_only_not_active_in_neuralese", reason="biasless ridge to retain existing trace compatibility",
                  excluded_previous_groups=len(excluded), fresh_test=fresh, candidates={}, finalists_fixed_before_fresh_test=["original", "mlp_896_ridge", "mlp_896_ridge_no_bias", "mlp_960_ridge_no_bias"])
    activations = collect_activations(original, study["splits"]["train"])
    for width in (896, 960):
        model, retained = shrink_mlp(original, width, activations, "ridge_no_bias")
        name = f"mlp_{width}_ridge_no_bias"
        save_candidate(model, args.candidates / f"{name}.pt", dict(layers=10, width=width, method="ridge_no_bias", retained_channels=retained))
        report["candidates"][name] = dict(parameters=parameter_count(model), width=width,
                                        validation_nll=nll(model, study["splits"]["validation"]),
                                        validation_tasks=task_evaluation(model, study["splits"]["validation"], tok))
        write_report(args.report, report)
    del activations
    for name in report["finalists_fixed_before_fresh_test"]:
        model = original if name == "original" else restore_candidate(original, args.candidates / f"{name}.pt")[0]
        row = report["candidates"].setdefault(name, dict(parameters=parameter_count(model)))
        row["fresh_nll"] = nll(model, fresh)
        row["fresh_tasks"] = task_evaluation(model, fresh, tok)
        row.update(agreement(model, original, fresh))
        if name.endswith("no_bias"):
            directory = args.cache / name
            directory.mkdir(parents=True, exist_ok=True)
            path = directory / "decoder.onnx"
            row["torch_onnx_checks"] = export_mlp(original, args.candidates / f"{name}.pt", path, args.kit)
            dedup = directory / "deduplicated.onnx"
            deduplicate(path, dedup)
            # Use the canonical basename expected by the existing trace adapter.
            path.unlink()
            dedup.replace(path)
            row["onnx_bytes"] = path.stat().st_size
            row["trace_adapter"] = trace_check(path, args.kit / "onnx/clean1000", args.cache / "trace-cache")
            assert row["trace_adapter"]["ok"], row["trace_adapter"]
            row["timing"] = timings(session(path), fresh[0]["prompt_ids"])
            row["fresh_onnx_quality"] = quality(session(path), session(args.kit / "onnx/clean1000/decoder.onnx"), fresh, tok)
        print(json.dumps(dict(event="fresh_evaluation", candidate=name, correct=row["fresh_tasks"]["correct"], count=len(fresh),
                              nll=row["fresh_nll"], parameters=row["parameters"], trace=row.get("trace_adapter"), bytes=row.get("onnx_bytes"))), flush=True)
        write_report(args.report, report)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit", type=Path, required=True)
    parser.add_argument("--study", type=Path, required=True)
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    run(parser.parse_args())
