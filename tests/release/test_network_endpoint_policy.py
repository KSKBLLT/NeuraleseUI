import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = ROOT / "resources" / "network_endpoint_policy.json"


def _load_policy() -> dict:
    assert POLICY_PATH.is_file(), "network endpoint policy is missing"
    return json.loads(POLICY_PATH.read_text(encoding="utf-8"))


def test_network_endpoint_policy_covers_remote_entry_points() -> None:
    policy = _load_policy()

    rest = policy["rest"]
    websocket = policy["websocket"]

    assert rest["aliases"]["ask_once"] == "api/axon/ask-once"
    assert rest["aliases"]["classroom_join"] == "api/classrooms/join"
    assert "api/projects/save" in rest["auth_required"]
    assert "api/pilot/onboarding/register" in rest["public"]
    assert websocket["aliases"]["ws/talk"] == "ws/axon/talk"
    assert "ws/infer" in websocket["auth_required"]


def test_remote_auth_policy_helpers_exist() -> None:
    assert (ROOT / "scripts" / "auth" / "remote_endpoint_policy.gd").is_file()
    assert (ROOT / "scripts" / "auth" / "remote_session_gate.gd").is_file()
