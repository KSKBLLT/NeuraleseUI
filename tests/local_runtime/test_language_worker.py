from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest

from neuralese_local.language.model_bundle import default_model_path


ROOT = Path(__file__).resolve().parents[2]
GRAPH = {"nodes": [{"id": "e", "op": "embedding"}, {"id": "a", "op": "attention_head"}], "edges": [{"from_node": "e", "to_node": "a"}]}


def packet(number, method, params=None, sid=""):
    return {"schema_version": 1, "request_id": number, "session_id": sid, "graph_revision": 7, "method": method, "params": params or {}}


def test_real_engine_preview_step_inspect_and_closed_session():
    from neuralese_local.language.engine import LanguageEngine
    engine = LanguageEngine(default_model_path())
    caps = engine.handle(packet(1, "capabilities"))
    assert caps["ok"] and not caps["is_dummy"]
    assert caps["result"]["vocab_size"] == 20002
    sid = engine.handle(packet(2, "open_session", {"graph": GRAPH}))["result"]["session_id"]
    tokens = engine.handle(packet(3, "tokenize", {"text": "Copy exactly: red cup"}, sid))["result"]
    preview = engine.handle(packet(4, "preview_node", {"prefix_ids": tokens["ids"], "target_id": "a"}, sid))
    assert preview["ok"] and preview["result"]["generated_ids"] == []
    assert set(preview["result"]["nodes"]) == {"a"}
    assert preview["result"]["nodes"]["a"]["preview"]["matrix"]
    stepped = engine.handle(packet(5, "run_step", {"prefix_ids": tokens["ids"], "generated_ids": [], "temperature": 0, "top_k": 5}, sid))
    assert stepped["ok"] and stepped["result"]["generated_ids"] == [768]
    inspection = engine.handle(packet(6, "inspect", {"node_id": "a", "start": 0, "count": 4}, sid))
    assert inspection["ok"] and len(inspection["result"]["matrix"]) == 4
    assert inspection["session_id"] == sid and inspection["graph_revision"] == 7
    engine.handle(packet(7, "close_session", sid=sid))
    assert not engine.handle(packet(8, "run_step", {"prefix_ids": tokens["ids"]}, sid))["ok"]


def test_cancel_open_releases_the_created_session():
    from neuralese_local.language.engine import LanguageEngine
    engine = LanguageEngine(default_model_path())
    sid = engine.handle(packet(1, "open_session", {"graph": GRAPH}))["result"]["session_id"]
    engine.handle(packet(2, "cancel", {"target_request_id": 1}))
    assert not engine.handle(packet(3, "inspect", {"node_id": "a"}, sid))["ok"]


def test_preparation_reports_demo_dataset_and_preserves_real_weights():
    import hashlib
    from neuralese_local.language.engine import LanguageEngine
    engine = LanguageEngine(default_model_path())
    original = hashlib.sha256(engine.bundle.decoder.read_bytes()).hexdigest()
    sid = engine.handle(packet(1, "open_session", {"graph": GRAPH}))["result"]["session_id"]
    prepared = engine.handle(packet(2, "prepare_model", {"dataset":{"name":"language_stories","simulated":True,"size":12}}, sid))
    assert prepared["ok"] and not prepared["is_dummy"]
    assert prepared["result"]["simulated"] and prepared["result"]["weights_written"] is False
    assert prepared["result"]["dataset"]["name"] == "language_stories"
    assert prepared["result"]["model_id"] == engine.bundle.model_id
    assert prepared["result"]["mapping"]["effective_depth"] == 10
    initial=engine.handle(packet(3,"training_step",{"text":"Copy exactly: red cup","progress":0,"example":"The little cat looked out of the window."},sid))
    final=engine.handle(packet(4,"training_step",{"text":"Copy exactly: blue moon","progress":1,"example":"A bright sun warmed the quiet garden."},sid))
    assert initial["ok"] and final["ok"] and final["result"]["teacher_agreement"]==1
    assert final["result"]["nodes"]["a"]["preview"]["source_text"]=="Copy exactly: blue moon"
    assert final["result"]["generated_ids"]==[]
    assert hashlib.sha256(engine.bundle.decoder.read_bytes()).hexdigest() == original
