"""Language model operations used by the standard local inference/training workers."""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import time
import traceback
import uuid

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from neuralese_local.stop_flag import StopFlag
from neuralese_local.language.model_bundle import load_bundle
from neuralese_local.language.graph_mapping import resolve_graph


def envelope(request: dict, result=None, error=None) -> dict:
    return {"schema_version": 1, "request_id": request.get("request_id", 0), "session_id": request.get("session_id", ""), "graph_revision": request.get("graph_revision", 0), "provider_id": "onnx-clean1000", "is_dummy": False, "ok": error is None, "result": result if error is None else None, "error": error}


class LanguageEngine:
    def __init__(self, model_path=None):
        # Import inside the startup error boundary: a checkout may still use an
        # older interpreter without the newly added inference dependencies.
        from neuralese_local.language.onnx_session import LanguageSession
        self._session_class = LanguageSession
        self.bundle = load_bundle(model_path)
        self.prototype = LanguageSession(self.bundle)
        self.sessions: dict[str, LanguageSession] = {}
        self.open_requests = {}
        self.graphs = {}
        self.learners = {}

    def _mapping(self, graph):
        return resolve_graph(graph, {"source_hash": self.bundle.source_hash}, self.bundle.layers)

    def handle(self, request: dict) -> dict:
        try:
            if request.get("schema_version") != 1:
                raise ValueError("Unsupported language protocol version")
            method, params = request.get("method"), request.get("params", {})
            sid = str(request.get("session_id", ""))
            if method == "capabilities":
                result = {"vocab_size": self.bundle.vocab_size, "model_width": self.bundle.width, "head_count": self.bundle.heads, "kv_head_count": self.bundle.kv_heads, "max_context": 512, "max_new_tokens": 32, "training": "pretrained", "export": False, "loose_architecture": True, "model_id": self.bundle.model_id, "real_traces": True}
            elif method == "open_session":
                if len(self.sessions) >= 4:
                    raise ValueError("Закройте другую языковую сеть перед запуском новой")
                sid = uuid.uuid4().hex
                graph = params.get("graph", {})
                self.sessions[sid] = self._session_class(self.bundle, self._mapping(graph), int(params.get("seed", 42)), shared=self.prototype)
                self.graphs[sid] = graph
                self.open_requests[int(request["request_id"])] = sid
                result = {"session_id": sid, "model_id": self.bundle.model_id, "mapping": self.sessions[sid].mapping}
            elif method == "cancel":
                created = self.open_requests.pop(int(params.get("target_request_id", -1)), None)
                if created:
                    self.sessions.pop(created, None)
                    self.graphs.pop(created, None)
                    self.learners.pop(created, None)
                result = {"cancelled": True}
            elif method == "close_session":
                self.sessions.pop(sid, None)
                self.graphs.pop(sid, None)
                self.learners.pop(sid, None)
                self.open_requests = {key: value for key, value in self.open_requests.items() if value != sid}
                result = {"closed": True}
            elif method == "tokenize":
                result = self.sessions.get(sid, self.prototype).tokenize(str(params.get("text", "")))
            elif method == "vocabulary_page":
                result = self.prototype.vocabulary_page(str(params.get("query", "")), int(params.get("offset", 0)), int(params.get("limit", 50)))
            else:
                if sid not in self.sessions:
                    return envelope(request, error={"code": "unknown_session", "message": "Сессия модели завершена", "node_id": ""})
                session = self.sessions[sid]
                if "graph" in params:
                    self.graphs[sid] = params["graph"]
                    session.mapping = self._mapping(params["graph"])
                if method in {"preview_node", "preview"}:
                    prefix = params.get("prefix_ids")
                    if prefix is None:
                        prefix = session.tokenize(str(params.get("text", "")))["ids"]
                    targets = [str(params["target_id"])] if params.get("target_id") else None
                    result = session.preview(prefix, params.get("generated_ids", []), targets)
                elif method == "run_step":
                    result = session.step(params.get("prefix_ids", []), params.get("generated_ids", []), float(params.get("temperature", .7)), int(params.get("top_k", 5)))
                elif method == "inspect":
                    result = session.inspect(str(params.get("node_id", "")), int(params.get("start", 0)), int(params.get("count", 8)))
                elif method == "training_step":
                    if sid not in self.learners:
                        raise ValueError("Prepare the language model before training")
                    learner = self.learners[sid]
                    learner.mapping = session.mapping
                    step_started = time.perf_counter()
                    result = learner.training_preview(str(params.get("text", "")), float(params.get("progress", 0)), str(params.get("example", "")),int(params.get("batch_index",0)))
                    if "epoch" in params:
                        epoch=int(params["epoch"])
                        if getattr(learner,"_measured_epoch",None)!=epoch:
                            learner._measured_epoch=epoch
                            learner._epoch_compute_seconds=0.0
                        learner._epoch_compute_seconds+=time.perf_counter()-step_started
                        result["epoch_compute_seconds"]=learner._epoch_compute_seconds
                elif method in {"train", "prepare_model"}:
                    dataset = params.get("dataset", {})
                    if dataset and (not isinstance(dataset, dict) or not dataset.get("simulated") or int(dataset.get("size", 0)) < 1):
                        raise ValueError("Select the classroom language dataset")
                    from neuralese_local.language.learning_session import LearningSession
                    self.learners[sid] = LearningSession(session)
                    if dataset.get("samples"):
                        self.learners[sid].prepare_corpus(dataset["samples"],dataset.get("validation_samples",[]))
                    result = {"event": "completed", "progress": 1., "weights_written": False, "simulated": True, "mode": "pretrained", "model_id": self.bundle.model_id, "source_hash": self.bundle.source_hash, "dataset": {key: dataset[key] for key in ("name", "size", "simulated") if key in dataset}, "mapping": session.mapping}
                else:
                    raise ValueError(f"Unsupported language method: {method}")
                if "nodes" in result:
                    originals = {str(n["id"]): n for n in self.graphs[sid].get("nodes", [])}
                    for key, trace in result["nodes"].items():
                        for field in ("input_shape", "output_shape", "input_type", "output_type", "input_dtype", "output_dtype"):
                            if field in originals.get(key, {}):
                                trace[field] = originals[key][field]
            return envelope(request, result=result)
        except Exception as error:
            return envelope(request, error={"code": "language_runtime", "message": str(error), "node_id": str(request.get("params", {}).get("target_id", ""))})

