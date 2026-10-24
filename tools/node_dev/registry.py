from __future__ import annotations

from dataclasses import dataclass
import json
import re
from pathlib import Path
from typing import Any, Iterable

from tools.jasondocs.godot_static import (
    GodotStaticAnalyzer,
    NodeInfo,
    SceneInfo,
    godot_to_fs,
)

from .model import NodeDefinition, NodeDefinitionError


LANGUAGES = ("en", "ru", "kz")


@dataclass(frozen=True)
class ResolvedNode:
    definition: NodeDefinition
    node_info: NodeInfo | None
    title: dict[str, str]
    outline_color: str
    tuning_color: str
    script_hooks: tuple[str, ...]
    scene_components: tuple[str, ...]
    scene_nodes: tuple[dict[str, str], ...]

    @property
    def id(self) -> str:
        return self.definition.id

    @property
    def server_typename(self) -> str | None:
        return self.node_info.server_typename if self.node_info else None

    def development_dict(self) -> dict[str, Any]:
        info = self.node_info
        return {
            **self.definition.to_dict(),
            "resolved": {
                "title": self.title,
                "outline_color": self.outline_color,
                "tuning_color": self.tuning_color,
                "server_typename": self.server_typename,
                "script": info.script_path if info else None,
                "inherits_graph": info.inherits_graph if info else None,
                "ports": [port.__dict__ for port in info.ports] if info else [],
                "settings": [setting.__dict__ for setting in info.settings] if info else [],
                "script_hooks": list(self.script_hooks),
                "scene_components": list(self.scene_components),
                "scene_nodes": list(self.scene_nodes),
            },
        }


