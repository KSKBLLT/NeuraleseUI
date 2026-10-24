---
name: driving-neuralese-ui
description: "How to operate the running Neuralese app with mouse automation, and the traces the tools leave behind"
metadata:
  node_type: memory
  type: reference
  originSessionId: 0fe21542-4155-4615-89f3-daf716df8888
  modified: 2026-10-12T10:17:01.040Z
---

Learned 2026-10-11 and 2026-10-12 driving teachneurons (godot MCP run_project):

- Path to the smart-car sim: onboarding "Кто сейчас работает?" needs BOTH name and surname (Test / User) -> "Не сейчас" -> "Посмотреть готовые ИИ-модели" -> "Умная машинка" "Сделать копию" -> top tabs. Training: epochs field `$YY` left of "Учись!", 500-900 epochs.
- **Mouse position is polled from the real cursor**, not from events. Before each synthetic click run `scene_tree.root.warp_mouse(Vector2(x,y))` in run_script, then simulate_input `mouse_button` with `hold_ms` 150-250. Without the warp the click lands wherever the cursor was.
- Screenshots: use mcp godot `take_screenshot` once the app has finished loading (it times out for ~1 min during startup). `viewport.get_texture().get_image().save_png()` from run_script works early but does NOT capture blurred dialogs (splash windows look absent).
- Top-bar node names lie: node `graphs` is the "Симуляции" tab (window "env"), `minigames` is "Графы" ("graph"), `datasets` is "Датасеты" ("ds"). Tab clicks were unreliable after closing a dialog; `glob.go_window("env"|"graph"|"ds")` does the same thing.
- Open Brain Mapping without hunting for the car (the camera follows the cursor): `get_node("/root/@Node@211/SimulationTab/SimulationEditor").select_object("car")`; scroll its panel via a ScrollContainer found under `brain_mapping_panel`.
- Open Export: emit `released` on `/root/base/fg/ColorRect/Control/@Control@110/@Control@109/export` (a click did open it eventually but the shot was blank). Esc closes splash windows.
- The project's training node (`TrainBegin`, found by a property named `dataset_meta`) holds the training dataset's meta: for "Умная машинка" that is `car_track` with input_hints ray_0..ray_7 and label_names steer/throttle. Cards in the ready-made projects window are wrapped in runtime `Wrapper` nodes: find them with find_children and a duck-typed property.
- Runs create local state in `C:/Users/Mike/AppData/Roaming/Godot/app_userdata/nnets` (profile name, `local_projects/*.scn` copies of the built-in project, cookies, onboarding state). Tell the user; do not hand-edit `index.bin`.
- Traces in the repo: the godot bridge adds `.mcp/` to teachneurons/.gitignore and writes `.mcp/godot-runtime/`; revert with `git checkout -- .gitignore` and delete `.mcp`. `addons/*/bin/~lib*.dll` untracked files are Godot run leftovers (not mine to delete without asking).
- Pre-existing app issues seen: "Savefile corruption detected" (graph_manager.gd:554) locks autosave; dataset_tab.gd:543 "Control/view/Label/run" node not found; project-card tooltip overflows the window edge.

Related: [[brain-mapping-is-training-contract]], [[godot-tooling-setup]].
