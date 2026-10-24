---
name: ui-caveats-and-duplication
description: "Rules for adding Neuralese UI: duplicate existing elements, survey the quirks of splash menus and the Simulations bottom bar, and treat existing tests as not binding"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 0fe21542-4155-4615-89f3-daf716df8888
  modified: 2026-10-12T10:26:47.860Z
---

When adding UI to teachneurons (robot window, Export pill, Simulations button):

- **Duplicate existing UI elements** (copy the neighbouring node/scene and change its parameters, e.g. the `onnx` pill in model_export.tscn, `_create_runtime_button` for runtime buttons, `builtin_project_card.tscn` for cards) instead of building new controls.
- **Watch for caveats in splash menus and button placement/anchoring, especially the Simulations bottom panel** (user: "can be tricky"). Concrete ones found 2026-10-12 are in `D:\NRLSE\nnets\prototypes\ROBOT_UI_PLAN.md` §2а: SplashMenu needs a child literally named `ColorRect`; buttons inside need `in_splash=true`; splash() disables the Simulations tab's process mode; Esc/Enter/outside-click dismissal; model_export.tscn uses absolute offsets and scaled pills; RuntimeBar is fixed-height with an HBox at separation 12 and a per-frame layout function that must not be given theme overrides.
- **The existing Godot tests are not binding.** The user said whoever wrote them was careless ("ignore them"). E.g. the exact-three-buttons and width<=560 assertions in tests/godot/test_simulation_editor.gd: update them when the UI changes; judge fit by looking at screenshots.

**Why:** the user reminded me after I presented the UI plan; the bottom panel and splash menus break easily and the codebase has a "reuse, don't reinvent" culture ([[neuralese-style-is-shader]]).

**How to apply:** before touching a splash window or the bottom bar, re-read splash_menu.gd and the runtime bar code, duplicate the nearest element, then check visually at several window widths and languages. Related: [[driving-neuralese-ui]].
