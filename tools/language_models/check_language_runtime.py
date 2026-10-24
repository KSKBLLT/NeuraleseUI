"""Offline smoke test, executed with an export's Python using -I.

Reject imports from external site-packages, run genuine tokenization, attention,
and cached autoregression, with fresh derived caches and no model-kit fallback.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import sys
import tempfile


def verify(runtime: Path):
    runtime = runtime.resolve()
    for key in list(os.environ):
        if key.startswith("NEURALESE_LANGUAGE_"):
            os.environ.pop(key)
    sys.path.insert(0, str(runtime))
    def no_network(*_args, **_kwargs):
        raise AssertionError("Offline runtime attempted a network connection")
    socket.create_connection = no_network
    socket.getaddrinfo = no_network
    from neuralese_local.language.engine import LanguageEngine
    with tempfile.TemporaryDirectory(prefix="neuralese-offline-check-") as cache:
        os.environ["NEURALESE_LANGUAGE_CACHE_DIR"] = cache
        engine = LanguageEngine(runtime / "models/clean1000")
        modules = {}
        for name in ("numpy", "onnx", "onnxruntime", "tokenizers", "jinja2", "markupsafe", "neuralese_local"):
            module = sys.modules[name]
            path = Path(module.__file__).resolve()
            if not path.is_relative_to(runtime):
                raise AssertionError(f"External dependency: {name}: {path}")
            modules[name] = path.relative_to(runtime).as_posix()
        def send(number, method, params=None, sid=""):
            response = engine.handle({"schema_version": 1, "request_id": number, "session_id": sid,
                                      "graph_revision": 1, "method": method, "params": params or {}})
            if not response["ok"]:
                raise AssertionError(response["error"])
            return response["result"]
        graph = {"nodes": [{"id": "e", "op": "embedding"}, {"id": "a", "op": "attention_head"}],
                 "edges": [{"from_node": "e", "to_node": "a"}]}
        session = send(1, "open_session", {"graph": graph})["session_id"]
        tokens = send(2, "tokenize", {"text": "Copy exactly: red cup"}, session)["ids"]
        preview = send(3, "preview", {"prefix_ids": tokens}, session)
        assert preview["nodes"]["a"]["preview"]["matrix"]
        generated = []
        for i in range(4):
            result = send(4 + i, "run_step", {"prefix_ids": tokens, "generated_ids": generated, "temperature": 0, "top_k": 5}, session)
            generated = result["generated_ids"]
            if result.get("finished") or (generated and generated[-1] == engine.bundle.config["eos_token_id"]):
                break
        text = engine.prototype.decode(generated).strip()
        assert text == "red cup", repr(text)
        assert "torch" not in sys.modules and "transformers" not in sys.modules and "huggingface_hub" not in sys.modules
        return {"ok": True, "offline": True, "model_id": engine.bundle.model_id, "text": text,
                "attention": True, "modules": modules}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.runtime)))
