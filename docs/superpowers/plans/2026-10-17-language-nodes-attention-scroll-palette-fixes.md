# Attention Node Scrolling & Transformer Nodes UX Fixes Implementation Plan

## Context & Problem Breakdown

The user reported 6 specific issues with Transformer-related nodes (`text_input`, `tokenizer`, `embedding`, `attention_head`).
Specifically for **Point 4**, the user requested: *"For this point, form a plan first, cuz its hard to understand this issue."*

### Why does Point 4 occur? (Deep Analysis of Unfilled Attention Scrolling)

In `scripts/language_models/views/attention_heatmap.gd`:
1. The visible grid of an attention head displays an 8x8 matrix by default.
2. In the previous turn, mouse wheel support without scrollbars was added:
   ```gdscript
   func _gui_input(event: InputEvent) -> void:
       if event is InputEventMouseButton and event.pressed:
           if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
               if not _is_scrollbar_active():
                   var delta := 1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
                   _scroll_window(delta)
                   accept_event()
                   return
   ```
3. Inside `_scroll_window(delta)`:
   ```gdscript
   func _scroll_window(delta: int) -> void:
       var total: int = int(preview.get("total", 0))
       var tokens: Array = preview.get("tokens", [])
       var max_total: int = maxi(total, tokens.size())
       var cur_start: int = int(preview.get("start", 0))
       var new_start: int = maxi(0, cur_start + delta)
       if max_total > 0 and new_start >= max_total:
           return
       if new_start != cur_start:
           preview.start = new_start
           _recompute_cache()
           queue_redraw()
           window_requested.emit(delta)
   ```
4. **The Bug**:
   - Suppose the user enters text with only 2 or 3 words (e.g. `"hello world"`).
   - `max_total` is 2 or 3, while the grid capacity is 8. The node is **not filled** (5 empty columns/rows).
   - When the user rolls the mouse wheel down over the attention node (`delta = 1`):
     - `new_start` becomes `1`.
     - `new_start < max_total` (1 < 3) is TRUE!
     - `preview.start` is updated to 1!
     - The attention heatmap re-indexes tokens starting from 1: **the first word ("hello") vanishes off the left/top of the matrix**, and the matrix shifts towards empty space!
     - Even worse, rolling wheel down again shifts to start=2, vanishing "world".
   - Furthermore, `accept_event()` is called on every wheel event, and `language_node.gd` connected `mouse_entered` to `glob.set_scroll_impossible(attention_scroll)`.
   - Result: Not only does the unfilled matrix bizarrely slide away its words, but the user is completely blocked from zooming the camera (Point 6)!

---

## Comprehensive Implementation Plan

### Task 1: Fix Point 1 — `_can_drag` in Embedding Node
- **File**: `scripts/language_models/views/embedding_plot.gd`
- **Issue**: `is_mouse_over_interactive()` returns `false` unconditionally. When clicking on an embedding dot, `LanguageNode._can_drag()` checks `view.is_mouse_over_interactive()`, receives `false`, and starts dragging the node instead of selecting the point.
- **Fix**:
  ```gdscript
  func is_mouse_over_interactive() -> bool:
      var local_m := get_local_mouse_position()
      for item in _render_items:
          if item.pos.distance_to(local_m) <= 12.0:
              return true
      return false
  ```

---

### Task 2: Fix Point 2 — Embedding Node Display of Long Strings
- **File**: `scripts/language_models/views/embedding_plot.gd`
- **Issues identified**:
  1. Hardcoded truncate limit: `if text.length() > 14: text = text.left(13) + "…"` truncates strings after only 14 chars.
  2. Overlap suppression: Long strings have wide bounding boxes (`str_size.x`), causing `bounds.intersects(box)` with neighboring points in `occupied`, marking `show_label = false` so the label never draws unless clicked.
  3. Label placement flexibility: Bounding box only tests rightward placement `p + Vector2(7, -13)`. If placing to the left `p - Vector2(str_size.x + 7, 13)` avoids overlap, use left placement.
  4. Non-alphanumeric token loss: `_words_regex` only matches `[a-zA-Zа-яА-ЯёЁ...0-9]+`. Standalone tokens or punctuation not in word spans should fall back to display rather than being dropped completely.
- **Fix**:
  - Increase length limit to 24 characters (`text.left(23) + "…"`).
  - Test right placement; if it overlaps, test left placement before giving up and hiding label.
  - Retain token points even when no regex words match.

