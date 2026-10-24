from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from tools.jasondocs.cli import find_repo_root

from .generator import stale_outputs, validate_runtime_handlers, write_outputs
from .model import NodeDefinition, NodeDefinitionError
from .registry import NodeRegistry


def _stdio_utf8() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")


def _registry(args: argparse.Namespace) -> NodeRegistry:
    root = Path(args.repo_root).resolve() if args.repo_root else find_repo_root(Path.cwd())
    definitions = Path(args.definitions)
    if not definitions.is_absolute():
        definitions = root / definitions
    return NodeRegistry(root, definitions)


def cmd_list(args: argparse.Namespace) -> int:
    nodes = _registry(args).resolve()
    for node in nodes:
        marker = "menu" if node.definition.menu["visible"] else "hidden"
        source = node.definition.source
        print(
            f"{node.id:14} {marker:6} {source['kind']:8} {source['path']} "
            f"server={node.server_typename or '-'} runtime={node.definition.runtime.get('handler', '-')}"
        )
    print(f"{len(nodes)} registered nodes")
    return 0


def cmd_inspect(args: argparse.Namespace) -> int:
    nodes = {node.id: node for node in _registry(args).resolve()}
    if args.node_id not in nodes:
        print(f"unknown node: {args.node_id}", file=sys.stderr)
        return 2
    print(json.dumps(nodes[args.node_id].development_dict(), ensure_ascii=False, indent=2))
    return 0


def cmd_discover(args: argparse.Namespace) -> int:
    candidates = _registry(args).discover_scene_candidates()
    if args.format == "json":
        print(json.dumps(candidates, ensure_ascii=False, indent=2))
    else:
        for candidate in candidates:
            print(
                f"{candidate['suggested_id']:20} {candidate['scene']} "
                f"server={candidate['server_typename'] or '-'} script={candidate['script'] or '-'}"
            )
        print(f"{len(candidates)} unregistered BaseGraph scene(s)")
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    registry = _registry(args)
    nodes = registry.resolve()
    errors = validate_runtime_handlers(registry, nodes)
    if errors:
        for error in errors:
            print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    print(f"Node definitions valid: {len(nodes)} nodes")
    return 0


def cmd_generate(args: argparse.Namespace) -> int:
    registry = _registry(args)
    nodes = registry.resolve()
    errors = validate_runtime_handlers(registry, nodes)
    if errors:
        for error in errors:
            print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    for message in write_outputs(registry):
        print(message)
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    registry = _registry(args)
    nodes = registry.resolve()
    errors = validate_runtime_handlers(registry, nodes)
    stale = stale_outputs(registry)
    for error in errors:
        print(f"[ERROR] {error}", file=sys.stderr)
    for path in stale:
        print(f"[ERROR] stale generated file: {path.relative_to(registry.root)}", file=sys.stderr)
    if errors or stale:
        print("Run: python -m tools.node_dev generate", file=sys.stderr)
        return 1
    print(f"Node developer check passed: {len(nodes)} nodes")
    return 0


def _find_godot_binary(explicit: str | None) -> str | None:
    candidates = [explicit, os.environ.get("GODOT_BIN")]
    candidates.extend(shutil.which(name) for name in ("godot4", "godot", "godot4.7"))
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate).resolve())
    return None


