from __future__ import annotations

from dataclasses import dataclass, field
import json
import re
from pathlib import Path
from typing import Any

from .port_visual_labels import describe_port_visual


LANGS = ("en", "ru", "kz")


def strip_gd_comments(text: str) -> str:
    """Remove whole-line comments before simple GDScript pattern matching."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def to_repo_path(path: Path, root: Path) -> str:
    return str(path.relative_to(root)).replace("\\", "/")


def godot_to_fs(root: Path, godot_path: str) -> Path:
    if godot_path.startswith("res://"):
        return root / godot_path.removeprefix("res://")
    return root / godot_path


def fs_to_godot(root: Path, path: Path) -> str:
    return "res://" + to_repo_path(path, root)


def normalize_id(value: str) -> str:
    value = value.replace("res://", "")
    value = re.sub(r"[^A-Za-z0-9_]+", "_", value)
    value = re.sub(r"_+", "_", value).strip("_").lower()
    return value or "unnamed"


def pascal_graph_id(graph_id: str) -> str:
    return "".join(part[:1].upper() + part[1:] for part in graph_id.split("_") if part)


def clean_godot_value(value: str | None) -> str | None:
    if value is None:
        return None
    value = value.strip().rstrip(",")
    if value.startswith("&"):
        value = value[1:]
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    if value in ("null", "nil"):
        return None
    return value


def parse_scalar(value: str) -> Any:
    value = clean_godot_value(value)
    if value is None:
        return None
    if value in ("true", "false"):
        return value == "true"
    if re.fullmatch(r"-?\d+", value):
        return int(value)
    if re.fullmatch(r"-?\d+\.\d+", value):
        return float(value)
    return value


def parse_header_attrs(header: str) -> dict[str, str]:
    attrs: dict[str, str] = {}
    for key, value in re.findall(r"(\w+)=\"([^\"]*)\"", header):
        attrs[key] = value
    for key, value in re.findall(r"(\w+)=ExtResource\(\"([^\"]+)\"\)", header):
        attrs[key] = f"ExtResource({value})"
    for key, value in re.findall(r"(\w+)=SubResource\(\"([^\"]+)\"\)", header):
        attrs[key] = f"SubResource({value})"
    return attrs


@dataclass
class ExtResource:
    id: str
    type: str | None
    path: str
    uid: str | None = None


@dataclass
class SceneNode:
    name: str
    parent: str
    header: str
    attrs: dict[str, str]
    block: str

    def prop(self, name: str) -> str | None:
        match = re.search(r"^" + re.escape(name) + r"\s*=\s*(.+)$", self.block, re.MULTILINE)
        return clean_godot_value(match.group(1)) if match else None

    def raw_prop(self, name: str) -> str | None:
        match = re.search(r"^" + re.escape(name) + r"\s*=\s*(.+)$", self.block, re.MULTILINE)
        return match.group(1).strip() if match else None


@dataclass
class SceneInfo:
    path: str
    uid: str | None
    ext_resources: dict[str, ExtResource]
    nodes: list[SceneNode]

    @property
    def root(self) -> SceneNode | None:
        return self.nodes[0] if self.nodes else None


@dataclass
class ScriptInfo:
    path: str
    extends: str | None
    class_name: str | None
    has_useful_properties: bool
    has_config_field: bool
    has_is_valid: bool
    update_config_keys: list[str] = field(default_factory=list)
    cfg_keys: list[str] = field(default_factory=list)
    config_field_cases: list[str] = field(default_factory=list)


@dataclass
class PortInfo:
    id: str
    scene_node: str
    scene_path: str
    hint: int
    server_name: str | None
    direction: str
    datatypes: list[str]
    multiple: bool
    config_conn: bool
    keyword: str | None
    conn_count_keyword: str | None
    visual: dict[str, Any] = field(default_factory=dict)


@dataclass
class SettingInfo:
    id: str
    source: str
    default: Any = None
    ui_kind: str | None = None
    ui_path: str | None = None
    options: list[dict[str, str | None]] = field(default_factory=list)


@dataclass
class NodeInfo:
    node_id: str
    created_with: str
    scene_path: str
    scene_uid: str | None
    root_instance_path: str | None
    script_path: str | None
    inheritance_chain: list[str]
    inherits_graph: bool
    server_typename: str | None
    layer_name: str | None
    title_candidates: dict[str, str]
    base_config: dict[str, Any]
    ports: list[PortInfo]
    settings: list[SettingInfo]
    icon_source: str | None
    localized_properties: dict[str, Any] = field(default_factory=dict)
    static_compatible_nodes: list[dict[str, Any]] = field(default_factory=list)

    def to_generated(self) -> dict[str, Any]:
        return {
            "node_id": self.node_id,
            "created_with": self.created_with,
            "scene_path": self.scene_path,
            "scene_uid": self.scene_uid,
            "root_instance_path": self.root_instance_path,
            "script_path": self.script_path,
            "inheritance_chain": self.inheritance_chain,
            "inherits_graph": self.inherits_graph,
            "server_typename": self.server_typename,
            "layer_name": self.layer_name,
            "title_candidates": self.title_candidates,
            "localized_properties": self.localized_properties,
            "base_config": self.base_config,
            "ports": [port.__dict__ for port in self.ports],
            "settings": [setting.__dict__ for setting in self.settings],
            "icon_source": self.icon_source,
            "static_compatible_nodes": self.static_compatible_nodes,
        }


class GodotStaticAnalyzer:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.scripts = self._load_scripts()
        self.class_to_script = {
            info.class_name: path for path, info in self.scripts.items() if info.class_name
        }

    def scan(self) -> list[NodeInfo]:
        graph_types = self.graph_types()
        creation_ids = self.creation_type_ids(graph_types)
        nodes: list[NodeInfo] = []
        for node_id in creation_ids:
            scene_path = graph_types.get(node_id)
            if not scene_path:
                continue
            scene = self.parse_scene(godot_to_fs(self.root, scene_path))
            nodes.append(self._node_from_scene(node_id, scene))
        self._attach_static_compatibility(nodes)
        return nodes

    def graph_types(self) -> dict[str, str]:
        definitions = self._node_definition_documents()
        if definitions:
            return {
                str(document["id"]): str(document["source"]["path"])
                for document in sorted(
                    definitions,
                    key=lambda item: (int(item.get("load_order", 0)), str(item.get("id", ""))),
                )
                if document.get("source", {}).get("kind") == "scene"
            }
        return self.legacy_graph_types()

    def legacy_graph_types(self) -> dict[str, str]:
        graph_manager = self.root / "scripts" / "graph_manager.gd"
        text = strip_gd_comments(graph_manager.read_text(encoding="utf-8", errors="replace"))
        match = re.search(r"var\s+graph_types\s*=\s*\{(?P<body>.*?)^\}", text, re.MULTILINE | re.DOTALL)
        if not match:
            return {}
        body = match.group("body")
        found = re.findall(r'"([^"]+)"\s*:\s*gload\("([^"]+)"\)', body)
        return {key: path for key, path in found}

    def creation_type_ids(self, graph_types: dict[str, str]) -> list[str]:
        """Mirror GraphCreationCatalog.ordered_definitions for the public add menu.

        JasonDocs should describe nodes available through cmenu/node palette, not
        every registered graph type. We keep this static and project-independent:
        transient input hiding is intentionally not applied.
        """
        definitions = self._node_definition_documents()
        if definitions:
            return [
                str(document["id"])
                for document in sorted(
                    definitions,
                    key=lambda item: (
                        int(item.get("menu", {}).get("order", item.get("load_order", 0))),
                        str(item.get("id", "")),
                    ),
                )
                if document.get("source", {}).get("kind") == "scene"
                and bool(document.get("menu", {}).get("visible", True))
                and str(document.get("id", "")) in graph_types
            ]

        importance_chain = self._project_importance_chain()
        name_groups, skip = self._cmenu_catalog_settings()
        allowed = set(importance_chain) if importance_chain else set(graph_types)
        skipped = set(skip)
        definitions = [node_id for node_id in graph_types if node_id in allowed and node_id not in skipped]
        definitions_by_name = {node_id: node_id for node_id in definitions}
        ordered: list[str] = []
        added: set[str] = set()

        def append_definition(type_id: str) -> None:
            if not type_id or type_id in added or type_id not in definitions_by_name:
                return
            ordered.append(type_id)
            added.add(type_id)

        for group in name_groups:
            for type_id in group:
                append_definition(type_id)
        for type_id in definitions:
            append_definition(type_id)
        return ordered

    def _node_definition_documents(self) -> list[dict[str, Any]]:
        definitions_dir = self.root / "node_defs"
        if not definitions_dir.is_dir():
            return []
        documents: list[dict[str, Any]] = []
        for path in sorted(definitions_dir.glob("*.json")):
            try:
                document = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise ValueError(f"invalid node definition {path}: {exc}") from exc
            if not isinstance(document, dict) or not document.get("id") or not isinstance(document.get("source"), dict):
                raise ValueError(f"invalid node definition shape: {path}")
            documents.append(document)
        return documents

    def _project_importance_chain(self) -> list[str]:
        path = self.root / "scenes" / "project.tscn"
        if not path.exists():
            return []
        text = path.read_text(encoding="utf-8", errors="replace")
        match = re.search(r"^importance_chain\s*=\s*Array\[StringName\]\(\[(?P<body>.*?)\]\)", text, re.MULTILINE | re.DOTALL)
        if not match:
            return []
        return self._parse_string_array(match.group("body"))

    def _cmenu_catalog_settings(self) -> tuple[list[list[str]], list[str]]:
        path = self.root / "scenes" / "menus.tscn"
        if not path.exists():
            return [], []
        scene = self.parse_scene(path)
        cmenu_nodes = [
            node for node in scene.nodes
            if node.raw_prop("name_groups") is not None or node.raw_prop("skip") is not None
        ]
        selected = None
        for node in cmenu_nodes:
            if node.name == "add_graph":
                selected = node
                break
        # Prefer the actual add menu over select-node helper menus when possible.
        if selected is None:
            for node in cmenu_nodes:
                if "select" not in node.name.lower():
                    selected = node
                    break
        if selected is None and cmenu_nodes:
            selected = cmenu_nodes[0]
        if selected is None:
            return [], []
        return self._parse_packed_string_array_groups(selected.raw_prop("name_groups") or ""), self._parse_string_array(selected.raw_prop("skip") or "")

    @staticmethod
    def _parse_string_array(raw: str) -> list[str]:
        return [a or b for a, b in re.findall(r'&"([^"]+)"|"([^"]+)"', raw)]

    @staticmethod
    def _parse_packed_string_array_groups(raw: str) -> list[list[str]]:
        groups: list[list[str]] = []
        for body in re.findall(r"PackedStringArray\((\[[^\)]*?\])\)", raw, re.DOTALL):
            groups.append(GodotStaticAnalyzer._parse_string_array(body))
        return groups

    def parse_scene(self, path: Path) -> SceneInfo:
        text = path.read_text(encoding="utf-8", errors="replace")
        uid_match = re.search(r"^\[gd_scene[^\]]*uid=\"([^\"]+)\"", text, re.MULTILINE)
        ext_resources: dict[str, ExtResource] = {}
        for match in re.finditer(r"^\[ext_resource(?P<body>[^\]]+)\]", text, re.MULTILINE):
            attrs = parse_header_attrs("[ext_resource" + match.group("body") + "]")
            resource_id = attrs.get("id")
            resource_path = attrs.get("path")
            if resource_id and resource_path:
                ext_resources[resource_id] = ExtResource(
                    id=resource_id,
                    type=attrs.get("type"),
                    path=resource_path,
                    uid=attrs.get("uid"),
                )

        starts = [m.start() for m in re.finditer(r"^\[node ", text, re.MULTILINE)]
        scene_nodes: list[SceneNode] = []
        for index, start in enumerate(starts):
            end = starts[index + 1] if index + 1 < len(starts) else len(text)
            block = text[start:end]
            header = block.splitlines()[0]
            attrs = parse_header_attrs(header)
            scene_nodes.append(
                SceneNode(
                    name=attrs.get("name", ""),
                    parent=attrs.get("parent", "."),
                    header=header,
                    attrs=attrs,
                    block=block,
                )
            )
        return SceneInfo(
            path=fs_to_godot(self.root, path),
            uid=uid_match.group(1) if uid_match else None,
            ext_resources=ext_resources,
            nodes=scene_nodes,
        )

    def _load_scripts(self) -> dict[str, ScriptInfo]:
        result: dict[str, ScriptInfo] = {}
        scripts_dir = self.root / "scripts"
        for path in scripts_dir.rglob("*.gd"):
            text = path.read_text(encoding="utf-8", errors="replace")
            godot_path = fs_to_godot(self.root, path)
            extends = self._first_match(text, r"^extends\s+([^\s#]+)")
            class_name = self._first_match(text, r"^class_name\s+([^\s#]+)")
            result[godot_path] = ScriptInfo(
                path=godot_path,
                extends=extends.strip('"') if extends else None,
                class_name=class_name,
                has_useful_properties=bool(re.search(r"^func\s+_useful_properties\s*\(", text, re.MULTILINE)),
                has_config_field=bool(re.search(r"^func\s+_config_field\s*\(", text, re.MULTILINE)),
                has_is_valid=bool(re.search(r"^func\s+_is_valid\s*\(", text, re.MULTILINE)),
                update_config_keys=sorted(set(re.findall(r'(?<!\.)\bupdate_config(?:_subfield)?\s*\(\s*\{[^}]*"([^"]+)"\s*:', text))),
                cfg_keys=sorted(set(re.findall(r'cfg\s*\[\s*"([^"]+)"\s*\]', text))),
                config_field_cases=self._config_field_cases(text),
            )
        return result

    @staticmethod
    def _config_field_cases(text: str) -> list[str]:
        match = re.search(
            r"^func\s+_config_field\s*\([^)]*\):(?P<body>.*?)(?=^func\s|\Z)",
            text,
            re.MULTILINE | re.DOTALL,
        )
        if not match:
            return []
        body = match.group("body")
        return sorted(set(re.findall(r"^\s*\"([^\"]+)\"\s*:\s*$", body, re.MULTILINE)))

    @staticmethod
    def _first_match(text: str, pattern: str) -> str | None:
        match = re.search(pattern, text, re.MULTILINE)
        return match.group(1) if match else None

    def _node_from_scene(self, node_id: str, scene: SceneInfo) -> NodeInfo:
        root = scene.root
        script_path = self._resolve_script(root, scene.ext_resources) if root else None
        root_instance_path = self._resolve_instance(root, scene.ext_resources) if root else None
        inheritance_chain = self._inheritance_chain(script_path)
        base_config = self._parse_base_config(root.block if root else "")
        ports = self._parse_ports(scene)
        controls = self._parse_controls(scene)
        settings = self._settings(base_config, controls, script_path)
        localized = self._localized_properties(scene, settings, ports)
        return NodeInfo(
            node_id=node_id,
            created_with=node_id,
            scene_path=scene.path,
            scene_uid=scene.uid,
            root_instance_path=root_instance_path,
            script_path=script_path,
            inheritance_chain=inheritance_chain,
            inherits_graph=self._inherits_graph(inheritance_chain, root_instance_path),
            server_typename=root.prop("server_typename") if root else None,
            layer_name=root.prop("layer_name") if root else None,
            title_candidates=localized.get("title", {}).get("values", self._title_candidates(scene)),
            localized_properties=localized,
            base_config=base_config,
            ports=ports,
            settings=settings,
            icon_source=self._icon_source(node_id),
        )

    def node_from_scene(self, node_id: str, scene: SceneInfo) -> NodeInfo:
        """Public adapter reused by development-time node tooling."""
        return self._node_from_scene(node_id, scene)

    def _resolve_script(self, node: SceneNode | None, resources: dict[str, ExtResource]) -> str | None:
        if not node:
            return None
        raw = node.raw_prop("script")
        if not raw:
            return None
        match = re.search(r'ExtResource\("([^"]+)"\)', raw)
        if not match:
            return None
        resource = resources.get(match.group(1))
        return resource.path if resource else None

    def _resolve_instance(self, node: SceneNode | None, resources: dict[str, ExtResource]) -> str | None:
        if not node:
            return None
        raw = node.attrs.get("instance")
        if not raw:
            return None
        match = re.search(r"ExtResource\(([^)]+)\)", raw)
        if not match:
            return None
        resource = resources.get(match.group(1))
        return resource.path if resource else None

    def _inheritance_chain(self, script_path: str | None) -> list[str]:
        chain: list[str] = []
        current = script_path
        seen: set[str] = set()
        while current and current not in seen:
            seen.add(current)
            chain.append(current)
            info = self.scripts.get(current)
            if not info or not info.extends:
                break
            current = self.class_to_script.get(info.extends)
            if current is None and info.extends.startswith("res://"):
                current = info.extends
        return chain

    @staticmethod
    def _inherits_graph(chain: list[str], root_instance_path: str | None) -> bool:
        return (
            "res://scripts/base_graph.gd" in chain
            or "res://scripts/io_graph.gd" in chain
            or root_instance_path == "res://scenes/base_graph.tscn"
        )

    def _parse_base_config(self, block: str) -> dict[str, Any]:
        match = re.search(
            r"^base_config\s*=\s*Dictionary[^{]*\(\{(?P<body>.*?)^\}\)",
            block,
            re.MULTILINE | re.DOTALL,
        )
        if not match:
            return {}
        body = match.group("body")
        result: dict[str, Any] = {}
        for line in body.splitlines():
            item = re.match(r'\s*&?"([^"]+)"\s*:\s*(.+?)\s*,?\s*$', line)
            if item:
                result[item.group(1)] = parse_scalar(item.group(2))
        return result

    def _parse_ports(self, scene: SceneInfo) -> list[PortInfo]:
        ports: list[PortInfo] = []
        used_ids: dict[str, int] = {}
        reference = self._graph_rect_node(scene)
        reference_rect = self._scene_rect(reference, scene) if reference else None
        reference_path = self._node_path(reference) if reference else None
        for node in scene.nodes:
            if not self._scene_node_is_visible(node, scene):
                continue
            instance_path = self._resolve_instance(node, scene.ext_resources)
            looks_like_connection = (
                instance_path == "res://scenes/Connection.tscn"
                or node.raw_prop("_accepted_datatypes") is not None
                or node.raw_prop("connection_type") is not None
                or node.raw_prop("server_name") is not None
            )
            if not looks_like_connection:
                continue
            direction = "output" if self._effective_prop(node, scene, "connection_type") == "1" else "input"
            hint_raw = node.prop("hint")
            try:
                hint = int(hint_raw) if hint_raw is not None else 0
            except ValueError:
                hint = 0
            server_name = node.prop("server_name")
            datatypes = (node.prop("_accepted_datatypes") or "").split()
            base_id_parts = [direction]
            if node.parent not in ("", "."):
                base_id_parts.append(node.parent)
            base_id_parts.extend([node.name, server_name or f"hint_{hint}"])
            base_id = normalize_id("_".join(base_id_parts))
            count = used_ids.get(base_id, 0) + 1
            used_ids[base_id] = count
            port_id = base_id if count == 1 else f"{base_id}_{count}"
            ports.append(
                PortInfo(
                    id=port_id,
                    scene_node=node.name,
                    scene_path=node.parent,
                    hint=hint,
                    server_name=server_name,
                    direction=direction,
                    datatypes=datatypes,
                    multiple=node.prop("multiple_splines") == "true",
                    config_conn=node.prop("config_conn") == "true",
                    keyword=node.prop("keyword"),
                    conn_count_keyword=node.prop("conn_count_keyword"),
                    visual=self._port_visual(node, scene, reference_rect, reference_path),
                )
            )
        return ports

    def _scene_node_is_visible(self, node: SceneNode, scene: SceneInfo) -> bool:
        current: SceneNode | None = node
        seen: set[tuple[str, str]] = set()
        while current is not None:
            key = (current.parent, current.name)
            if key in seen:
                break
            seen.add(key)
            if current.prop("visible") == "false":
                return False
            if current.parent in ("", "."):
                break
            current = self._find_node(scene, current.parent)
        return True

    def _graph_rect_node(self, scene: SceneInfo) -> SceneNode | None:
        root = scene.root
        if root:
            match = re.search(r'NodePath\("([^"]+)"\)', root.raw_prop("rect") or "")
            if match:
                return self._find_node(scene, match.group(1))
            script_path = self._resolve_script(root, scene.ext_resources)
            for path in self._inheritance_chain(script_path):
                script = godot_to_fs(self.root, path).read_text(encoding="utf-8", errors="replace")
                match = re.search(
                    r"(?:@onready\s+)?var\s+rect(?:\s*:[^=]+)?\s*=\s*(?:\$\"([^\"]+)\"|\$([A-Za-z0-9_/]+)|%([A-Za-z0-9_]+)|get_node\(\"([^\"]+)\"\))",
                    script,
                )
                if match:
                    target = next(value for value in match.groups() if value)
                    found = self._find_node(scene, target)
                    if found:
                        return found
        return None

    def _port_visual(self, node: SceneNode, scene: SceneInfo, reference_rect: dict[str, float] | None, reference_path: str | None) -> dict[str, Any]:
        port_rect = self._scene_rect(node, scene)
        dir_vector = self._parse_vector2(self._effective_prop(node, scene, "dir_vector")) or {"x": 1.0 if self._effective_prop(node, scene, "connection_type") == "1" else -1.0, "y": 0.0}
        origin = self._origin_from_rect(port_rect, dir_vector)
        color = self._color_hex(self._effective_prop(node, scene, "gradient_color") or self._effective_prop(node, scene, "color"))
        side = self._side_from_dir(dir_vector)
        visual: dict[str, Any] = {
            "color": self._color_hex(self._effective_prop(node, scene, "color")),
            "gradient_color": color,
            "dir_vector": dir_vector,
            "side": side,
            "relative_to": {"role": "graph_rect", "scene_path": reference_path},
            "absolute_scene_rect": port_rect,
        }
        if reference_rect and reference_rect["w"] and reference_rect["h"]:
            visual["reference_rect"] = reference_rect
            visual["relative_rect"] = {
                "x": (port_rect["x"] - reference_rect["x"]) / reference_rect["w"],
                "y": (port_rect["y"] - reference_rect["y"]) / reference_rect["h"],
                "w": port_rect["w"] / reference_rect["w"],
                "h": port_rect["h"] / reference_rect["h"],
            }
            visual["relative_origin"] = {
                "x": (origin["x"] - reference_rect["x"]) / reference_rect["w"],
                "y": (origin["y"] - reference_rect["y"]) / reference_rect["h"],
            }
        if color:
            visual.update(describe_port_visual(color, side))
        return visual

    def _scene_rect(self, node: SceneNode | None, scene: SceneInfo) -> dict[str, float]:
        if node is None:
            return {"x": 0.0, "y": 0.0, "w": 0.0, "h": 0.0}
        local = self._local_rect(node, scene)
        parent = self._find_node(scene, node.parent)
        if parent is None or node.parent in ("", "."):
            return local
        parent_rect = self._scene_rect(parent, scene)
        return {"x": parent_rect["x"] + local["x"], "y": parent_rect["y"] + local["y"], "w": local["w"], "h": local["h"]}

    def _find_node(self, scene: SceneInfo, path: str) -> SceneNode | None:
        if path in ("", "."):
            return None
        for node in scene.nodes:
            node_path = node.name if node.parent == "." else f"{node.parent}/{node.name}"
            if node_path == path:
                return node
        return None

    @staticmethod
    def _node_path(node: SceneNode | None) -> str | None:
        if node is None:
            return None
        return node.name if node.parent == "." else f"{node.parent}/{node.name}"

    def _local_rect(self, node: SceneNode, scene: SceneInfo) -> dict[str, float]:
        left = float(parse_scalar(self._effective_prop(node, scene, "offset_left") or "0") or 0)
        top = float(parse_scalar(self._effective_prop(node, scene, "offset_top") or "0") or 0)
        right = float(parse_scalar(self._effective_prop(node, scene, "offset_right") or "0") or 0)
        bottom = float(parse_scalar(self._effective_prop(node, scene, "offset_bottom") or "0") or 0)
        return {"x": left, "y": top, "w": right - left, "h": bottom - top}

    def _effective_prop(self, node: SceneNode, scene: SceneInfo, name: str) -> str | None:
        value = node.prop(name)
        if value is not None:
            return value
        root_instance = self._resolve_instance(scene.root, scene.ext_resources)
        if not root_instance:
            return None
        base_path = godot_to_fs(self.root, root_instance)
        if not base_path.is_file():
            return None
        base_scene = self.parse_scene(base_path)
        inherited = self._find_node(base_scene, self._node_path(node) or "")
        return self._effective_prop(inherited, base_scene, name) if inherited else None

    @staticmethod
    def _rect_area(rect: dict[str, float]) -> float:
        return abs(rect.get("w", 0.0) * rect.get("h", 0.0))

    @staticmethod
    def _parse_vector2(raw: str | None) -> dict[str, float] | None:
        if not raw:
            return None
        match = re.search(r"Vector2\(([^,]+),\s*([^)]+)\)", raw)
        if not match:
            return None
        return {"x": float(match.group(1)), "y": float(match.group(2))}

    @staticmethod
    def _origin_from_rect(rect: dict[str, float], direction: dict[str, float]) -> dict[str, float]:
        x = rect["x"] + rect["w"] / 2.0
        y = rect["y"] + rect["h"] / 2.0
        if direction["x"] > 0:
            x = rect["x"] + rect["w"]
        elif direction["x"] < 0:
            x = rect["x"]
        if direction["y"] > 0:
            y = rect["y"] + rect["h"]
        elif direction["y"] < 0:
            y = rect["y"]
        return {"x": x, "y": y}

    @staticmethod
    def _side_from_dir(direction: dict[str, float]) -> str:
        if abs(direction["x"]) >= abs(direction["y"]) and direction["x"] != 0:
            return "right" if direction["x"] > 0 else "left"
        if direction["y"] != 0:
            return "bottom" if direction["y"] > 0 else "top"
        return "inside"

    @staticmethod
    def _color_hex(raw: str | None) -> str | None:
        if not raw:
            return None
        match = re.search(r"Color\(([^)]+)\)", raw)
        if not match:
            return None
        values = [float(part.strip()) for part in match.group(1).split(",")]
        while len(values) < 4:
            values.append(1.0)
        channels = [max(0, min(255, round(value * 255))) for value in values[:4]]
        return "#" + "".join(f"{channel:02x}" for channel in channels)

    def _parse_controls(self, scene: SceneInfo) -> list[dict[str, Any]]:
        controls: list[dict[str, Any]] = []
        for node in scene.nodes:
            node_type = node.attrs.get("type")
            text = node.prop("text")
            hint = node.prop("hint")
            placeholder = node.prop("placeholder_text")
            is_control = (
                node_type in {"HSlider", "LineEdit", "TextEdit", "CheckBox", "OptionButton"}
                or hint is not None
                or placeholder is not None
            )
            if not is_control:
                continue
            controls.append(
                {
                    "name": node.name,
                    "path": node.parent if node.parent != "." else node.name,
                    "type": node_type or "instance",
                    "text": text,
                    "hint": hint,
                    "placeholder": placeholder,
                }
            )
        return controls

    def _settings(
        self,
        base_config: dict[str, Any],
        controls: list[dict[str, Any]],
        script_path: str | None,
    ) -> list[SettingInfo]:
        script = self.scripts.get(script_path or "")
        ids: dict[str, SettingInfo] = {}
        for key, default in base_config.items():
            ids[key] = SettingInfo(id=key, source="base_config", default=default)
        if script:
            for key in script.update_config_keys + script.config_field_cases:
                ids.setdefault(key, SettingInfo(id=key, source="script"))
        for setting in ids.values():
            lower_id = setting.id.lower()
            for control in controls:
                path = str(control["path"]).lower()
                placeholder = str(control.get("placeholder") or "").lower()
                if lower_id in path or lower_id in placeholder:
                    setting.ui_kind = control["type"]
                    setting.ui_path = control["path"]
        menu_groups: dict[str, list[dict[str, str | None]]] = {}
        for control in controls:
            if control.get("hint") and control.get("text"):
                parent = str(control["path"]).split("/")[0]
                menu_groups.setdefault(parent, []).append(
                    {"hint": control.get("hint"), "text": control.get("text")}
                )
        for setting_id, options in menu_groups.items():
            if setting_id in ids:
                ids[setting_id].options = options
                ids[setting_id].ui_kind = ids[setting_id].ui_kind or "menu"
        return list(ids.values())

    def _title_candidates(self, scene: SceneInfo) -> dict[str, str]:
        english = ""
        ru = ""
        kz = ""
        for node in scene.nodes:
            if node.name in {"Label", "Label2"} and "ColorRect/root" in node.parent:
                english = node.prop("text") or english
                break
        if not english:
            for node in scene.nodes:
                text = node.prop("text")
                if text:
                    english = text
                    break
        for node in scene.nodes:
            if not ru and "localizations_ru" in node.block:
                values = self._dict_string_values(node.block, "localizations_ru")
                ru = values[0] if values else ""
            if not kz and "localizations_kz" in node.block:
                values = self._dict_string_values(node.block, "localizations_kz")
                kz = values[0] if values else ""
        return {"en": english, "ru": ru, "kz": kz}

    def _localized_properties(
        self,
        scene: SceneInfo,
        settings: list[SettingInfo],
        ports: list[PortInfo],
    ) -> dict[str, Any]:
        controls: dict[str, dict[str, Any]] = {}
        for loc in scene.nodes:
            script_path = self._resolve_script(loc, scene.ext_resources)
            if "res://scripts/loc.gd" not in self._inheritance_chain(script_path):
                continue
            parent = self._find_node(scene, loc.parent)
            if parent is None:
                continue
            prop = "placeholder_text" if parent.raw_prop("placeholder_text") is not None else "text"
            source = parent.prop(prop)
            if source is None:
                continue
            ru_map = self._dict_string_map(loc.block, "localizations_ru")
            kz_map = self._dict_string_map(loc.block, "localizations_kz")
            key = self._sanitize_loc(source)
            ru = self._loc_value(ru_map, key, source)
            kz = self._loc_value(kz_map, key, ru)
            path = self._node_path(parent) or parent.name
            controls[path] = {
                "property": prop,
                "values": {"en": source, "ru": ru, "kz": kz},
            }

        title_path = None
        for path in controls:
            if re.search(r"(?:^|/)ColorRect/root/Label2?$", path):
                title_path = path
                break
        if title_path is None:
            for path in controls:
                if path.endswith("/Label") or path.endswith("/Label2"):
                    title_path = path
                    break

        result: dict[str, Any] = {"ports": {}, "settings": {}, "controls": controls}
        if title_path:
            result["title"] = {"source_path": title_path, **controls[title_path]}

        for setting in settings:
            candidates = [setting.ui_path or "", setting.id]
            match = self._best_localized_path(controls, candidates)
            if match:
                result["settings"][setting.id] = {
                    "label": {"source_path": match, **controls[match]},
                    "options": [],
                }
            option_rows = []
            for option in setting.options:
                option_path = self._best_localized_path(controls, [str(option.get("text") or "")])
                if option_path:
                    option_rows.append({"hint": option.get("hint"), "label": {"source_path": option_path, **controls[option_path]}})
            if option_rows:
                result["settings"].setdefault(setting.id, {"options": []})["options"] = option_rows

        for port in ports:
            full_path = port.scene_node if port.scene_path in ("", ".") else f"{port.scene_path}/{port.scene_node}"
            match = self._best_localized_path(controls, [full_path, port.scene_path, port.server_name or ""])
            if match and match != title_path:
                result["ports"][port.id] = {"label": {"source_path": match, **controls[match]}}
        return result

    @staticmethod
    def _best_localized_path(controls: dict[str, Any], candidates: list[str]) -> str | None:
        scored: list[tuple[int, str]] = []
        for path, entry in controls.items():
            lower_path = path.lower()
            english = str(entry.get("values", {}).get("en", "")).lower()
            for candidate in candidates:
                value = candidate.strip().lower()
                if not value:
                    continue
                path_parts = lower_path.split("/")
                if value == lower_path or value == english:
                    scored.append((3, path))
                elif len(value) >= 2 and value in path_parts:
                    scored.append((2, path))
        return max(scored, default=(0, ""))[1] or None

    @staticmethod
    def _sanitize_loc(source: str) -> str:
        return " ".join("".join(char.lower() if char.isalnum() else " " for char in source).split())

    @staticmethod
    def _loc_value(values: dict[str, str], key: str, fallback: str) -> str:
        if len(values) == 1:
            return next(iter(values.values()))
        return values.get(key, fallback)

    @staticmethod
    def _dict_string_map(block: str, prop: str) -> dict[str, str]:
        match = re.search(
            r"^" + re.escape(prop) + r"\s*=\s*Dictionary[^{]*\(\{(?P<body>.*?)^\}\)",
            block,
            re.MULTILINE | re.DOTALL,
        )
        if not match:
            return {}
        return dict(re.findall(r'"([^"]*)"\s*:\s*"([^"]*)"', match.group("body")))

    @staticmethod
    def _dict_string_values(block: str, prop: str) -> list[str]:
        match = re.search(
            r"^" + re.escape(prop) + r"\s*=\s*Dictionary[^{]*\(\{(?P<body>.*?)^\}\)",
            block,
            re.MULTILINE | re.DOTALL,
        )
        if not match:
            return []
        return re.findall(r'"[^"]*"\s*:\s*"([^"]*)"', match.group("body"))

    def _icon_source(self, node_id: str) -> str | None:
        candidates = [
            self.root / "node_icons" / "en" / f"Icon{pascal_graph_id(node_id)}.png",
            self.root / "node_icons" / f"Icon{pascal_graph_id(node_id)}.png",
            self.root / "node_icons" / f"Icon{node_id}.png",
        ]
        for path in candidates:
            if path.exists():
                return fs_to_godot(self.root, path)
        return None

    def _attach_static_compatibility(self, nodes: list[NodeInfo]) -> None:
        roles = {str(d["id"]): set(d.get("roles", [])) for d in self._node_definition_documents()}
        for source in nodes:
            out_ports = [port for port in source.ports if port.direction == "output" and port.datatypes]
            compatible: list[dict[str, Any]] = []
            for out_port in out_ports:
                out_types = set(out_port.datatypes)
                for target in nodes:
                    for in_port in target.ports:
                        if in_port.direction != "input" or not in_port.datatypes:
                            continue
                        source_roles = roles.get(source.node_id, set())
                        target_roles = roles.get(target.node_id, set())
                        if not out_port.config_conn and not in_port.config_conn:
                            if "language" in source_roles and not target_roles.intersection({"language", "sequence_capable"}):
                                continue
                            if "language" in target_roles and not source_roles.intersection({"language", "sequence_capable"}):
                                continue
                        shared = sorted(out_types.intersection(in_port.datatypes))
                        language_pair = "language" in source_roles or "language" in target_roles
                        if language_pair and not out_port.config_conn and not in_port.config_conn:
                            # These existing scenes acquire a sequence contract only in a language graph.
                            sequence_outputs = {"layer": "language_vectors", "concat": "language_vectors", "softmax": "language_scores"}
                            sequence_inputs = {"layer": "language_vectors", "concat": "language_vectors", "softmax": "language_vectors"}
                            source_types = {sequence_outputs[source.node_id]} if source.node_id in sequence_outputs else out_types
                            target_types = {sequence_inputs[target.node_id]} if target.node_id in sequence_inputs else set(in_port.datatypes)
                            shared = sorted(source_types.intersection(target_types))
                        if not shared:
                            continue
                        compatible.append(
                            {
                                "from_port": out_port.id,
                                "to_node": target.node_id,
                                "to_port": in_port.id,
                                "datatypes": shared,
                                "confidence": "language_sequence_contract" if language_pair else "static_datatype_intersection",
                            }
                        )
            source.static_compatible_nodes = compatible


class EnhancedJsonEncoder(json.JSONEncoder):
    def default(self, obj: Any) -> Any:
        if hasattr(obj, "__dict__"):
            return obj.__dict__
        return super().default(obj)


