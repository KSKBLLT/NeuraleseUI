# Neuralese landmarks

Survey of `D:\NRLSE\nnets\teachneurons` at commit `cbed0e9` (2026-10-07).

Read this after SKILL.md, never instead of the survey it describes. Each entry records what was found and how it was found, so the query can be repeated. The entries describe kinds of solution that exist; the feature you are working on may need one that is not here. Counts are from the survey date and only indicate scale.

## Guardrails and documents

- `AGENTS.md` (imported by `CLAUDE.md`) is the canonical agent guide: verification commands, generated files that must not be edited by hand, where the autoload list really lives, which documents are known to be stale. Read it in full at the start of any session in the main repo.
- `docs/Neuralese_Godot_Frontend_Documentation.md` was generated on 2026-05-25 from 185 scripts and 77 scenes. The repo has grown since (115 scenes at this survey). Use it to find your way; verify each claim before repeating it.
- `docs/superpowers/specs/` contains design specs from earlier agent work. They show the expected level of detail, in particular a "visual contract" that names which existing resources a feature reuses and what it does not introduce.

## Controls

- Most clickable controls are not Godot `Button`s. They are `BlockComponent` (`scripts/block_component.gd`, extends `ColorRect`), usually instanced from `scenes/BaseBComponent.tscn` (214 instances in 44 scenes). The first line of the script says it must never be rewritten.
- `button_type` chooses between a plain block button, a context menu and a dropout menu. Hover and press colours and scales come from a `ButtonConfig` resource (`resources/*config.tres`).
- In scene files, actions on these controls are mostly connected to `released` (66 connections, against 7 on `pressed`); menus pass the child that was released through `child_button_release` and dispatch on its `hint`. In code both signals are used, partly for ordinary Godot buttons. Check what the analogue uses.
- At runtime a block button moves itself into `Wrapper` nodes, so its node path at runtime is not its path in the `.tscn`. Find runtime paths from the running tree.
- How it was found: open a visible button in a `.tscn`, follow `instance=` and `script=`; count instances by the base scene's uid and by its path.

## Text in several languages

Several mechanisms are in use; find out which one the surrounding code uses before adding text.

- A `Loc` child node (`scripts/loc.gd`) under the text-bearing control. The control's English text is the lookup key; `localizations_ru` and `localizations_kz` hold the translations. Subclasses of `Loc` also adjust layout per language. Present in about 42 scenes.
- Dictionaries keyed by language, `{"en": ..., "ru": ..., "kz": ...}`, in code and in data passed to dialogs.
- Separate per-language fields, or `match language:` branches.
- The current language comes from `glob.get_lang()`; `glob.language_changed` fires when it changes. Languages at survey time: en, ru, kz.
- Godot's `tr()` and translation files were not used at survey time.
- How it was found: searching for `tr(` returns nothing and is misleading on its own; searching for `"ru"`, `language` and `lang` finds all of the above.

## Input

- Mouse buttons are polled, not received as GUI events: `glob.press_poll()` reads `Input.is_action_just_pressed("ui_mouse")` and related actions each frame; controls combine `glob.mouse_just_pressed` with their own hit test.
- Overlapping controls are arbitrated by the project itself: `glob.occupy` / `glob.un_occupy` on named layers, and `glob.consume_input` by z-index.
- `ui.click_screen(pos)` is the project's own synthetic click: it pushes press and release events through the viewport.
- Consequence for testing: a synthetic event delivered straight to a Control may not press a `BlockComponent`. Move the mouse to the control and press through the input action path, then confirm that the expected signal fired.

## Windows and dialogs

- Older windows are `SplashMenu` scenes registered by name in `ui.splash_menus` (`scripts/ui_manager.gd`) and opened with `ui.splash(...)` or `ui.splash_and_get_result(...)`.
- Newer dialogs are built from data: `ui.show_dialog(spec)` and `ui.show_dialog_and_get_result(spec)` create a `MultipurposeDialog` from a JSON-like spec (see `scripts/dialog_spec.gd` and its design spec). They keep the `SplashMenu` lifecycle.
- Errors are shown as toasts with `ui.error(text)`.
- Some flows keep their appearance presets in code (for example `scripts/startup/startup_dialog_style.gd`).

## Styling

- There is no central palette. Colours are literals: about 300 `Color(` in scripts and about 1100 in scenes. Some features import style constants from a sibling feature's script with `preload`.
- Themes are in `resources/` (`theme*.tres`), fonts in `game_assets/fonts/`, icons in `game_assets/icons/`.
- Graphics quality has three levels (`scripts/graphics_quality.gd`, High, Medium and Low) that switch blur and animation paths, so the same UI renders differently per level.

## Global state

- The autoload list is in `project.godot` under `[autoload]`; no prose list is reliable. `glob` (`scripts/glob.gd`, about 3500 lines) is the central service locator: menu registry, window size, language, persisted settings.

## Tests and capture

- Godot tests are headless scripts in `tests/godot/` that pass by printing a marker registered in `tests/godot/run_all.sh` (details in AGENTS.md). UI tests instantiate the real scene and assert geometry, for instance that a hitbox has the visible width, or that opening a control does not move a neighbouring one.
- The project can render a single control from the running app to PNG: `ui.capture_control(...)` and `tools/capture_ui_elements.sh` (`docs/ui-capture.md`).
