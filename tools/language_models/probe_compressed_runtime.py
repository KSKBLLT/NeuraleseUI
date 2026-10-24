"""Research-only compatibility probe using the actual lightweight runtime API."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def probe(model_root):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "local_runtime"))
    from neuralese_local.language.engine import LanguageEngine
    import onnx
    import onnxruntime
    engine = LanguageEngine(model_root)
    def send(i, method, params=None, sid=""):
        response = engine.handle(dict(schema_version=1, request_id=i, session_id=sid, graph_revision=1, method=method, params=params or {}))
        if not response["ok"]:
            raise AssertionError(response["error"])
        return response["result"]
    graph = {"nodes": [{"id": "e", "op": "embedding"}, {"id": "a", "op": "attention_head"}],
             "edges": [{"from_node": "e", "to_node": "a"}]}
    sid = send(1, "open_session", {"graph": graph})["session_id"]
    ids = send(2, "tokenize", {"text": "Copy exactly: red cup"}, sid)["ids"]
    preview = send(3, "preview", {"prefix_ids": ids}, sid)
    generated = []
    for i in range(4):
        result = send(4 + i, "run_step", {"prefix_ids": ids, "generated_ids": generated, "temperature": 0, "top_k": 5}, sid)
        generated = result["generated_ids"]
        if result["finished"]:
            break
    text = engine.prototype.decode(generated)
    assert text == "red cup", repr(text)
    send(9, "prepare_model", {}, sid)
    initial = send(10, "training_step", {"text": "Copy exactly: red cup", "progress": 0, "batch_index": 0}, sid)
    final = send(11, "training_step", {"text": "Copy exactly: red cup", "progress": 1, "batch_index": 1}, sid)
    assert final["teacher_agreement"] == 1
    assert "torch" not in sys.modules and "transformers" not in sys.modules
    return dict(model_id=engine.bundle.model_id, onnx_sha256=engine.bundle.source_hash, generated_text=text,
                attention=bool(preview["nodes"]["a"]["preview"]["matrix"]),
                learning_initial_agreement=initial["teacher_agreement"], learning_final_agreement=final["teacher_agreement"],
                onnx=onnx.__version__, onnxruntime=onnxruntime.__version__, torch_imported=False, transformers_imported=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-root", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    result = probe(args.model_root)
    report = json.loads(args.report.read_text())
    report["candidates"][args.model_root.name]["current_runtime_probe"] = result
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(result))