---

### Task 3: Fix Point 3 — Eliminate Initial Startup Size Lerp
- **Files**: `scripts/language_models/language_node.gd`, `scripts/language_models/text_input.gd`
- **Issue**:
  - On node instantiate / `_after_ready()`, `rect.size` starts at default packed scene size (e.g. 109x73).
  - In `_after_process(delta)`, it lerps toward `target_size_vec` over multiple frames.
  - On creation, this causes an annoying small-to-large pop animation.
- **Fix**:
  - In `_after_ready()` of `text_input.gd` and `language_node.gd`:
    Immediately after initial `_update_content_layout()`, snap `rect.size = target_size_vec` and `size = target_size_vec`, sync ports and child bounds immediately.
  - In subsequent frames (`_after_process`), when `target_size_vec` changes dynamically due to text typing or attention grid expansion, continue lerping smoothly as desired.

---

### Task 4 & Task 6: Fix Points 4 & 6 — Attention Heatmap Scrolling & Camera Zooming
- **Files**: `scripts/language_models/views/attention_heatmap.gd`, `scripts/language_models/language_node.gd`
- **Fix for Point 4 (Scrolling when not filled)**:
  - In `attention_heatmap.gd`:
    A heatmap is only window-scrollable if `max_total > 8` AND the current window view does not already contain all items (i.e. `total > 8`).
    If `max_total <= 8` or `count <= 8 and total <= 8`:
    - The node is not scrollable.
    - `_scroll_window(delta)` must do nothing.
    - `_gui_input` must NOT accept the mouse wheel event (`accept_event()` not called), allowing the event to propagate to the camera.
  - Also ensure window bounds clamp properly: if `max_total > 8`, the start window cannot scroll past `max_total - 8`.
- **Fix for Point 6 (Camera zoom over attention node)**:
  - In `language_node.gd`:
    Only set `glob.set_scroll_impossible(attention_scroll)` if scrollbars are actually active (`_is_scrollbar_active()`).
    If scrollbars are not active, do NOT block scrolling in `glob`, so the user can zoom in/out with the mouse wheel.
    In `attention_heatmap.gd`:
    When scrollbars are not active and the node is not scrollable (or at limits), do not accept wheel events so they zoom the camera.

---

### Task 5: Fix Point 5 — Attention Node Palette in Embedding Node Dot Palette Style
- **File**: `scripts/language_models/views/attention_heatmap.gd`
- **Issue**:
  - Attention heatmap currently uses a navy/purple background (`Color(0.12, 0.14, 0.23, 0.45)`) and a hardcoded LUT interpolating from `(38, 37, 60)` to `S.ACCENT` (teal).
  - Embedding plot uses `DEPTH_PALETTE = preload("res://resources/language_models/ylgn.tres")` (YlGn ColorBrewer yellow-to-green gradient) and a dark canvas background `Color(0.08, 0.1, 0.15)`.
- **Fix**:
  - Load `const DEPTH_PALETTE = preload("res://resources/language_models/ylgn.tres")` in `attention_heatmap.gd`.
  - Update `empty_bg`: `Color(0.08, 0.1, 0.15, 0.5)` to match Embedding canvas styling.
  - Rebuild `_color_lut`:
    Map attention weight `t` (0.0 to 1.0) through the `DEPTH_PALETTE` style:
    - At `t = 0.0`: dark canvas background `Color(0.08, 0.1, 0.15, 1.0)` / zero cell color.
    - At `t > 0.0`: smooth transition into `DEPTH_PALETTE` (from deep forest green up through vibrant lime to light yellow for peak weights).
  - Matrix texture and empty cell backgrounds will match the clean dark canvas + YlGn dot style of the Embedding node.

---

### Verification Strategy
1. **Headless Unit Tests**:
   - Run `tests/godot/test_language_interactions.gd` (with new assertions for embedding dot interactive hit test, attention scroll guard when <= 8 items, zoom scrollability).
   - Run `tests/godot/test_language_views.gd` to ensure palette, labels, and geometry contracts remain intact.
2. **Node Dev & Registry Check**:
   - Run `python -m tools.node_dev check`.
3. **Interactive Visual Verification**:
   - Verify camera zoom over attention head without scrollbars.
   - Verify instant spawn size for TextInput, Tokenizer, Embedding, and Attention Head.
