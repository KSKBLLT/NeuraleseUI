from __future__ import annotations

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer
from jinja2 import StrictUndefined
from jinja2.sandbox import SandboxedEnvironment

from ..training_profile import build_session_options, SessionProfile
from .model_bundle import ModelBundle
from .trace_model import ensure_trace_model
from .sampling import probabilities, sample


class LanguageSession:
    """One logical decoder session; all exposed tensors belong to its forward pass."""

    def __init__(self, bundle: ModelBundle, mapping: dict | None = None, seed: int = 42, shared: LanguageSession | None = None):
        self.bundle = bundle
        self.mapping = mapping or {"node_mapping": {}}
        self.rng = np.random.default_rng(seed)
        if shared is not None:
            self.tokenizer, self.ort, self.trace_outputs = shared.tokenizer, shared.ort, shared.trace_outputs
        else:
            self.tokenizer = Tokenizer.from_file(str(bundle.tokenizer))
            path, manifest = ensure_trace_model(bundle)
            self.trace_outputs = manifest["outputs"]
            options = build_session_options(SessionProfile("language",2))
            self.ort = ort.InferenceSession(str(path), sess_options=options, providers=["CPUExecutionProvider"])
        self.cache_names = [f"present_{i}_{kind}" for i in range(bundle.layers) for kind in ("key", "value")]
        self.last_text = ""
        self._template = SandboxedEnvironment(undefined=StrictUndefined).from_string((bundle.root / "chat_template.jinja").read_text(encoding="utf-8"))
        self._last = {}
        self._attention_views = {}
        self._model_ids = []
        self._last_forward = None
        self._shared = shared if shared is not None else self
        if shared is None:
            self._word_view = None
            self._projection = None

    def tokenize(self, text: str) -> dict:
        encoded = self.tokenizer.encode(text, add_special_tokens=False)
        self.last_text = text
        tokens = [{"id": int(token), "piece": piece, "start": start, "end": end, "position": i} for i, (token, piece, (start, end)) in enumerate(zip(encoded.ids, encoded.tokens, encoded.offsets))]
        return {"text": text, "tokens": tokens, "ids": encoded.ids, "vocabulary_id": self.bundle.model_id, "source_text": text}

    def decode(self, ids: list[int]) -> str:
        return self.tokenizer.decode(ids, skip_special_tokens=True)

    def _additional_feed(self) -> dict:
        return {}

    def forward(self, ids: list[int], cache: list[np.ndarray] | None = None, layers=()) -> dict:
        if not ids or any(not isinstance(i, (int, np.integer)) or i < 0 or i >= self.bundle.vocab_size for i in ids):
            raise ValueError("Enter valid model token IDs")
        if cache is None:
            cache = [np.zeros((1, self.bundle.kv_heads, 0, self.bundle.head_dim), np.float32) for _ in self.cache_names]
        if len(cache) != len(self.cache_names):
            raise ValueError("Invalid KV cache")
        past = cache[0].shape[2]
        if past + len(ids) > self.bundle.max_context:
            raise ValueError("Use at most 512 tokens, including the model prompt")
        feed = {"input_ids": np.array([ids], np.int64), "attention_mask": np.ones((1, past + len(ids)), np.int64), "position_ids": np.arange(past, past + len(ids), dtype=np.int64)[None]}
        for name, value in zip(self.ort.get_inputs()[3:3 + len(cache)], cache):
            feed[name.name] = value
        feed.update(self._additional_feed())
        layers = sorted(set(int(i) for i in layers))
        if any(i < 0 or i >= self.bundle.layers for i in layers):
            raise ValueError("Invalid attention layer")
        names = ["logits", *self.cache_names, self.trace_outputs["embeddings"]]
        for layer in layers:
            names.extend(self.trace_outputs[k][layer] for k in ("attention", "head_outputs", "hidden"))
        values = dict(zip(names, self.ort.run(names, feed)))
        return {"logits": values["logits"], "cache": [values[name] for name in self.cache_names], "embeddings": values[self.trace_outputs["embeddings"]], **{kind: {i: values[self.trace_outputs[kind][i]] for i in layers} for kind in ("attention", "head_outputs", "hidden")}}

    def _context(self, prefix: list[int], generated: list[int]) -> tuple[list[int], list[dict], str, list[int]]:
        if not prefix:
            raise ValueError("Введите текст")
        text = self.decode(prefix)
        if self.last_text and self.tokenizer.encode(self.last_text, add_special_tokens=False).ids == prefix:
            text = self.last_text
        marker = "NEURALESE_CONTENT_PLACEHOLDER_7f721c"
        rendered = self._template.render(messages=[{"role": "user", "content": marker}], add_generation_prompt=True)
        if rendered.count(marker) != 1:
            raise ValueError("Unsupported chat template")
        before, after = rendered.split(marker)
        encoded = self.tokenizer.encode(before + text + after, add_special_tokens=False)
        positions, tokens = [], []
        for position, (token, piece, (start, end)) in enumerate(zip(encoded.ids, encoded.tokens, encoded.offsets)):
            if end > len(before) and start < len(before) + len(text):
                positions.append(position)
                tokens.append({"id": token, "piece": piece, "start": max(0, start - len(before)), "end": min(len(text), end - len(before)), "position": len(tokens)})
        previous = ""
        for index, token in enumerate(generated):
            following = self.decode(generated[:index + 1])
            common = 0
            while common < min(len(previous), len(following)) and previous[common] == following[common]:
                common += 1
            positions.append(len(encoded.ids) + index)
            tokens.append({"id": token, "piece": self.tokenizer.id_to_token(token), "start": len(text) + common, "end": len(text) + len(following), "position": len(tokens)})
            previous = following
        return encoded.ids + generated, tokens, text + self.decode(generated), positions

    def preview(self, prefix_ids: list[int], generated_ids: list[int] | None = None, trace_nodes: list[str] | None = None) -> dict:
        generated = list(generated_ids or [])
        ids, tokens, source_text, visible_positions = self._context(prefix_ids, generated)
        mapping = self.mapping.get("node_mapping", {})
        selected_nodes = mapping if trace_nodes is None else {key: mapping[key] for key in trace_nodes if key in mapping}
        layers = {m["layer"] for m in selected_nodes.values() if m["op"] in {"attention_head", "layer"}}
        value = self.forward(ids, layers=layers)
        self._model_ids, self._last_forward = ids, value
        scores = probabilities(value["logits"][0, -1])
        selected = int(scores.argmax())
        labels = {str(i): self.tokenizer.decode([int(i)], skip_special_tokens=False) for i in np.argsort(-scores, kind="stable")[:20]}
        traces = {}
        self._attention_views = {}
        for key, item in selected_nodes.items():
            op = item["op"]
            data = {"source_text": source_text, "tokens": tokens, "total": len(tokens), "start": 0, "model_id": self.bundle.model_id, "layer_index": item["layer"], "width": self.bundle.width}
            if op in {"token_labels", "top_output", "softmax"}:
                data.update(scores=scores.tolist(), labels=labels, selected_id=selected)
            elif op == "attention_head":
                matrix = value["attention"][item["layer"]][0, item["head"]]
                visible = matrix[np.ix_(visible_positions, visible_positions)]
                self._attention_views[key] = visible
                # Eight *words* are visible in the native scroll area. Truncating
                # eight BPE tokens loses most Cyrillic/Kazakh words and scrolling.
                # The full matrix is bounded by the 512-token model context.
                data.update(matrix=visible.tolist(), head_index=item["head"], hidden_mass=(1 - visible.sum(-1)).tolist(), vector=value["head_outputs"][item["layer"]][0, item["head"], -1].tolist(), width=self.bundle.head_dim)
            elif op == "embedding":
                data.update(self._word_preview(source_text,tokens))
            elif op == "layer":
                data["vector"] = value["hidden"][item["layer"]][0, -1].tolist()
            elif op == "autoregression":
                data["decoded_text"] = self.decode(generated)
            traces[key] = {"kind": op, "preview": data, "actual_layer": item["layer"], "model_id": self.bundle.model_id}
        result = {"scores": scores.tolist(), "vocab_size": self.bundle.vocab_size, "labels": labels, "selected_id": selected, "next_token_id": selected, "generated_ids": generated, "decoded_text": self.decode(generated), "finished": False, "stop_reason": "", "token_count": len(tokens), "nodes": traces, "model_id": self.bundle.model_id, "mapping": self.mapping}
        self._last = result
        return result

    def _word_preview(self, text: str, tokens: list[dict]) -> dict:
        from .word_embeddings import ModelWordEmbeddings
        from .projection import load_or_build_projection, project_words
        resource = self._shared
        if resource._word_view is None:
            resource._word_view = ModelWordEmbeddings.from_bundle(self.bundle)
            resource._projection = load_or_build_projection(resource._word_view)
        points = project_words(resource._word_view.words(text,tokens),resource._projection)
        return {"points":points,"points_are_words":True,"basis_id":resource._projection["basis_id"],"z_range":[-1.,1.],"projection_method":resource._projection["method"],"normalization":"casefold"}

    def step(self, prefix_ids: list[int], generated_ids: list[int], temperature: float = .7, top_k: int = 5) -> dict:
        if len(generated_ids) >= 32:
            raise ValueError("Начните новое продолжение после 32 шагов")
        ids, _, _, _ = self._context(prefix_ids, generated_ids)
        if ids != self._model_ids or self._last_forward is None:
            self.preview(prefix_ids, generated_ids)
        chosen = sample(self._last_forward["logits"][0, -1], temperature, top_k, self.rng)
        finished = chosen == int(self.bundle.config["eos_token_id"])
        appended = list(generated_ids) + ([] if finished else [chosen])
        result = self.preview(prefix_ids, appended)
        result.update(next_token_id=chosen, generated_ids=appended, decoded_text=self.decode(appended), finished=finished, stop_reason="eos" if finished else "")
        return result

    def inspect(self, node_id: str, start: int, limit: int = 8) -> dict:
        if node_id not in self._attention_views:
            raise ValueError("Attention is not available for this node/session")
        matrix = self._attention_views[node_id]
        start = max(0, min(int(start), max(0, len(matrix) - 1)))
        limit = max(1, min(int(limit), 16))
        return {"matrix": matrix[start:start + limit, start:start + limit].tolist(), "start": start, "total": len(matrix)}

    def vocabulary_page(self, query: str, offset: int, limit: int) -> dict:
        matches = []
        for token in range(self.bundle.vocab_size):
            piece = self.tokenizer.decode([token], skip_special_tokens=False)
            if not query or query.lower() in piece.lower() or query == str(token):
                matches.append({"id": token, "piece": piece})
        offset, limit = max(0, offset), max(1, min(50, limit))
        return {"entries": matches[offset:offset + limit], "total": len(matches), "offset": offset}
