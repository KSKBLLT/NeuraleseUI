---
name: visual-qa
description: Use after any change that affects what appears on screen in a Godot project (layout, controls, text, styling, animation, windows, dialogs) and before reporting the work as done. Requires running the real scene, capturing every affected state and mode, including frame sequences for anything that moves, inspecting the captures against a defect checklist and against the existing UI, fixing what is found, and showing the evidence.
---

# Visual QA

Code that compiles and a test that passes do not show whether a button is clipped, whether a label overflows in Russian, or whether a panel jumps on the first frame of its opening animation. For visual work, the rendered result is the only evidence.

The rule of this skill: **a visual change is not reported as done until the states it affects have been captured, inspected against the checklist below, and shown to the user.** A state that could not be captured is named, with the reason.

This skill is the visual part of `superpowers:verification-before-completion`; it does not replace running the project's tests.

## 1. Decide what to look at

From the change, list:

- the surfaces changed, and their neighbours, since a resized control can push the one next to it;
- the states each affected control can be in: idle, hovered, pressed, after the action, disabled, focused, selected, empty, loading, error, open, closed;
- the modes of the application that change rendering: every interface language it supports, every graphics-quality level, the smallest supported window size, a common one and a large one, and any other mode the pattern-first survey found;
- motion: everything that animates, tweens, scrolls, expands, follows the mouse, or appears and disappears.

## 2. Capture

Use whichever of these is connected, and check the project's `docs/` and `tools/` for its own capture or test tooling first. Project tooling knows the project's layering and hidden layers.

- **Runtime bridge (`godot` MCP).** `run_project` (with `background: true` when the window should not take physical input), `get_ui_elements` for the real rectangles, texts and visibility of controls, `simulate_input` (its `watch` list samples properties after each action, and it reports which controls appeared, disappeared or changed and which signals fired), `take_screenshot`, and `run_script` for anything the other tools do not cover.
- **Desktop capture (`windows-computer-use`).** `screenshot` of the game window, `record` for motion (a timestamped frame montage plus an mp4), `play` for timed input while recording. Use it when the bridge cannot reach something, or to see the window as the user sees it.

**Motion is captured as a sequence, never as a single frame.** Prefer a script that, on every frame, saves the viewport image together with the properties that drive the motion (position, size, scale, modulate, tween progress). Then a defect can be traced to the property that misbehaves, not only to the picture. Reading the viewport image every frame stalls the GPU, so such a sequence shows correctly what happens frame by frame but not how long it takes; measure timing with the profiler.

**Confirm that synthetic input arrived.** After each simulated click or key press, check that the expected signal fired or the expected state changed. If the project polls input or arbitrates it itself, an event delivered as a GUI event can silently do nothing; then deliver it the way real input arrives, and say so in the report.

## 3. Inspect

Look at every capture, at full resolution where detail matters. Check each applicable point.

**Geometry**
- Nothing is clipped at the edge of its panel or window, and no text is cut off unless the design trims it.
- Nothing overlaps unintentionally; stacking order is right (menus over content, tooltips over menus).
- Alignment and spacing match the neighbours: the same paddings, gaps and baselines.
- The clickable area matches the visible shape: hover and click work where the control looks clickable, and only there.
- Layout holds at the smallest and the largest window size; anchors and containers resize as intended.
- Nothing moves when something unrelated changes, such as a dropdown opening, the language changing, or a hover scale.

**Text**
- In every supported language the text fits, wraps or trims as designed, contains no leftovers of another language, and shows no internal identifiers.
- Font, size and colour match the equivalent text nearby.

**Style**
- Colours, corner radii, outlines, materials and icons match the neighbours. Nothing looks like a stock Godot control inside a custom-styled interface.
- The states can be told apart: hovered, pressed and disabled look different.

**Motion**
- Animations start and end in the right place, with no single-frame flash, jump or wrong size at either end.
- No jitter: properties that should change monotonically do.
- Interrupted animations (a second click mid-animation, closing while opening) still end in a valid state.

**Behaviour**
- One click performs the action once; repeated clicks do not stack windows or fire twice.
- Escape, clicking outside and keyboard focus behave like the comparable existing surface.

**Compare with the existing UI, not with an abstract ideal.** Capture the analogue found in the pattern-first survey in the same state and mode, and put the two side by side.

## 4. Fix and repeat

Fix every defect found and retake the affected captures. After each fix, look at the neighbours again; a fix in one place often moves something else.

## 5. Report

Show the user the captures (or a montage), which points of the checklist were checked, which were not and why, and what you are unsure of. "Looks fine" without images is not a report.

Where a check can be made permanent, for example a geometry invariant or a "this does not move" assertion, propose a test written in the project's own test convention.
