from __future__ import annotations

from dataclasses import dataclass, field
import json
import re
from pathlib import Path, PurePosixPath
from typing import Any


NODE_ID_RE = re.compile(r"^[a-z][a-z0-9_]*$")
SOURCE_KINDS = {"scene", "provider"}
ROOT_FIELDS = {
    "schema_version",
    "id",
    "source",
    "load_order",
    "menu",
    "roles",
    "llm",
    "runtime",
    "display",
}
SOURCE_FIELDS = {"kind", "path"}
MENU_FIELDS = {"visible", "section", "order"}
LLM_FIELDS = {"type", "aliases"}
RUNTIME_FIELDS = {
    "handler",
    "aliases",
    "roles",
    "default_input_port",
    "default_output_port",
}
DISPLAY_FIELDS = {"title", "outline_color", "tuning_color", "category"}
# Colour family of a node in the Pixel design (scripts/ui/design.gd).
DISPLAY_CATEGORIES = {"data", "learn", "ops", "shape", "output", "train"}


class NodeDefinitionError(ValueError):
    """A definition cannot be compiled safely."""


def _string_list(value: Any, field_name: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(item, str) and item for item in value):
        raise NodeDefinitionError(f"{field_name} must be an array of non-empty strings")
    result = list(value)
    if len(result) != len(set(result)):
        raise NodeDefinitionError(f"{field_name} must not contain duplicates")
    return result


def _reject_unknown(value: dict[str, Any], allowed: set[str], field_name: str) -> None:
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise NodeDefinitionError(f"{field_name} has unknown field(s): {', '.join(unknown)}")


def _optional_string(value: dict[str, Any], key: str, field_name: str) -> None:
    if key in value and (not isinstance(value[key], str) or not value[key].strip()):
        raise NodeDefinitionError(f"{field_name}.{key} must be a non-empty string")


