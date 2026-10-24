# Node Palette Drag-and-Drop Implementation Plan

**Goal:** Build an automatically generated, scrollable node palette with visual previews and drag-and-drop node creation while preserving the context menu.

**Architecture:** Registry metadata in `graph_manager.gd` feeds a pure catalog helper. A screen-space palette builds item controls at runtime and sends stable type ids to a temporary drop surface. Creation delegates to the existing `get_graph()` factory.

**Tech stack:** Godot 4.7, GDScript, native Control drag-and-drop, existing PNG node previews.

## Constraints

- Start from `origin/dev` in `codex/node-palette-drag-drop`.
- Never duplicate the graph type-to-scene mapping.
- Keep the existing context menu operational.
- Do not generate previews during normal startup.
- New registered graph types should appear without editing the palette scene or script.

## Task 1: Dynamic catalog

**Files:**
- Create `scripts/node_palette_catalog.gd`
- Create `tests/godot/test_node_palette_catalog.gd`
- Modify `tests/godot/run_all.sh`

- [x] Write failing tests for icon naming, ordering, localization, hidden types and automatic discovery.
- [x] Run the focused test and verify it fails because the catalog does not exist.
- [x] Implement the catalog without global state or graph-specific type mappings.
- [x] Run the focused test and verify all catalog cases pass.

## Task 2: Automatically generated palette UI

**Files:**
- Create `scripts/node_palette.gd`
- Create `scripts/node_palette_item.gd`
- Create `scenes/node_palette.tscn`
- Create `scenes/node_palette_item.tscn`
- Create `tests/godot/test_node_palette_scene.gd`

- [x] Write a scene smoke test that checks the palette contains a reusable item template and no manually declared graph cards.
- [x] Build cards at runtime from `graphs.graph_buttons` and `importance_chain`.
- [x] Load each preview by convention and render a title/color fallback when absent.
- [x] Rebuild localized titles on `glob.language_changed`.
- [x] Verify scrolling and fixed screen-space sizing.

## Task 3: Drag/drop creation path

**Files:**
- Modify `scripts/graph_manager.gd`
- Modify `scripts/node_palette.gd`
- Modify `scripts/node_palette_item.gd`
- Extend `tests/godot/test_node_palette_catalog.gd`

- [x] Test payload validation and valid workspace bounds before implementation.
- [x] Add `create_graph_at_screen_position(type_id, screen_position)` as a thin wrapper around `get_graph()`.
- [x] Add a drag preview and enable the drop surface only during palette drags.
- [x] Reject panel/top-bar/out-of-window drops without side effects.
- [x] Center the created graph at the converted world position.

## Task 4: Registry-driven preview generation

**Files:**
- Create `tools/generate_node_icons.sh`
- Modify `scripts/graph_manager.gd`
- Modify `scripts/project.gd`
- Extend `tests/godot/test_node_palette_catalog.gd`

- [x] Share one icon-path convention between the palette and generator.
- [x] Iterate `graph_types` instead of listing node scenes.
- [x] Preserve and restore camera state during generation.
- [x] Delete temporary graph instances and report generated/missing files.
- [x] Document the explicit developer command.

## Task 5: Project integration and regression verification

**Files:**
- Modify `scenes/project.tscn`
- Modify `docs/node-palette.md`

- [x] Mount the palette in a dedicated screen-space layer.
- [x] Run focused catalog and scene tests.
- [x] Import the project headlessly to catch scene/script parse errors.
- [x] Run the existing Godot suite and distinguish pre-existing runner failures.
- [x] Manually verify the screen-space panel and confirm the existing context-menu implementation remains untouched.

## Task 6: Search, collapse and input isolation

**Files:**
- Modify `scenes/node_palette.tscn`
- Modify `scripts/node_palette.gd`
- Modify `scripts/node_palette_catalog.gd`
- Extend focused palette tests

- [x] Replace the static header with node search and a compact collapse control.
- [x] Filter generated entries by localized title and stable type id.
- [x] Leave a compact reopen control while the palette is collapsed.
- [x] Block graph selection while using the panel or its scrollbar.
- [x] Verify search, collapse/reopen and scrollbar behavior in the running application.
