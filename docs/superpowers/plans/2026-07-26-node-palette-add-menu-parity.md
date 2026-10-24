# Node Palette / Add Graph Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the left node palette contain the exact same usable node types in the same order as `Add Graph`, remove test nodes, and polish its search/top-edge UI.

**Architecture:** Extract the existing Add Graph filtering and ordering into a pure shared catalog consumed by both `cmenu.gd` and `node_palette.gd`. Keep palette-only styling and geometry inside `node_palette.gd` so shared themes and platform behavior remain unchanged.

**Tech Stack:** Godot 4.7, GDScript, Godot themes/scenes, headless SceneTree tests.

## Global Constraints

- Do not maintain a second hardcoded test-node blacklist.
- Do not modify the main Theme resources.
- Preserve the current preview-based drag-and-drop palette.
- Use the same code on Windows and macOS.

---

### Task 1: Shared graph creation catalog

**Files:**
- Create: `scripts/graph_creation_catalog.gd`
- Modify: `scripts/cmenu.gd`
- Modify: `scripts/node_palette_catalog.gd`
- Modify: `scripts/node_palette.gd`
- Test: `tests/godot/test_node_palette_catalog.gd`

**Interfaces:**
- Produces: `GraphCreationCatalog.ordered_definitions(definitions, importance_chain, skip_types, name_groups, hide_inputs) -> Array`
- Consumes: `graphs.graph_buttons`, `glob.base_node.importance_chain`, `add_graph.skip`, `add_graph.name_groups`

- [ ] Add a failing catalog test containing allowed, skipped, test-only, and ungrouped allowed definitions.
- [ ] Run `test_node_palette_catalog.gd` and verify the test fails because test-only definitions are appended.
- [ ] Implement the shared pure ordering helper.
- [ ] Make `cmenu.gd` and `node_palette.gd` consume the helper and remove palette fallback appending.
- [ ] Run the catalog test and verify exact ordered type parity.

### Task 2: Palette-only search styling and top alignment

**Files:**
- Modify: `scripts/node_palette.gd`
- Modify: `scenes/node_palette.tscn`
- Test: `tests/godot/test_node_palette_scene.gd`

**Interfaces:**
- Produces: `NodePalette.palette_search_style(source_style, radius) -> StyleBox`
- Produces: `NodePalette.top_bar_bottom(top_bar, fallback) -> float`

- [ ] Add failing scene tests for a locally duplicated six-pixel search radius and live top-bar geometry.
- [ ] Run `test_node_palette_scene.gd` and verify the new assertions fail.
- [ ] Duplicate the source search styleboxes and set only palette copies to six-pixel corners.
- [ ] Replace the fixed top inset at runtime with `fg/ColorRect.get_global_rect().end.y`.
- [ ] Run scene and catalog tests.

### Task 3: Cross-platform verification and launch

**Files:**
- Verify: `export_presets.cfg`
- Verify: project resources and generated exports

- [ ] Run `tests/godot/run_all.sh`.
- [ ] Run `git diff --check`.
- [ ] Export the `Windows Desktop` preset to a temporary build directory.
- [ ] Export the `macOS` preset to a temporary build directory.
- [ ] Launch `scenes/project.tscn` on macOS and verify the process remains alive without a new palette error.
