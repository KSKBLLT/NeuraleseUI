import importlib.util
from pathlib import Path
import sys

import pytest

POLICY = Path(__file__).resolve().parents[2] / "resources" / "network_endpoint_policy.json"
TOOL = POLICY.parents[1] / "tools" / "network_boundary_audit.py"
SPEC = importlib.util.spec_from_file_location("network_boundary_audit", TOOL)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
audit_repository = MODULE.audit_repository


def _write_script(root: Path, relative: str, source: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")


@pytest.mark.parametrize(
    ("source", "rule"),
    [
        ('func go():\n\tweb.POST("api/new-route", {})\n', "unclassified-rest-route"),
        (
            'func go():\n\tweb.GET("https://unapproved.example/file")\n',
            "unapproved-external-route",
        ),
        (
            'func go():\n\tweb.POST(\n\t\t"api/new-route",\n\t\t{}\n\t)\n',
            "unclassified-rest-route",
        ),
        ('func go():\n\tsockets.connect_to("ws/new-route")\n', "unclassified-websocket-route"),
        (
            'func go():\n\tsockets.connect_to(\n\t\t"ws/new-route"\n\t)\n',
            "unclassified-websocket-route",
        ),
        ('func go(route):\n\tweb.GET(route)\n', "dynamic-network-route"),
        ('func go():\n\tvar req = HTTPRequest.new()\n', "raw-transport-owner"),
        ('func go():\n\tweb._request("https://example.test")\n', "raw-request-owner"),
        ('func go():\n\tcookies.get_auth_header()\n', "ambiguous-auth-header"),
    ],
)
def test_rejects_unapproved_network_boundaries(
    tmp_path: Path, source: str, rule: str
) -> None:
    _write_script(tmp_path, "scripts/feature.gd", source)
    violations = audit_repository(tmp_path, POLICY)
    assert any(item.rule == rule for item in violations)


def test_ignores_commented_transport_example(tmp_path: Path) -> None:
    _write_script(
        tmp_path,
        "scripts/feature.gd",
        '# HTTPRequest.new()\n# web.POST("api/new-route", {})\n',
    )
    assert audit_repository(tmp_path, POLICY) == []


def test_allows_narrowly_registered_external_callsite(tmp_path: Path) -> None:
    _write_script(
        tmp_path,
        "scripts/glob.gd",
        "func download_update(url):\n\tweb.GET(url)\n",
    )
    assert audit_repository(tmp_path, POLICY) == []
