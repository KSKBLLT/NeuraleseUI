---
name: neuralese-nested-windows
description: How Neuralese opens a window or dialog from inside another splash window without breaking the shared blur
metadata:
  type: reference
---
Splash windows (SplashMenu) all drive the one shared `ui.blur` alpha in their `_process`, and a click inside a second window counts as an outside click for the first. So the app never stacks two windows. The pattern (scripts/workslist.gd `_hide_for_child_menu` / `_restore_from_child_menu`, delete dialog; builtin_projects_window.gd `_hide_for_transition`):

1. Parent hides but keeps the blur: `can_tween_zero = false; can_go = false; go_away(false); await quitting`.
2. Child opens with `inner = true` (`ui.splash(name, splashed_from, emitter, true, {"created_parent": parent})`, or a dialog spec with `"inner": true` and buttons `"can_go": false`, plus `dialog.can_tween_zero = false`).
3. After the result (and `await dialog.tree_exited`) the parent comes back: `can_go = true; can_tween_zero = true; splash()`. Windows opened via `created_parent` re-splash the parent in their `_quit_request`.

A parent whose `_just_go_away` tears things down (the robot window shuts its robot session there) must skip that while it is only hiding for a child.
Related: [[ui-caveats-and-duplication]], [[robot-ui-rejected-2-of-10]].
