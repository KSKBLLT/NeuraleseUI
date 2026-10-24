"""Fresh-pull failures must reach the UI instead of killing the mailbox."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("missing", ["tokenizers", "jinja2", "onnxruntime"])
def test_missing_inference_dependency_returns_actionable_error(tmp_path, missing):
    # Simulate an old bundled interpreter without changing installed packages.
    (tmp_path / "sitecustomize.py").write_text(
        "import sys\n"
        "class MissingDependency:\n"
        " def find_spec(self, fullname, path=None, target=None):\n"
        f"  if fullname == {missing!r}:\n"
        f"   raise ModuleNotFoundError(\"No module named '{missing}'\", name={missing!r})\n"
        "sys.meta_path.insert(0, MissingDependency())\n"
    )
    mailbox = tmp_path / "mailbox"
    mailbox.mkdir()
    (mailbox / "control.json").write_text(json.dumps({"model_kind":"language", "parent_pid": os.getpid()}))
    request = {"schema_version": 1, "request_id": 1, "session_id": "", "graph_revision": 2, "method": "capabilities", "params": {}}
    env = dict(os.environ, PYTHONPATH=str(tmp_path))
    process = subprocess.Popen([sys.executable, str(ROOT / "local_runtime/neuralese_local/infer_loop.py"), str(mailbox)],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        response = mailbox / "response.json"
        deadline = time.monotonic() + 10
        while not response.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(.01)
        assert response.exists(), f"Worker exited before returning the missing {missing} error"
        packet = json.loads(response.read_text(encoding="utf-8"))
        assert not packet["ok"]
        assert missing in packet["error"]["technical_message"]

    finally:
        (mailbox / "stop").touch()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
