"""Research-only clean1000 compression spike. Never imported by the app.

Weights are written only below --cache; JSON contains every selected example,
grader result and candidate. Selection uses train/validation, never test.
Requires the original model kit's scripts/model_io.py, torch and transformers.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import platform
import random
import re
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn


SKILLS = {
    "general": ("addition", "action", "assembly", "retrieval", "history", "reasoning", "conversation"),
    "operations": ("sub", "mul", "text_crossed"),
}
SEED = 20261021


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def normalize(text):
    return " ".join(text.casefold().split()).strip(' .!\"\'')


def grade(row, output):
    """Strict task rules; never match a number as a substring of another number."""
    text = output.strip()
    if row.get("numeric_answer") is not None:
        answers = re.findall(r"\banswer\s*:\s*([-+]?\d+)\b", text, re.I)
        if answers:
            return int(answers[-1]) == int(row["numeric_answer"])
        return bool(re.fullmatch(r"[-+]?\d+[.!]?", text)) and int(text.rstrip('.!')) == int(row["numeric_answer"])
    if row.get("expected_terms"):
        return all(re.search(r"(?<!\w)" + re.escape(term) + r"(?!\w)", text, re.I) for term in row["expected_terms"])
    if row.get("expected"):
        expected = row["expected"]
        explicit = re.findall(r"\banswer\s*:\s*([^\n]+)", text, re.I)
        return normalize(explicit[-1] if explicit else text) == normalize(expected)
    # Copy, transform and assembly tasks have an unambiguous reference string.
    return normalize(text) == normalize(row["answer"])


def identity(row):
    return str(row.get("group_id", row["id"]))


def load_splits(kit, tok, counts=(("train", 6), ("validation", 2), ("test", 4)), excluded_groups=()):
    result = {}
    used_groups = set(excluded_groups)
    # Exclude the exact same semantic group across all three research splits,
    # including groups shared by the two original dataset directories.
    for split, count in counts:
        selected = []
        for domain, skills in SKILLS.items():
            rows = [json.loads(line) for line in (kit / "datasets" / domain / f"{split}.jsonl").read_text().splitlines()]
            for skill in skills:
                pool = [r for r in rows if r["skill"] == skill and (skill != "conversation" or r.get("expected_terms"))]
                pool.sort(key=lambda r: hashlib.sha256(f'{SEED}:{r["id"]}'.encode()).hexdigest())
                picked = 0
                for row in pool:
                    if identity(row) in used_groups:
                        continue
                    row = dict(row, domain=domain)
                    prompt = tok.apply_chat_template(row["messages"], add_generation_prompt=True)
                    full = tok.apply_chat_template(row["messages"] + [dict(role="assistant", content=row["answer"])])
                    # No truncation: assistant-only targets retain their true positions.
                    if full[:len(prompt)] != prompt or len(full) > 320:
                        continue
                    row["prompt_ids"], row["full_ids"] = prompt, full
                    selected.append(row)
                    used_groups.add(identity(row))
                    picked += 1
                    if picked == count:
                        break
                if picked != count:
                    raise ValueError(f"Insufficient eligible {domain}/{split}/{skill}: {picked}")
        result[split] = selected
    return result


def parameter_count(model):
    return sum(p.numel() for p in model.parameters())


def set_layers(model, keep):
    model.model.layers = nn.ModuleList([model.model.layers[i] for i in keep])
    model.config.num_hidden_layers = len(keep)
    model.config.layer_types = ["full_attention"] * len(keep)
    for i, layer in enumerate(model.model.layers):
        layer.self_attn.layer_idx = i
    return model


@torch.inference_mode()
def nll(model, rows):
    total = count = 0
    for row in rows:
        ids = torch.tensor([row["full_ids"]])
        start = len(row["prompt_ids"]) - 1
        logits = model(ids, use_cache=False).logits[0, start:-1].float()
        labels = ids[0, start + 1:]
        total += float(F.cross_entropy(logits, labels, reduction="sum"))
        count += labels.numel()
    return total / count


@torch.inference_mode()
def task_evaluation(model, rows, tok):
    results = []
    for row in rows:
        ids = torch.tensor([row["prompt_ids"]])
        output = model.generate(ids, attention_mask=torch.ones_like(ids), max_new_tokens=192,
                                do_sample=False, use_cache=True, pad_token_id=tok.pad_token_id,
                                eos_token_id=tok.eos_token_id)
        tokens = output[0, ids.shape[1]:].tolist()
        text = tok.decode(tokens, skip_special_tokens=True)
        results.append(dict(id=row["id"], skill=row["skill"], prompt=row["messages"],
                            expected=row["answer"], output=text, correct=bool(grade(row, text)),
                            tokens=len(tokens), reached_limit=len(tokens) == 192))
    by_skill = {}
    for skill in sorted({r["skill"] for r in results}):
        subset = [r for r in results if r["skill"] == skill]
        by_skill[skill] = dict(correct=sum(r["correct"] for r in subset), count=len(subset))
    return dict(correct=sum(r["correct"] for r in results), count=len(results), by_skill=by_skill, examples=results)


@torch.inference_mode()
def agreement(model, teacher, rows):
    kl = correct = count = 0
    for row in rows:
        ids = torch.tensor([row["full_ids"]])
        start = len(row["prompt_ids"]) - 1
        actual = model(ids, use_cache=False).logits[0, start:-1].float()
        expected = teacher(ids, use_cache=False).logits[0, start:-1].float()
        logp, logq = actual.log_softmax(-1), expected.log_softmax(-1)
        kl += float((logq.exp() * (logq - logp)).sum())
        correct += int((actual.argmax(-1) == expected.argmax(-1)).sum())
        count += actual.shape[0]
    return dict(teacher_kl=kl / count, teacher_top1_agreement=correct / count, assistant_tokens=count)


@torch.inference_mode()
def collect_activations(model, rows):
    chunks = defaultdict(list)
    handles = []
    for i, layer in enumerate(model.model.layers):
        def capture(_module, args, index=i):
            chunks[index].append(args[0].detach().reshape(-1, args[0].shape[-1]).clone())
        handles.append(layer.mlp.down_proj.register_forward_pre_hook(capture))
    try:
        for row in rows:
            model(torch.tensor([row["full_ids"]]), use_cache=False)
    finally:
        for handle in handles:
            handle.remove()
    return [torch.cat(chunks[i]) for i in range(len(model.model.layers))]


def fit_down_projection(z, weight, keep, method):
    """Mean compensation or anchored ridge reconstruction; no backpropagation."""
    selected = z[:, keep].double()
    original = weight.double()
    anchor = original[:, keep]
    if method == "plain":
        return anchor.float(), None
    full_mean, kept_mean = z.double().mean(0), selected.mean(0)
    if method == "mean":
        bias = original @ full_mean - anchor @ kept_mean
        return anchor.float(), bias.float()
    if method == "ridge_no_bias":
        gram = selected.T @ selected
        ridge = float(gram.diag().mean()) * 1e-3
        solution = torch.linalg.solve(gram + torch.eye(len(keep), dtype=torch.float64) * ridge,
                                      selected.T @ (z.double() @ original.T) + ridge * anchor.T)
        return solution.T.float(), None
    centered = selected - kept_mean
    target = z.double() @ original.T
    target_mean = target.mean(0)
    centered_target = target - target_mean
    gram = centered.T @ centered
    ridge = float(gram.diag().mean()) * 1e-3
    solution = torch.linalg.solve(gram + torch.eye(len(keep), dtype=torch.float64) * ridge,
                                  centered.T @ centered_target + ridge * anchor.T)
    bias = target_mean - kept_mean @ solution
    return solution.T.float(), bias.float()


def shrink_mlp(original, width, activations, method):
    model = copy.deepcopy(original)
    retained = []
    for i, layer in enumerate(model.model.layers):
        mlp = layer.mlp
        z = activations[i]
        # FLAP-inspired variance * squared downstream column norm. We use a
        # uniform width, not FLAP's global adaptive allocation algorithm.
        scores = z.var(0, unbiased=False) * mlp.down_proj.weight.detach().square().sum(0)
        keep = scores.topk(width).indices.sort().values
        weight, bias = fit_down_projection(z, mlp.down_proj.weight.detach(), keep, method)
        for name in ("gate_proj", "up_proj"):
            old = getattr(mlp, name)
            new = nn.Linear(old.in_features, width, bias=False)
            new.weight = nn.Parameter(old.weight.detach()[keep].clone())
            setattr(mlp, name, new)
        down = nn.Linear(width, model.config.hidden_size, bias=bias is not None)
        down.weight = nn.Parameter(weight)
        if bias is not None:
            down.bias = nn.Parameter(bias)
        mlp.down_proj = down
        mlp.intermediate_size = width
        retained.append(keep.tolist())
    model.config.intermediate_size = width
    return model.eval(), retained


def save_candidate(model, path, metadata):
    # Research checkpoint includes reconstruction metadata because Qwen3's
    # standard config does not encode a newly added MLP down-projection bias.
    torch.save(dict(state=model.state_dict(), metadata=metadata), path)


def restore_candidate(original, path):
    saved = torch.load(path, map_location="cpu", weights_only=True)
    meta = saved["metadata"]
    model = copy.deepcopy(original)
    if "source_layers" in meta:
        set_layers(model, meta["source_layers"])
    width = meta.get("width", original.config.intermediate_size)
    for layer in model.model.layers:
        layer.mlp.gate_proj = nn.Linear(model.config.hidden_size, width, bias=False)
        layer.mlp.up_proj = nn.Linear(model.config.hidden_size, width, bias=False)
        layer.mlp.down_proj = nn.Linear(width, model.config.hidden_size, bias=meta.get("method") in ("mean", "ridge"))
        layer.mlp.intermediate_size = width
    model.config.intermediate_size = width
    model.load_state_dict(saved["state"], strict=True)
    return model.eval(), meta


def write_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + "\n")


def run(args):
    torch.set_num_threads(2)
    torch.set_num_interop_threads(1)
    torch.manual_seed(SEED)
    np.random.seed(SEED)
    random.seed(SEED)
    sys.path.insert(0, str(args.kit / "scripts"))
    from model_io import load_model, load_tokenizer
    tok = load_tokenizer(args.kit / "models" / "clean1000")
    original = load_model(args.kit / "models" / "clean1000").cpu().eval()
    original.requires_grad_(False)
    args.cache.mkdir(parents=True, exist_ok=True)
    splits = load_splits(args.kit, tok)
    source = args.kit / "onnx" / "clean1000" / "decoder.onnx"
    source_hash = sha256(source)
    report = dict(seed=SEED, scope="research_only_not_active_in_neuralese",
                  environment=dict(platform=platform.platform(), torch=torch.__version__, threads=2),
                  source=dict(path=str(source), sha256=source_hash, bytes=source.stat().st_size,
                              parameters=parameter_count(original), layers=10, width=1024),
                  benchmark=dict(max_new_tokens=192, assistant_only_nll=True, generation="greedy_cached",
                                 limitations=["small fixed English benchmark", "reference graders can reject valid paraphrases", "test used only after choosing candidates"]),
                  splits=splits, searches={}, candidates={})
    print(json.dumps(dict(event="baseline", split_counts={k: len(v) for k, v in splits.items()})), flush=True)
    base_val = nll(original, splits["validation"])
    report["candidates"]["original"] = dict(validation_nll=base_val, parameters=parameter_count(original), layers=10, width=1024)
    # True removal: evaluate every possible deletion, then repeat on the
    # already reduced model. Calibration NLL selects each next deletion.
    keep = list(range(10))
    depth_paths = []
    for target in (9, 8):
        trials = []
        for removed in keep:
            retained = [i for i in keep if i != removed]
            candidate = set_layers(copy.deepcopy(original), retained)
            score = nll(candidate, splits["train"])
            trials.append(dict(removed=removed, source_layers=retained, calibration_nll=score))
        best = min(trials, key=lambda r: r["calibration_nll"])
        keep = best["source_layers"]
        report["searches"][f"depth_{target}"] = trials
        candidate = set_layers(copy.deepcopy(original), keep)
        name = f"depth_{target}"
        metadata = dict(source_layers=keep, layers=target, width=1024, method="iterative_nll_prune")
        save_candidate(candidate, args.cache / f"{name}.pt", metadata)
        row = dict(**metadata, parameters=parameter_count(candidate), validation_nll=nll(candidate, splits["validation"]))
        report["candidates"][name] = row
        depth_paths.append(name)
        print(json.dumps(dict(event=name, **row)), flush=True)
        write_report(args.report, report)
    print(json.dumps(dict(event="collect_mlp_activations")), flush=True)
    activations = collect_activations(original, splits["train"])
    report["calibration_activation_tokens"] = activations[0].shape[0]
    mlp_paths = []
    for width in (896, 768, 512):
        for method in ("plain", "mean", "ridge"):
            candidate, retained = shrink_mlp(original, width, activations, method)
            name = f"mlp_{width}_{method}"
            meta = dict(layers=10, width=width, method=method, retained_channels=retained)
            save_candidate(candidate, args.cache / f"{name}.pt", meta)
            row = dict(layers=10, width=width, method=method, parameters=parameter_count(candidate),
                       validation_nll=nll(candidate, splits["validation"]))
            report["candidates"][name] = row
            print(json.dumps(dict(event=name, **row)), flush=True)
            write_report(args.report, report)
        methods = [f"mlp_{width}_{m}" for m in ("plain", "mean", "ridge")]
        mlp_paths.append(min(methods, key=lambda name: report["candidates"][name]["validation_nll"]))
    del activations
    # Negative control: naive weight averaging is not a full LaCo reproduction.
    trials = []
    for i in range(9):
        candidate = copy.deepcopy(original)
        first, second = candidate.model.layers[i:i + 2]
        for a, b in zip(first.parameters(), second.parameters()):
            a.copy_(0.5 * (a + b))
        set_layers(candidate, [j for j in range(10) if j != i + 1])
        trials.append(dict(pair=[i, i + 1], calibration_nll=nll(candidate, splits["train"])))
    best = min(trials, key=lambda r: r["calibration_nll"])
    report["searches"]["adjacent_lerp"] = trials
    i = best["pair"][0]
    candidate = copy.deepcopy(original)
    for a, b in zip(candidate.model.layers[i].parameters(), candidate.model.layers[i + 1].parameters()):
        a.copy_(0.5 * (a + b))
    retained = [j for j in range(10) if j != i + 1]
    set_layers(candidate, retained)
    save_candidate(candidate, args.cache / "adjacent_lerp.pt", dict(layers=9, width=1024, method="adjacent_lerp", source_layers=retained, pair=best["pair"]))
    report["candidates"]["adjacent_lerp"] = dict(layers=9, width=1024, parameters=parameter_count(candidate), validation_nll=nll(candidate, splits["validation"]))
    finalists = ["original", *depth_paths, *mlp_paths, "adjacent_lerp"]
    report["finalists_chosen_before_test"] = finalists
    write_report(args.report, report)
    for name in finalists:
        candidate = original if name == "original" else restore_candidate(original, args.cache / f"{name}.pt")[0]
        row = report["candidates"][name]
        row["validation_tasks"] = task_evaluation(candidate, splits["validation"], tok)
        row["test_nll"] = nll(candidate, splits["test"])
        row["test_tasks"] = task_evaluation(candidate, splits["test"], tok)
        row.update(agreement(candidate, original, splits["test"]))
        print(json.dumps(dict(event="evaluated", candidate=name, validation_correct=row["validation_tasks"]["correct"],
                              test_correct=row["test_tasks"]["correct"], test_count=row["test_tasks"]["count"],
                              test_nll=row["test_nll"], teacher_top1_agreement=row["teacher_top1_agreement"])), flush=True)
        write_report(args.report, report)
    assert sha256(source) == source_hash
    report["source_unchanged"] = True
    write_report(args.report, report)
    print(json.dumps(dict(event="complete", report=str(args.report))), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    with torch.no_grad():
        run(parser.parse_args())
