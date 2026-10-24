# Node Palette Visual Integration Implementation Plan

**Goal:** Restyle and isolate the node palette using Neuralese's existing UI assets while preserving its generated catalog and drag/drop behavior.

**Architecture:** `NodePalette` copies project-owned styles at runtime and owns the global input blockers while hovered. `NodePaletteItem` renders one preview with tooltip/fallback metadata and local hover interpolation. `NodePaletteDropSurface` validates drops without drawing an overlay, and `GraphViewport` applies the existing navigation guard to middle-button drag.

**Tech Stack:** Godot 4.7, GDScript, existing Control scenes, existing shader/theme resources, headless Godot tests.

## Global Constraints

- Keep `scripts/graph_manager.gd` as the only node registry and factory.
- Keep the context menu and current drag payload unchanged.
- Reuse styles from `fg.tscn` and `menus.tscn`; do not recreate their colors manually.
- Preserve the current Retina scaling and platform input changes.

### Task 1: Lock the visual and input contract

**Files:**
- Modify: `tests/godot/test_node_palette_scene.gd`
- Modify: `tests/godot/test_platform_input.gd`

- [x] Assert that palette items contain only an unframed preview and retain the title as a tooltip/fallback.
- [x] Assert that hover interpolation changes visual scale without changing layout metadata.
- [x] Assert that the palette registers and releases the existing scroll blocker.
- [x] Assert that middle-button camera drag cannot start while navigation is blocked.
- [x] Run both focused tests and confirm the new assertions fail for the expected missing behavior.

### Task 2: Reuse native Neuralese styling

**Files:**
- Modify: `scenes/node_palette.tscn`
- Modify: `scripts/node_palette.gd`

- [x] Remove custom blue search/button styling and card-like panel decoration.
- [x] Copy the top-panel shader material and instance parameters from `fg/ColorRect` at runtime.
- [x] Copy the graph add-menu search styles from `WIN_GRAPH/menus/add_graph/Label2` at runtime.
- [x] Keep collapse/reopen controls compact and neutral.
- [x] Run the palette scene test until it passes.

### Task 3: Simplify previews and drag feedback

**Files:**
- Modify: `scenes/node_palette_item.tscn`
- Modify: `scripts/node_palette_item.gd`
- Modify: `scripts/node_palette_drop_surface.gd`

- [x] Replace framed cards with transparent preview-only rows.
- [x] Keep missing-icon fallback and localized tooltip behavior.
- [x] Interpolate hover scale using a stable pivot and delta-based smoothing.
- [x] Build a plain image drag preview and remove the workspace outline draw.
- [x] Run the palette scene test until it passes.

### Task 4: Isolate graph navigation

**Files:**
- Modify: `scripts/node_palette.gd`
- Modify: `scripts/camera_2d.gd`

- [x] Register both selection and scroll blockers while the pointer is over palette UI.
- [x] Release both blockers on pointer exit, collapse and tree teardown.
- [x] Require `_can_user_navigate()` before starting middle-button camera dragging.
- [x] Run the platform input test until it passes.

### Task 5: Integration verification

**Files:**
- No production changes expected.

- [x] Run the focused palette and platform input tests.
- [x] Run `tests/godot/run_all.sh` with the Godot 4.7 binary.
- [x] Launch the project and visually verify search, scrolling, hover, collapse and node drag/drop.
- [x] Commit and push the branch backing the existing pull request.
