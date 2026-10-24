# Language Nodes UX & Performance Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate attention node hover/frame lag, introduce a 100ms debounced coalescing inference loop for keystroke spam, enable click-to-deselect and drag suppression on interactive elements, overhaul embedding visualization (grid, larger saturated points, centered legend, no PC labels), and fix tokenizer pill shifting on hover/click.

**Architecture:**
- Caching pattern in `attention_heatmap.gd` to compile RegEx and compute matrix geometry once per input change rather than per frame/mouse-move, gating `queue_redraw()` in `advance_reveal`.
- Debounce/throttle timer in `language_graph_controller.gd` coalescing rapid keystrokes into 100ms batches instead of continuous per-frame inference triggers.
- Interaction handling in `embedding_plot.gd` and `language_node.gd` overriding `_can_drag()` to prioritize token/point clicks while permitting empty-space canvas clicks to deselect vectors.
- Drawing enhancements in `embedding_plot.gd` rendering a 2D coordinate grid, enlarged saturated points, horizontally centered legend, and removing legacy PC1/PC2/PC3 text.
- Alignment stabilization in `action_button.tscn` and `token_strip.gd` locking `alignment = Vector2(0.5, 0.5)` to keep button scaling centered without directional shifts.

**Tech Stack:** Godot 4.7.2 GDScript, Godot UI Controls / Custom Drawing (`_draw`), Python 3.12 pytest.

**Spec:** User feedback requirements from 2026-10-15 session.

## Global Constraints
- Target repository: `D:\NRLSE\nnets\teachneurons-llm-merge` (DO NOT touch `D:\NRLSE\nnets\teachneurons`).
- Maintain backward compatibility with existing tests in `tests/godot/test_language_*.gd`.
- Strictly adhere to Godot 4.7 GDScript conventions.
- Never edit generated files (`scripts/generated/*`).

## Review Focus
1. Rapid typing spam ("ааааааааа") coalesces to 100ms intervals without dropping the final character or triggering per-frame request storms.
2. Attention heatmap hover triggers zero regex compiles or matrix re-averaging per mouse move event.
3. Clicking on an embedding point selects it without dragging the parent graph node; clicking empty canvas space deselects the vector (`selected_position = -1`).
4. Embedding visualization cleanly displays subtle grid lines, bright vibrant points, horizontally centered depth legend, and no PC1/PC2/PC3 labels.
5. Tokenizer pills scale strictly from their geometric center on hover and press without shifting to the right.

---

### Task 1: 100ms Inference Debounce & Coalescing during Fast Keystrokes

**Files:**
- Modify: `scripts/language_models/language_graph_controller.gd`
- Test: `tests/godot/test_language_controller.gd`

**Context:**
Currently `AUTOMATIC_DELAY := 0.0`. In `_process(delta)`, when `current != _fingerprint`, `_automatic_remaining` is set to `0.0`, firing `start(source)` on every single keystroke. When typing rapidly, this spams session resets and inferences.

**Steps:**
- [ ] **Step 1: Write/update test in `tests/godot/test_language_controller.gd`**
  Add verification that when `controller._process()` runs after text changes, `_automatic_remaining` is set to `0.1` and counts down, coalescing multiple edits before executing `start()`.
- [ ] **Step 2: Run test to confirm behavior**
  Execute `& "D:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path . -s tests/godot/test_language_controller.gd`.
- [ ] **Step 3: Implement 100ms debounce and coalescing in `language_graph_controller.gd`**
  - Set `const AUTOMATIC_DELAY := 0.1`.
  - In `_process(delta)`:
    ```gdscript
    if current != _fingerprint:
        _fingerprint = current
        var text := str(source.cfg.get("text",""))
        var edges_list: Array = graph.get("edges", [])
        var has_edges: bool = not edges_list.is_empty()
        var has_text: bool = not text.strip_edges().is_empty()
        if not has_edges or not has_text:
            reset(true)
            _automatic_remaining = -1.0
        else:
            if _automatic_remaining < 0.0:
                _automatic_remaining = AUTOMATIC_DELAY
    ```
- [ ] **Step 4: Re-run tests**
  Verify all controller tests pass.
- [ ] **Step 5: Commit changes**
  `git commit -m "feat(language): coalesce inference on typing spam with 100ms debounce"`

