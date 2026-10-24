"""Measure pruning/merging on this checkpoint rather than assuming redundancy.

Run with the model kit's development Python. No input file is modified.
"""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import sys
import time

import numpy as np


CALIBRATION = [
    "The cat sat on the mat. The dog ran to the door.",
    "A bird sat in a tree and watched the sun.",
    "A mother and a father helped their child.",
    "A king and a queen lived in a castle.",
    "The little boy put his blue cup on the table.",
    "Two children played with a red ball in the park.",
]
HELDOUT = [
    "Lily went to the park with her friend. They played a game and went home.",
    "Tom has three red balls and two blue balls. He has five balls.",
    "The cup is on the table. The table is next to the chair.",
]
TASKS = [("Add 26 and 49.", "75"), ("Copy exactly: red cup", "red cup"), ("Mia has a red bag. What color is it?", "red")]


def interpolate_weights(a: np.ndarray, b: np.ndarray, t: float, method: str) -> np.ndarray:
    linear = (1 - t) * a + t * b
    if method == "lerp":
        return linear
    norm_a, norm_b = np.linalg.norm(a), np.linalg.norm(b)
    if norm_a < 1e-12 or norm_b < 1e-12:
        return linear
    cosine = float(np.clip(np.vdot(a.ravel(), b.ravel()) / (norm_a * norm_b), -1, 1))
    if abs(cosine) > 0.9995:
        return linear
    angle = np.arccos(cosine)
    return (np.sin((1 - t) * angle) * a + np.sin(t * angle) * b) / np.sin(angle)


def calibrate(kit: Path, output: Path) -> dict:
    import torch
    import torch.nn.functional as functional
    sys.path.insert(0, str(kit / "scripts"))
    from model_io import load_model, load_tokenizer
    torch.set_num_threads(2)
    model = load_model(kit / "models/clean1000")
    tokenizer = load_tokenizer(kit / "models/clean1000")
    count = len(model.model.layers)
    influence = [[] for _ in range(count)]

    def capture(index):
        def hook(module, inputs, result):
            value = result[0] if isinstance(result, tuple) else result
            influence[index].append(float((1 - functional.cosine_similarity(inputs[0].float(), value.float(), dim=-1)).mean()))
        return hook

    handles = [layer.register_forward_hook(capture(i)) for i, layer in enumerate(model.model.layers)]
    with torch.no_grad():
        for text in CALIBRATION:
            model(tokenizer(text, return_tensors="pt").input_ids, use_cache=False)
    for handle in handles:
        handle.remove()
    scores = [sum(values) / len(values) for values in influence]
    reference = []
    with torch.no_grad():
        for text in HELDOUT:
            ids = tokenizer(text, return_tensors="pt").input_ids
            reference.append((ids, model(ids, use_cache=False).logits.float()))

    def measure(candidate):
        started = time.monotonic()
        losses, divergences, agreements = [], [], []
        with torch.no_grad():
            for ids, golden in reference:
                logits = candidate(ids, use_cache=False).logits.float()
                losses.append(float(functional.cross_entropy(logits[:, :-1].reshape(-1, logits.shape[-1]), ids[:, 1:].reshape(-1))))
                divergences.append(float(functional.kl_div(logits.log_softmax(-1), golden.softmax(-1), reduction="none").sum(-1).mean()))
                agreements.append(float((logits.argmax(-1) == golden.argmax(-1)).float().mean()))
            task_outputs, correct = [], 0
            for prompt, expected in TASKS:
                ids = torch.tensor([tokenizer.apply_chat_template([{"role": "user", "content": prompt}], add_generation_prompt=True)])
                generated = candidate.generate(ids, max_new_tokens=96, do_sample=False, use_cache=False, pad_token_id=candidate.config.pad_token_id, eos_token_id=candidate.config.eos_token_id)
                text = tokenizer.decode(generated[0, ids.shape[1]:], skip_special_tokens=True)
                task_outputs.append({"prompt": prompt, "expected": expected, "actual": text})
                correct += expected in text.lower()
        return {"nll": float(np.mean(losses)), "teacher_kl": float(np.mean(divergences)), "top1_agreement": float(np.mean(agreements)), "task_accuracy": correct / len(TASKS), "seconds": time.monotonic() - started, "task_outputs": task_outputs}

    baseline = measure(model)
    results = []
    for depth in (2, 4, 6):
        for method in ("prune", "lerp", "slerp"):
            candidate = copy.deepcopy(model)
            if method == "prune":
                selected = sorted({0, count - 1} | set(sorted(range(1, count - 1), key=lambda i: scores[i], reverse=True)[:depth - 2]))
                candidate.model.layers = torch.nn.ModuleList([candidate.model.layers[i] for i in selected])
            else:
                groups = [list(map(int, group)) for group in np.array_split(np.arange(count), depth)]
                merged = []
                for group in groups:
                    layer = copy.deepcopy(model.model.layers[int(group[0])])
                    state = layer.state_dict()
                    for index, original in enumerate(group[1:], 2):
                        following = model.model.layers[int(original)].state_dict()
                        state = {key: torch.from_numpy(interpolate_weights(state[key].numpy(), following[key].numpy(), 1 / index, method)).to(state[key].dtype) for key in state}
                    layer.load_state_dict(state)
                    merged.append(layer)
                selected = groups
                candidate.model.layers = torch.nn.ModuleList(merged)
            candidate.config.num_hidden_layers = depth
            candidate.config.layer_types = ["full_attention"] * depth
            for i, layer in enumerate(candidate.model.layers):
                layer.self_attn.layer_idx = i
            metrics = measure(candidate)
            passed = metrics["nll"] <= baseline["nll"] * 1.2 and metrics["top1_agreement"] >= .8 and metrics["task_accuracy"] >= baseline["task_accuracy"] * .95
            result = {"id": f"{method}-{depth}", "layers": depth, "method": method, "source_layers": selected, "quality_passed": passed, "metrics": metrics}
            results.append(result)
            print(json.dumps({"profile": result["id"], "quality_passed": passed, "nll": metrics["nll"], "agreement": metrics["top1_agreement"]}), flush=True)
            del candidate
    report = {"schema_version": 1, "calibration": CALIBRATION, "heldout": HELDOUT, "block_influence": scores, "baseline": baseline, "candidates": results, "selected": {str(n): "identity" for n in (2, 4, 6)}, "note": "A passing candidate still needs a verified exported artifact before it can be selected."}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False))
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    calibrate(arguments.kit, arguments.output)
