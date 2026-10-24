# Node Palette Toggle Animation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Animate the Neuralese node palette when it opens and closes without disturbing graph input or layout.

**Architecture:** Keep `NodePalette.set_collapsed` as the only public state transition. A single owned `Tween` moves and fades the existing panel, cancels safely when superseded, and hands visibility to the existing reopen button only after closing completes.

**Tech Stack:** Godot 4.7, GDScript, built-in `Tween`, existing headless Godot test runner.

## Global Constraints

- Toggle duration is exactly 0.22 seconds.
- Opening uses cubic ease-out; closing uses cubic ease-in.
- Initialization applies the expanded endpoint without animation.
- Search, drag-and-drop, graph navigation, node previews, and shared styles remain unchanged.
- No new dependency or scene is introduced.

---

### Task 1: Animate The Existing Palette Toggle

**Files:**
- Modify: `tests/godot/test_node_palette_scene.gd`
- Modify: `scripts/node_palette.gd`

**Interfaces:**
- Consumes: existing `set_collapsed(value: bool)` button bindings and `Panel`/`Reopen` scene nodes.
- Produces: `set_collapsed(value: bool, animated: bool = true) -> void`, `toggle_offset(collapsed: bool, width: float) -> float`, and one interruptible `_toggle_tween`.

- [x] **Step 1: Write the failing animation contract test**

Extend `test_node_palette_scene.gd` with a sixth case. It must assert the exact duration, endpoint calculation, optional animation argument, initial non-animated setup, tween cancellation, and cubic easing:

```gdscript
func _test_palette_toggle_animation_contract() -> void:
	var palette = load("res://scenes/node_palette.tscn").instantiate()
	_expect(is_equal_approx(palette.toggle_duration, 0.22), "palette toggle must use the approved 220ms duration")
	_expect(is_equal_approx(palette.toggle_offset(false, 248.0), 0.0), "expanded palette must end at the viewport edge")
	_expect(is_equal_approx(palette.toggle_offset(true, 248.0), -248.0), "collapsed palette must end just outside the left edge")
	var source := FileAccess.get_file_as_string("res://scripts/node_palette.gd")
	_expect(source.contains("set_collapsed(false, false)"), "palette initialization must not animate")
	_expect(source.contains("_toggle_tween.kill()"), "a new toggle must interrupt the previous tween")
	_expect(source.contains("Tween.TRANS_CUBIC"), "palette motion must use cubic easing")
	_expect(source.contains("Tween.EASE_OUT if not value else Tween.EASE_IN"), "opening and closing must use the approved easing directions")
	palette.free()
```

Register the new test in `_initialize()` and update the success marker from `5 cases` to `6 cases`.

- [x] **Step 2: Run the focused test and verify RED**

Run:

```bash
GODOT_BIN='/Users/alim/Library/Application Support/Steam/steamapps/common/Godot Engine/Godot.app/Contents/MacOS/Godot'
"$GODOT_BIN" --headless --path . --quit-after 300 --script tests/godot/test_node_palette_scene.gd
```

Expected: FAIL because `toggle_duration` and `toggle_offset` do not exist and the script has no owned toggle tween.

- [x] **Step 3: Implement the interruptible tween**

In `scripts/node_palette.gd`, add:

```gdscript
@export var toggle_duration := 0.22
var _toggle_tween: Tween = null

static func toggle_offset(collapsed: bool, width: float) -> float:
	return -width if collapsed else 0.0
```

Change initialization to `set_collapsed(false, false)`. Replace the instant visibility switch with a method that:

```gdscript
func set_collapsed(value: bool, animated: bool = true) -> void:
	_collapsed = value
	if value:
		search.release_focus()
	if _toggle_tween != null:
		_toggle_tween.kill()
		_toggle_tween = null

	reopen_button.visible = false
	panel.visible = true
	_sync_geometry()
	_update_selection_blocker(get_viewport().get_mouse_position())

	var target_x := toggle_offset(value, panel_width)
	var target_alpha := 0.0 if value else 1.0
	if not animated or not is_inside_tree():
		_apply_toggle_endpoint(value, target_x, target_alpha)
		return

	_toggle_tween = create_tween()
	_toggle_tween.set_parallel(true)
	var easing := Tween.EASE_OUT if not value else Tween.EASE_IN
	_toggle_tween.tween_property(panel, "position:x", target_x, toggle_duration).set_trans(Tween.TRANS_CUBIC).set_ease(easing)
	_toggle_tween.tween_property(panel, "modulate:a", target_alpha, toggle_duration).set_trans(Tween.TRANS_CUBIC).set_ease(easing)
	_toggle_tween.set_parallel(false)
	_toggle_tween.tween_callback(_finish_toggle.bind(value, _toggle_tween))
```

The endpoint callback must ignore stale tweens, hide the panel only after closing, show the reopen button only after closing, and reset the panel to full opacity when open. `_sync_geometry` must preserve an in-flight horizontal position while keeping the configured width.

- [x] **Step 4: Run the focused test and verify GREEN**

Run the focused command from Step 2.

Expected: `PASS test_node_palette_scene: 6 cases`.

- [x] **Step 5: Run the complete Godot suite**

Run:

```bash
GODOT_BIN='/Users/alim/Library/Application Support/Steam/steamapps/common/Godot Engine/Godot.app/Contents/MacOS/Godot' tests/godot/run_all.sh
```

Expected: all 14 test scripts print their PASS marker and the command exits with status 0.

- [x] **Step 6: Launch and manually verify the transition**

Run:

```bash
'/Users/alim/Library/Application Support/Steam/steamapps/common/Godot Engine/Godot.app/Contents/MacOS/Godot' --path .
```

Verify that closing slides and fades the panel, the reopen button appears at the end, opening reverses the motion, and graph zoom/pan remain available outside the palette.

- [x] **Step 7: Commit the implementation**

```bash
git add scripts/node_palette.gd tests/godot/test_node_palette_scene.gd docs/superpowers/plans/2026-07-19-node-palette-toggle-animation.md
git commit -m "feat: animate node palette toggle"
```