---

### Task 2: Attention Heatmap Cache Optimization & Redraw Throttling (Eliminate Hover & Large-Text Lag)

**Files:**
- Modify: `scripts/language_models/views/attention_heatmap.gd`
- Test: `tests/godot/test_language_views.gd`

**Context:**
`attention_heatmap.gd` currently recompiles `RegEx.new()` (`\S+`) and loops through all words inside `_groups()` on every call to `labels()`, `display_matrix()`, and `_geometry()`. These are invoked on every mouse move in `_get_tooltip()` and `_cell_at()`, and every frame via `advance_reveal()` calling `queue_redraw()`.

**Steps:**
- [ ] **Step 1: Create static/precompiled RegEx and cache fields in `attention_heatmap.gd`**
  Add cached variables:
  ```gdscript
  static var _word_regex: RegEx
  var _cached_groups: Array = []
  var _cached_display_matrix: Array = []
  var _cached_labels: Array = []
  var _cached_geometry: Dictionary = {}
  var _cache_dirty := true
  ```
- [ ] **Step 2: Implement `_recompute_cache()`**
  Initialize `_word_regex` once. Calculate `_cached_groups`, `_cached_display_matrix`, `_cached_labels`, and `_cached_geometry`.
  Mark dirty when `set_preview()`, `clear_preview()`, `set_word_mode()`, or `set_window()` is called.
- [ ] **Step 3: Point callers to cached values**
  Make `_groups()`, `labels()`, `display_matrix()`, `_geometry()`, `_cell_at()`, `_get_tooltip()`, and `content_size()` read directly from the cached structures without running RegEx.
- [ ] **Step 4: Throttle `advance_reveal()` redraws**
  Only call `queue_redraw()` in `advance_reveal(delta, available)` if an alpha value actually changed (`absf(target - alpha) > 0.001`).
- [ ] **Step 5: Run `test_language_views.gd` to verify accuracy and performance**
  Verify heatmap tests pass.
- [ ] **Step 6: Commit changes**
  `git commit -m "perf(attention): cache heatmap calculations and eliminate hover/frame lag"`

---

### Task 3: Embedding Plot Deselection on Empty Click & Node Drag Suppression

**Files:**
- Modify: `scripts/language_models/views/embedding_plot.gd`
- Modify: `scripts/language_models/views/token_strip.gd`
- Modify: `scripts/language_models/language_node.gd`
- Test: `tests/godot/test_language_views.gd`

**Context:**
Users reported that clicking empty space in the embedding plot did not deselect the active vector, and clicking on an embedding point or token pill would drag the whole node instead of interacting cleanly with the point/pill.

**Steps:**
- [ ] **Step 1: Implement empty-space deselection in `embedding_plot.gd`**
  In `_gui_input(event)`:
  If `event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT`:
  Find `nearest` point within distance 12.0.
  If `nearest >= 0`:
      `select_position(nearest)`
      `accept_event()`
  Else:
      `select_position(-1)` # Resets selected vector and line
      `accept_event()`
- [ ] **Step 2: Add `is_mouse_over_interactive()` helper on views**
  - In `embedding_plot.gd`: return true if mouse position is within 12px of any point or over the legend.
  - In `token_strip.gd`: return true if mouse is over any active token pill.
- [ ] **Step 3: Override `_can_drag()` in `language_node.gd`**
  In `language_node.gd`:
  ```gdscript
  func _can_drag() -> bool:
      if not super._can_drag():
          return false
      if is_instance_valid(view) and view.has_method("is_mouse_over_interactive"):
          if view.is_mouse_over_interactive():
              return false
      return true
  ```
- [ ] **Step 4: Verify with headless test**
  Verify selection and deselection work cleanly.
- [ ] **Step 5: Commit changes**
  `git commit -m "feat(language): support empty click deselection and drag suppression on points and tokens"`

---

### Task 4: Embedding Plot Visual Polish: Coordinate Grid, Vibrant Saturated Points, Centered Gradient Legend, Removal of PC1/PC2/PC3

**Files:**
- Modify: `scripts/language_models/views/embedding_plot.gd`
- Test: `tests/godot/test_language_views.gd`