def cmd_godot_check(args: argparse.Namespace) -> int:
    registry = _registry(args)
    nodes = registry.resolve()
    errors = validate_runtime_handlers(registry, nodes)
    stale = stale_outputs(registry)
    for error in errors:
        print(f"[ERROR] {error}", file=sys.stderr)
    for path in stale:
        print(f"[ERROR] stale generated file: {path.relative_to(registry.root)}", file=sys.stderr)
    if errors or stale:
        print("Run: python -m tools.node_dev generate", file=sys.stderr)
        return 1

    godot_binary = _find_godot_binary(args.godot_bin)
    if godot_binary is None:
        print(
            "[ERROR] Godot editor binary not found; pass --godot-bin or set GODOT_BIN",
            file=sys.stderr,
        )
        return 2

    validator = registry.root / "tools" / "node_dev" / "godot_validate.gd"
    if not validator.is_file():
        print(f"[ERROR] Godot validator script not found: {validator}", file=sys.stderr)
        return 1

    command = [
        godot_binary,
        "--headless",
        "--path",
        str(registry.root),
        "--script",
        str(validator),
    ]
    try:
        completed = subprocess.run(
            command,
            cwd=registry.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=args.timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        if exc.stdout:
            print(exc.stdout, end="" if exc.stdout.endswith("\n") else "\n")
        print(f"[ERROR] Godot node validation timed out after {args.timeout:g}s", file=sys.stderr)
        return 1

    marker = f"NODE_DEV_SOURCES_OK: {len(nodes)}"
    if completed.returncode != 0 or marker not in completed.stdout:
        if completed.stdout:
            print(completed.stdout, end="" if completed.stdout.endswith("\n") else "\n")
        print(
            f"[ERROR] Godot node validation failed (exit={completed.returncode}, expected {marker!r})",
            file=sys.stderr,
        )
        return 1
    print(f"Godot node source check passed: {len(nodes)} nodes")
    return 0


def _next_order(definitions: list[NodeDefinition], attr: str) -> int:
    if not definitions:
        return 0
    if attr == "load_order":
        return max(item.load_order for item in definitions) + 10
    return max(item.menu["order"] for item in definitions) + 10


def cmd_new(args: argparse.Namespace) -> int:
    registry = _registry(args)
    definitions = registry.load_definitions()
    if any(item.id == args.node_id for item in definitions):
        print(f"definition already exists: {args.node_id}", file=sys.stderr)
        return 2
    target = registry.definitions_dir / f"{args.node_id}.json"
    if target.exists():
        print(f"definition path already exists: {target.relative_to(registry.root)}", file=sys.stderr)
        return 2

    titles = {lang: getattr(args, f"title_{lang}") for lang in ("en", "ru", "kz")}
    if any(titles.values()) and not all(titles.values()):
        print("when overriding a title, --title-en, --title-ru and --title-kz are all required", file=sys.stderr)
        return 2
    if args.provider and not all(titles.values()):
        print("programmatic providers require --title-en, --title-ru and --title-kz", file=sys.stderr)
        return 2

    if args.scene:
        source = {"kind": "scene", "path": args.scene}
    else:
        source = {"kind": "provider", "path": args.provider}
        provider_path = registry.root / args.provider.removeprefix("res://")
        if not provider_path.exists():
            provider_path.parent.mkdir(parents=True, exist_ok=True)
            provider_path.write_text(
                "extends RefCounted\n\n\n"
                "func instantiate_node(_definition: Dictionary) -> Graph:\n"
                "\t# Build from existing Neuralese scenes/components and return a Graph.\n"
                "\tpush_error(\"Provider is not implemented yet\")\n"
                "\treturn null\n",
                encoding="utf-8",
            )
            print(f"created provider skeleton: {provider_path.relative_to(registry.root)}")

    display: dict[str, object] = {}
    if any(titles.values()):
        display["title"] = titles
    if args.outline_color:
        display["outline_color"] = args.outline_color
    if args.tuning_color:
        display["tuning_color"] = args.tuning_color

    runtime: dict[str, object] = {}
    if args.runtime_handler:
        runtime["handler"] = args.runtime_handler
    if args.runtime_alias:
        runtime["aliases"] = args.runtime_alias
    if args.runtime_role:
        runtime["roles"] = args.runtime_role
    if args.default_input_port:
        runtime["default_input_port"] = args.default_input_port
    if args.default_output_port:
        runtime["default_output_port"] = args.default_output_port
    llm: dict[str, object] = {"type": args.llm_type or args.node_id}
    if args.llm_alias:
        llm["aliases"] = args.llm_alias
    definition = NodeDefinition.from_dict(
        {
            "schema_version": 1,
            "id": args.node_id,
            "source": source,
            "load_order": args.load_order if args.load_order is not None else _next_order(definitions, "load_order"),
            "menu": {
                "visible": args.visible,
                "section": args.section,
                "order": args.menu_order if args.menu_order is not None else _next_order(definitions, "menu_order"),
            },
            "roles": args.role or [],
            "llm": llm,
            "runtime": runtime,
            "display": display,
        }
    )
    registry.write_definition(target, definition)
    print(f"created definition: {target.relative_to(registry.root)}")
    try:
        registry.resolve()
    except Exception:
        target.unlink(missing_ok=True)
        raise
    for message in write_outputs(registry):
        print(message)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="node-dev",
        description="Generate static Neuralese node catalogs with no runtime scanning.",
    )
    parser.add_argument("--repo-root", default=None)
    parser.add_argument("--definitions", default="node_defs")
    sub = parser.add_subparsers(dest="command", required=True)

    list_cmd = sub.add_parser("list", help="List registered nodes and their sources.")
    list_cmd.set_defaults(func=cmd_list)
    inspect = sub.add_parser("inspect", help="Show a node definition plus discovered scene contracts.")
    inspect.add_argument("node_id")
    inspect.set_defaults(func=cmd_inspect)
    discover = sub.add_parser("discover", help="Find unregistered scenes that inherit BaseGraph.")
    discover.add_argument("--format", choices=("text", "json"), default="text")
    discover.set_defaults(func=cmd_discover)
    validate = sub.add_parser("validate", help="Validate definitions, sources, aliases and handlers.")
    validate.set_defaults(func=cmd_validate)
    generate = sub.add_parser("generate", help="Generate static Godot and Python catalogs.")
    generate.set_defaults(func=cmd_generate)
    check = sub.add_parser("check", help="Fail when generated catalogs are stale or invalid.")
    check.set_defaults(func=cmd_check)
    godot_check = sub.add_parser(
        "godot-check",
        help="Development-only: ask the Godot editor to validate all generated PackedScene sources.",
    )
    godot_check.add_argument("--godot-bin", help="Godot editor/console executable; GODOT_BIN is the fallback.")
    godot_check.add_argument("--timeout", type=float, default=60.0)
    godot_check.set_defaults(func=cmd_godot_check)

    new = sub.add_parser("new", help="Register an existing scene or scaffold a programmatic provider.")
    new.add_argument("node_id")
    source = new.add_mutually_exclusive_group(required=True)
    source.add_argument("--scene", help="Existing res:// .tscn scene.")
    source.add_argument("--provider", help="res:// .gd provider; a skeleton is created if missing.")
    new.add_argument("--visible", action="store_true", help="Expose the node in the public add menu.")
    new.add_argument("--section", default="other")
    new.add_argument("--load-order", type=int, help="Graph deserialization order; inferred when omitted.")
    new.add_argument("--menu-order", type=int, help="Public menu group/order; inferred when omitted.")
    new.add_argument("--role", action="append")
    new.add_argument("--llm-type")
    new.add_argument("--llm-alias", action="append")
    new.add_argument("--runtime-handler")
    new.add_argument("--runtime-alias", action="append")
    new.add_argument("--runtime-role", action="append")
    new.add_argument("--default-input-port")
    new.add_argument("--default-output-port")
    new.add_argument("--title-en")
    new.add_argument("--title-ru")
    new.add_argument("--title-kz")
    new.add_argument("--outline-color", help="#rrggbbaa override; normally inferred from the scene.")
    new.add_argument("--tuning-color", help="#rrggbbaa override; normally inferred from the scene.")
    new.set_defaults(func=cmd_new)
    return parser


def main(argv: list[str] | None = None) -> int:
    _stdio_utf8()
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except NodeDefinitionError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