@dataclass(frozen=True)
class NodeDefinition:
    id: str
    source: dict[str, Any]
    load_order: int
    menu: dict[str, Any]
    roles: list[str] = field(default_factory=list)
    llm: dict[str, Any] = field(default_factory=dict)
    runtime: dict[str, Any] = field(default_factory=dict)
    display: dict[str, Any] = field(default_factory=dict)
    schema_version: int = 1
    path: Path | None = field(default=None, compare=False)

    @classmethod
    def from_path(cls, path: Path) -> "NodeDefinition":
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except Exception as exc:
            raise NodeDefinitionError(f"{path}: invalid JSON: {exc}") from exc
        if not isinstance(raw, dict):
            raise NodeDefinitionError(f"{path}: root must be an object")
        return cls.from_dict(raw, path=path)

    @classmethod
    def from_dict(cls, raw: dict[str, Any], path: Path | None = None) -> "NodeDefinition":
        location = str(path or "<definition>")
        _reject_unknown(raw, ROOT_FIELDS, location)
        required = {"schema_version", "id", "source", "load_order", "menu"}
        missing = sorted(required - set(raw))
        if missing:
            raise NodeDefinitionError(f"{location}: missing required field(s): {', '.join(missing)}")
        node_id = raw.get("id")
        if not isinstance(node_id, str) or not NODE_ID_RE.fullmatch(node_id):
            raise NodeDefinitionError(f"{location}: id must match {NODE_ID_RE.pattern}")
        if raw.get("schema_version") != 1:
            raise NodeDefinitionError(f"{node_id}: unsupported schema_version {raw.get('schema_version')!r}")

        source = raw.get("source")
        if not isinstance(source, dict) or source.get("kind") not in SOURCE_KINDS:
            raise NodeDefinitionError(f"{node_id}: source.kind must be one of {sorted(SOURCE_KINDS)}")
        _reject_unknown(source, SOURCE_FIELDS, f"{node_id}.source")
        source_path = source.get("path")
        if not isinstance(source_path, str) or not source_path.startswith("res://"):
            raise NodeDefinitionError(f"{node_id}: source.path must be a res:// path")
        if "\\" in source_path or ".." in PurePosixPath(source_path.removeprefix("res://")).parts:
            raise NodeDefinitionError(f"{node_id}: source.path must stay inside the Godot project")
        expected_suffix = ".tscn" if source["kind"] == "scene" else ".gd"
        if not source_path.endswith(expected_suffix):
            raise NodeDefinitionError(
                f"{node_id}: {source['kind']} source.path must end with {expected_suffix}"
            )

        load_order = raw.get("load_order")
        if not isinstance(load_order, int) or isinstance(load_order, bool) or load_order < 0:
            raise NodeDefinitionError(f"{node_id}: load_order must be a non-negative integer")

        menu = raw.get("menu", {})
        if not isinstance(menu, dict):
            raise NodeDefinitionError(f"{node_id}: menu must be an object")
        _reject_unknown(menu, MENU_FIELDS, f"{node_id}.menu")
        visible = menu.get("visible", True)
        order = menu.get("order", load_order)
        section = menu.get("section", "other")
        if not isinstance(visible, bool):
            raise NodeDefinitionError(f"{node_id}: menu.visible must be boolean")
        if not isinstance(order, int) or isinstance(order, bool) or order < 0:
            raise NodeDefinitionError(f"{node_id}: menu.order must be a non-negative integer")
        if not isinstance(section, str) or not section:
            raise NodeDefinitionError(f"{node_id}: menu.section must be a non-empty string")
        menu = {**menu, "visible": visible, "order": order, "section": section}

        roles = _string_list(raw.get("roles"), f"{node_id}.roles")
        llm = raw.get("llm", {})
        runtime = raw.get("runtime", {})
        display = raw.get("display", {})
        for name, value in (("llm", llm), ("runtime", runtime), ("display", display)):
            if not isinstance(value, dict):
                raise NodeDefinitionError(f"{node_id}: {name} must be an object")
        _reject_unknown(llm, LLM_FIELDS, f"{node_id}.llm")
        _reject_unknown(runtime, RUNTIME_FIELDS, f"{node_id}.runtime")
        _reject_unknown(display, DISPLAY_FIELDS, f"{node_id}.display")
        _optional_string(llm, "type", f"{node_id}.llm")
        for key in ("handler", "default_input_port", "default_output_port"):
            _optional_string(runtime, key, f"{node_id}.runtime")
        _string_list(llm.get("aliases"), f"{node_id}.llm.aliases")
        _string_list(runtime.get("aliases"), f"{node_id}.runtime.aliases")
        _string_list(runtime.get("roles"), f"{node_id}.runtime.roles")

        category = display.get("category")
        if category is not None and category not in DISPLAY_CATEGORIES:
            raise NodeDefinitionError(
                f"{node_id}: display.category must be one of {sorted(DISPLAY_CATEGORIES)}"
            )

        title = display.get("title", {})
        if not isinstance(title, dict):
            raise NodeDefinitionError(f"{node_id}: display.title must be an object")
        _reject_unknown(title, {"en", "ru", "kz"}, f"{node_id}.display.title")
        for lang, value in title.items():
            if not isinstance(value, str) or not value.strip():
                raise NodeDefinitionError(f"{node_id}: display.title.{lang} must be a non-empty string")

        return cls(
            id=node_id,
            source=dict(source),
            load_order=load_order,
            menu=menu,
            roles=roles,
            llm=dict(llm),
            runtime=dict(runtime),
            display=dict(display),
            schema_version=1,
            path=path,
        )

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "schema_version": self.schema_version,
            "id": self.id,
            "source": self.source,
            "load_order": self.load_order,
            "menu": self.menu,
        }
        if self.roles:
            result["roles"] = self.roles
        if self.llm:
            result["llm"] = self.llm
        if self.runtime:
            result["runtime"] = self.runtime
        if self.display:
            result["display"] = self.display
        return result

    def runtime_aliases(self, server_typename: str | None) -> list[str]:
        aliases = [self.id]
        if server_typename:
            aliases.append(server_typename)
        aliases.extend(_string_list(self.runtime.get("aliases"), f"{self.id}.runtime.aliases"))
        return list(dict.fromkeys(alias for alias in aliases if alias))

    def llm_aliases(self) -> list[str]:
        canonical = self.llm.get("type", self.id)
        aliases = [canonical, self.id]
        aliases.extend(_string_list(self.llm.get("aliases"), f"{self.id}.llm.aliases"))
        return list(dict.fromkeys(alias for alias in aliases if alias))