**Context:**
The embedding plot currently has tiny points (radius 2.3), lacks a coordinate grid, displays outdated "PC1", "PC2", "PC3" text labels, and has an off-center depth legend.

**Steps:**
- [ ] **Step 1: Remove "PC1", "PC2", and "PC3" text from `_draw()` and `_draw_depth_legend()`**
  Remove lines drawing "PC1", "PC2", and "PC3".
- [ ] **Step 2: Draw coordinate grid**
  In `_draw()`:
  Draw subtle grid lines across the $154 \times 154$ canvas:
  - 4 subdivisions (at -0.5, 0.0, +0.5 coordinate space) with `Color(S.MUTED, 0.12)`.
  - Main center axes with `Color(S.MUTED, 0.28)`.
- [ ] **Step 3: Increase point size and color saturation**
  - Increase point radius from 2.3 to 4.2 for normal points, and 3.2 to 6.0 for active points.
  - Active selection ring radius to 8.5.
  - Use high-saturation accent / depth palette with full contrast.
- [ ] **Step 4: Center depth legend horizontally**
  In `_legend_geometry()` and `_draw_depth_legend()`:
  - Calculate `bar_width = 54.0`.
  - Total width = `left_width + 6.0 + bar_width + 6.0 + right_width`.
  - Center origin `start_x = (CANVAS_DIM - total_width) * 0.5`.
  - Draw `low` text at `start_x`, gradient bar at `start_x + left_width + 6.0`, and `high` text at `bar.end.x + 6.0`.
- [ ] **Step 5: Run tests and verify visual output**
  Check `test_language_views.gd`.
- [ ] **Step 6: Commit changes**
  `git commit -m "style(embedding): add grid, enlarge vibrant points, center legend, remove PC labels"`

---

### Task 5: Tokenizer Pill Center Alignment (No Shift on Hover/Press)

**Files:**
- Modify: `scenes/language_models/action_button.tscn`
- Modify: `scripts/language_models/language_style.gd`
- Modify: `scripts/language_models/views/token_strip.gd`
- Test: `tests/godot/test_language_views.gd`

**Context:**
Hovering or clicking a token pill shifts it visually to the right. This is caused by `alignment = Vector2(0, 0)` in `action_button.tscn` causing `scaler` in `BlockComponent` to scale around the top-left corner instead of the center, and improper pill container positioning.

**Steps:**
- [ ] **Step 1: Set `alignment = Vector2(0.5, 0.5)` in `action_button.tscn`**
  Update `alignment = Vector2(0.5, 0.5)` so `BlockComponent` centers the scale pivot.
- [ ] **Step 2: Update `S.button()` in `language_style.gd`**
  Ensure newly created action buttons default to centered alignment `Vector2(0.5, 0.5)`.
- [ ] **Step 3: Update pill positioning in `token_strip.gd`**
  In `_layout()`:
  Ensure `pills[i].alignment = Vector2(0.5, 0.5)`.
  Position the wrapper / pill using `resize(Vector2(width, height))` or explicit center offsets so `scaler` expands and contracts symmetrically from the pill center without horizontal translation.
- [ ] **Step 4: Run tests**
  Run `test_language_views.gd` to ensure token positioning and row limits remain compliant.
- [ ] **Step 5: Commit changes**
  `git commit -m "fix(tokenizer): center pill rect alignment to prevent shifting on hover/click"`

---

### Task 6: Full Verification & Automated Regression Testing

**Files:**
- All modified files
- Python & Godot test suites

**Steps:**
- [ ] **Step 1: Run Python verification suites**
  `py -3.12 -m pytest tests/jasondocs tests/node_dev`
- [ ] **Step 2: Run all Godot language suites headless**
  - `tests/godot/test_language_backend.gd`
  - `tests/godot/test_language_controller.gd`
  - `tests/godot/test_language_editor.tscn`
  - `tests/godot/test_language_graph.gd`
  - `tests/godot/test_language_menus.tscn`
  - `tests/godot/test_language_views.gd`
- [ ] **Step 3: Launch interactive Godot session and verify visually**
  Verify hover smoothness on AttentionHead, vector deselect on empty click, non-draggable points/tokens, grid & centered legend in Embedding, and zero-shift token hover.
- [ ] **Step 4: Final commit and summary**