class NodeRegistry:
    """Loads node definitions and enriches them using the existing JasonDocs scene analyzer."""

    def __init__(self, root: Path, definitions_dir: Path | None = None):
        self.root = root.resolve()
        self.definitions_dir = (definitions_dir or self.root / "node_defs").resolve()
        self.analyzer = GodotStaticAnalyzer(self.root)

    def load_definitions(self) -> list[NodeDefinition]:
        if not self.definitions_dir.is_dir():
            raise NodeDefinitionError(f"definitions directory does not exist: {self.definitions_dir}")
        definitions = [
            NodeDefinition.from_path(path)
            for path in sorted(self.definitions_dir.glob("*.json"))
            if path.name != "catalog.json"
        ]
        seen_ids: dict[str, Path | None] = {}
        seen_load_order: dict[int, str] = {}
        seen_public_menu_order: dict[int, str] = {}
        for definition in definitions:
            if definition.id in seen_ids:
                raise NodeDefinitionError(
                    f"duplicate id {definition.id}: {seen_ids[definition.id]} and {definition.path}"
                )
            seen_ids[definition.id] = definition.path
            if definition.load_order in seen_load_order:
                other = seen_load_order[definition.load_order]
                raise NodeDefinitionError(
                    f"duplicate load_order {definition.load_order}: {other} and {definition.id}"
                )
            seen_load_order[definition.load_order] = definition.id
            if definition.menu["visible"]:
                menu_order = int(definition.menu["order"])
                if menu_order in seen_public_menu_order:
                    other = seen_public_menu_order[menu_order]
                    raise NodeDefinitionError(
                        f"duplicate public menu.order {menu_order}: {other} and {definition.id}"
                    )
                seen_public_menu_order[menu_order] = definition.id
        return sorted(definitions, key=lambda item: (item.load_order, item.id))

    def resolve(self) -> list[ResolvedNode]:
        resolved: list[ResolvedNode] = []
        for definition in self.load_definitions():
            source_path = godot_to_fs(self.root, definition.source["path"]).resolve()
            if not source_path.is_relative_to(self.root):
                raise NodeDefinitionError(
                    f"{definition.id}: source escapes the project: {definition.source['path']}"
                )
            if not source_path.is_file():
                raise NodeDefinitionError(f"{definition.id}: source does not exist: {definition.source['path']}")
            if definition.source["kind"] == "provider":
                text = source_path.read_text(encoding="utf-8", errors="replace")
                if not re.search(r"^func\s+instantiate_node\s*\(", text, re.MULTILINE):
                    raise NodeDefinitionError(
                        f"{definition.id}: provider must implement func instantiate_node(definition)"
                    )
                overrides = definition.display.get("title", {})
                if any(not str(overrides.get(language, "")).strip() for language in LANGUAGES):
                    raise NodeDefinitionError(
                        f"{definition.id}: providers require display.title.en/ru/kz"
                    )
                title = self._resolved_title(definition, {lang: definition.id for lang in LANGUAGES})
                resolved.append(
                    ResolvedNode(
                        definition=definition,
                        node_info=None,
                        title=title,
                        outline_color=self._display_color(definition, "outline_color", "#ffffffff"),
                        tuning_color=self._display_color(definition, "tuning_color", "#000000a3"),
                        script_hooks=("instantiate_node",),
                        scene_components=(),
                        scene_nodes=(),
                    )
                )
                continue

            scene = self.analyzer.parse_scene(source_path)
            info = self.analyzer.node_from_scene(definition.id, scene)
            if not info.inherits_graph:
                raise NodeDefinitionError(
                    f"{definition.id}: scene must inherit BaseGraph/Graph: {definition.source['path']}"
                )
            self._validate_scene_title_localization(definition, scene, info)
            title = self._resolved_title(definition, info.title_candidates)
            outline = self._display_color(
                definition,
                "outline_color",
                self._scene_color(scene, "instance_shader_parameters/outline_color", "#ffffffff"),
            )
            tuning = self._display_color(
                definition,
                "tuning_color",
                self._scene_color(scene, "instance_shader_parameters/tuning", "#000000a3"),
            )
            resolved.append(
                ResolvedNode(
                    definition=definition,
                    node_info=info,
                    title=title,
                    outline_color=outline,
                    tuning_color=tuning,
                    script_hooks=self._script_hooks(info.script_path),
                    scene_components=self._scene_components(scene),
                    scene_nodes=self._scene_nodes(scene),
                )
            )
        self._validate_cross_references(resolved)
        return resolved

    def public_nodes(self) -> list[ResolvedNode]:
        return sorted(
            (node for node in self.resolve() if node.definition.menu["visible"]),
            key=lambda node: (node.definition.menu["order"], node.definition.load_order, node.id),
        )

    def discover_scene_candidates(self) -> list[dict[str, Any]]:
        registered = {
            definition.source["path"]
            for definition in self.load_definitions()
            if definition.source["kind"] == "scene"
        }
        candidates: list[dict[str, Any]] = []
        for path in sorted((self.root / "scenes").rglob("*.tscn")):
            godot_path = "res://" + str(path.relative_to(self.root)).replace("\\", "/")
            if godot_path in registered:
                continue
            try:
                scene = self.analyzer.parse_scene(path)
                info = self.analyzer.node_from_scene(path.stem.lower(), scene)
            except Exception:
                continue
            if info.inherits_graph:
                candidates.append(
                    {
                        "suggested_id": path.stem.lower(),
                        "scene": godot_path,
                        "server_typename": info.server_typename,
                        "title": info.title_candidates,
                        "script": info.script_path,
                    }
                )
        return candidates

    def _resolved_title(self, definition: NodeDefinition, inferred: dict[str, str]) -> dict[str, str]:
        overrides = definition.display.get("title", {})
        result: dict[str, str] = {}
        for language in LANGUAGES:
            value = str(overrides.get(language, inferred.get(language, ""))).strip()
            if not value:
                raise NodeDefinitionError(
                    f"{definition.id}: missing {language} title; add Loc data to the scene or display.title.{language}"
                )
            result[language] = value
        return result

    def _validate_scene_title_localization(
        self,
        definition: NodeDefinition,
        scene: SceneInfo,
        info: NodeInfo,
    ) -> None:
        overrides = definition.display.get("title", {})
        missing = [language for language in LANGUAGES if not str(overrides.get(language, "")).strip()]
        if not missing:
            return

        title_info = info.localized_properties.get("title", {})
        values = title_info.get("values", {})
        if "en" in missing and not str(values.get("en", "")).strip():
            raise NodeDefinitionError(f"{definition.id}: title has no English base text")
        translated = [language for language in missing if language in {"ru", "kz"}]
        if not translated:
            return

        title_path = str(title_info.get("source_path", ""))
        title_node = self.analyzer._find_node(scene, title_path)
        source = title_node.prop(str(title_info.get("property", "text"))) if title_node else None
        loc = next(
            (
                node
                for node in scene.nodes
                if node.parent == title_path
                and "res://scripts/loc.gd"
                in self.analyzer._inheritance_chain(
                    self.analyzer._resolve_script(node, scene.ext_resources)
                )
            ),
            None,
        )
        if not source or loc is None:
            raise NodeDefinitionError(
                f"{definition.id}: title must use a child Loc or define display.title.en/ru/kz"
            )

        key = self.analyzer._sanitize_loc(source)
        prop_by_language = {"ru": "localizations_ru", "kz": "localizations_kz"}
        for language in translated:
            translations = self.analyzer._dict_string_map(loc.block, prop_by_language[language])
            value = next(iter(translations.values()), "") if len(translations) == 1 else translations.get(key, "")
            if not str(value).strip():
                raise NodeDefinitionError(
                    f"{definition.id}: title Loc is missing an explicit {language} translation for {source!r}"
                )

    @staticmethod
    def _display_color(definition: NodeDefinition, key: str, fallback: str) -> str:
        value = str(definition.display.get(key, fallback)).lower()
        if not re.fullmatch(r"#[0-9a-f]{8}", value):
            raise NodeDefinitionError(f"{definition.id}: display.{key} must be #rrggbbaa")
        return value

    def _scene_color(self, scene: SceneInfo, prop: str, fallback: str) -> str:
        rect = self.analyzer._graph_rect_node(scene)
        raw = self.analyzer._effective_prop(rect, scene, prop) if rect else None
        return self.analyzer._color_hex(raw) or fallback

    def _script_hooks(self, script_path: str | None) -> tuple[str, ...]:
        if not script_path:
            return ()
        path = godot_to_fs(self.root, script_path)
        if not path.is_file():
            return ()
        text = path.read_text(encoding="utf-8", errors="replace")
        return tuple(dict.fromkeys(re.findall(r"^func\s+(_[A-Za-z0-9_]+)\s*\(", text, re.MULTILINE)))

    @staticmethod
    def _scene_components(scene: SceneInfo) -> tuple[str, ...]:
        paths = [
            resource.path
            for resource in scene.ext_resources.values()
            if resource.type == "PackedScene"
        ]
        return tuple(dict.fromkeys(paths))

    @staticmethod
    def _scene_nodes(scene: SceneInfo) -> tuple[dict[str, str], ...]:
        result: list[dict[str, str]] = []
        for node in scene.nodes:
            entry = {
                "path": node.name if node.parent == "." else f"{node.parent}/{node.name}",
                "name": node.name,
                "parent": node.parent,
                "type": node.attrs.get("type", ""),
            }
            instance = node.attrs.get("instance", "")
            match = re.fullmatch(r"ExtResource\((.+)\)", instance)
            if match and match.group(1) in scene.ext_resources:
                entry["instance"] = scene.ext_resources[match.group(1)].path
            elif instance:
                entry["instance"] = instance
            result.append(entry)
        return tuple(result)

    @staticmethod
    def _validate_cross_references(nodes: Iterable[ResolvedNode]) -> None:
        llm_aliases: dict[str, str] = {}
        runtime_aliases: dict[str, tuple[str, tuple[str, ...], tuple[tuple[str, str], ...]]] = {}
        for node in nodes:
            for alias in node.definition.llm_aliases():
                existing = llm_aliases.get(alias)
                if existing and existing != node.id:
                    raise NodeDefinitionError(f"LLM alias {alias!r} belongs to both {existing} and {node.id}")
                llm_aliases[alias] = node.id

            handler = str(node.definition.runtime.get("handler", "")).strip()
            runtime = node.definition.runtime
            if not runtime:
                continue
            contract = (
                handler,
                tuple(sorted(runtime.get("roles", []))),
                tuple(
                    sorted(
                        (key, str(runtime[key]))
                        for key in ("default_input_port", "default_output_port")
                        if key in runtime
                    )
                ),
            )
            for alias in node.definition.runtime_aliases(node.server_typename):
                existing = runtime_aliases.get(alias)
                if existing and existing != contract:
                    raise NodeDefinitionError(
                        f"runtime type {alias!r} has conflicting contracts: {existing} and {contract}"
                    )
                runtime_aliases[alias] = contract

    @staticmethod
    def write_definition(path: Path, definition: NodeDefinition) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(definition.to_dict(), ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
