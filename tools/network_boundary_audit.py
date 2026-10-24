from __future__ import annotations

import argparse
import ast
import json
import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Violation:
    path: str
    line: int
    rule: str
    message: str


_FUNCTION_RE = re.compile(r"^\s*func\s+([A-Za-z_]\w*)\s*\(")
_HIGH_LEVEL_RE = re.compile(
    r"(?P<api>web\.(?:POST|JPOST|GET|GET_SSE|HEALTH)|sockets\.connect_to)"
    r"\s*\("
)
_LITERAL_RE = re.compile(r"^\s*(?P<quote>['\"])(?P<value>(?:\\.|(?!\1).)*)\1\s*$")
_RAW_PATTERNS = {
    "HTTPClient.new": re.compile(r"\bHTTPClient\s*\.\s*new\s*\("),
    "HTTPRequest.new": re.compile(r"\bHTTPRequest\s*\.\s*new\s*\("),
    "WebSocketPeer.new": re.compile(r"\bWebSocketPeer\s*\.\s*new\s*\("),
    "TCPServer.new": re.compile(r"\bTCPServer\s*\.\s*new\s*\("),
}


def _strip_line_comment(line: str) -> str:
    quote = ""
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\" and quote:
            escaped = True
            continue
        if char in {'"', "'"}:
            if not quote:
                quote = char
            elif quote == char:
                quote = ""
            continue
        if char == "#" and not quote:
            return line[:index]
    return line


def _literal_value(argument: str) -> str | None:
    match = _LITERAL_RE.match(argument)
    if not match:
        return None
    try:
        value = ast.literal_eval(argument.strip())
    except (SyntaxError, ValueError):
        return None
    return value if isinstance(value, str) else None


def _first_argument(source: str, start: int) -> str:
    quote = ""
    escaped = False
    nested = 0
    index = start
    while index < len(source):
        char = source[index]
        if escaped:
            escaped = False
        elif quote:
            if char == "\\":
                escaped = True
            elif char == quote:
                quote = ""
        elif char in {'"', "'"}:
            quote = char
        elif char in "([{":
            nested += 1
        elif char in ")]}":
            if nested == 0:
                return source[start:index].strip()
            nested -= 1
        elif char == "," and nested == 0:
            return source[start:index].strip()
        index += 1
    return source[start:].strip()


def _function_at_offset(functions: list[tuple[int, str]], offset: int) -> str:
    current = ""
    for function_offset, name in functions:
        if function_offset > offset:
            break
        current = name
    return current


def _canonical(route: str, section: dict) -> str:
    normalized = route.strip().lstrip("/")
    return str(section.get("aliases", {}).get(normalized, normalized))


def _classified(route: str, section: dict, *, websocket: bool) -> bool:
    lowered = route.strip().lower()
    schemes = ("ws://", "wss://") if websocket else ("http://", "https://")
    if lowered.startswith(schemes):
        return False
    canonical = _canonical(route, section)
    return canonical in section.get("public", []) or canonical in section.get(
        "auth_required", []
    )


def _dynamic_allowed(
    policy: dict, path: str, function: str, api: str
) -> bool:
    return any(
        item.get("path") == path
        and item.get("function") == function
        and item.get("api") == api
        for item in policy.get("dynamic_high_level_calls", [])
    )


def audit_repository(root: Path, policy_path: Path) -> list[Violation]:
    root = root.resolve()
    policy = json.loads(policy_path.read_text(encoding="utf-8"))
    raw_allowlist: dict = policy.get("raw_transport_allowlist", {})
    violations: list[Violation] = []

    scripts_dir = root / "scripts"
    if not scripts_dir.is_dir():
        return violations

    for script in sorted(scripts_dir.rglob("*.gd")):
        relative = script.relative_to(root).as_posix()
        source = script.read_text(encoding="utf-8-sig")
        clean_source = "\n".join(_strip_line_comment(line) for line in source.splitlines())
        functions = [
            (match.start(), match.group(1))
            for match in re.finditer(
                r"^\s*func\s+([A-Za-z_]\w*)\s*\(",
                clean_source,
                flags=re.MULTILINE,
            )
        ]
        for number, original in enumerate(
            source.splitlines(), start=1
        ):
            line = _strip_line_comment(original)
            if not line.strip():
                continue

            if "cookies.get_auth_header" in line:
                violations.append(
                    Violation(
                        relative,
                        number,
                        "ambiguous-auth-header",
                        "Use bearer readiness or transport-owned authorization.",
                    )
                )

            if re.search(r"\bweb\s*\.\s*_request\s*\(", line):
                if relative not in raw_allowlist.get("web._request", []):
                    violations.append(
                        Violation(
                            relative,
                            number,
                            "raw-request-owner",
                            "web._request is restricted to approved auth adapters.",
                        )
                    )

            for primitive, pattern in _RAW_PATTERNS.items():
                if pattern.search(line) and relative not in raw_allowlist.get(
                    primitive, []
                ):
                    violations.append(
                        Violation(
                            relative,
                            number,
                            "raw-transport-owner",
                            f"{primitive} is not approved in this file.",
                        )
                    )

        for call in _HIGH_LEVEL_RE.finditer(clean_source):
            api = call.group("api")
            argument = _first_argument(clean_source, call.end())
            route = _literal_value(argument)
            number = clean_source.count("\n", 0, call.start()) + 1
            current_function = _function_at_offset(functions, call.start())
            if route is None:
                if not _dynamic_allowed(policy, relative, current_function, api):
                    violations.append(
                        Violation(
                            relative,
                            number,
                            "dynamic-network-route",
                            f"Dynamic {api} route is not narrowly allowlisted.",
                        )
                    )
                continue
            websocket = api == "sockets.connect_to"
            lowered = route.strip().lower()
            schemes = ("ws://", "wss://") if websocket else ("http://", "https://")
            if lowered.startswith(schemes):
                if not _dynamic_allowed(policy, relative, current_function, api):
                    violations.append(
                        Violation(
                            relative,
                            number,
                            "unapproved-external-route",
                            f"External route {route!r} is not narrowly allowlisted.",
                        )
                    )
                continue
            section = policy["websocket" if websocket else "rest"]
            if not _classified(route, section, websocket=websocket):
                violations.append(
                    Violation(
                        relative,
                        number,
                        "unclassified-websocket-route"
                        if websocket
                        else "unclassified-rest-route",
                        f"Route {route!r} is absent from the endpoint policy.",
                    )
                )

    return violations


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit Neuralese network boundaries")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--policy", type=Path)
    args = parser.parse_args()
    policy = args.policy or args.root / "resources" / "network_endpoint_policy.json"
    violations = audit_repository(args.root, policy)
    if not violations:
        print("Network boundary audit passed")
        return 0
    for item in violations:
        print(f"{item.path}:{item.line}: {item.rule}: {item.message}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
