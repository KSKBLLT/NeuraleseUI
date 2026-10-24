---
name: robot-ui-rejected-2-of-10
description: User rated the first robot-window UI 2/10 (Oct 2026) — why, and the bar any new Neuralese UI must clear before it is shown
metadata:
  type: feedback
---
The first robot UI inside the Export window (steps Robot / How built / What goes where / Run, built from plain Godot Label, PanelContainer+StyleBoxFlat, LineEdit, ScrollContainer, hand-drawn bezier links) was rejected as 2/10: wrong fonts, broken layout, autowrap breaking words into columns, inconvenient click-to-connect mapping, and the flow as a whole inconvenient — "not a little, the whole thing". The blur was also too light because I zeroed `ui.blur` tuning; every other menu keeps `ui.blur.base_tuning` (black, alpha 0.576).

**Why:** I wrote layout from general Godot knowledge and judged it from my own screenshots, so the screens compiled and "worked" but did not look or behave like the rest of Neuralese.

**How to apply:**
- No new UI without first agreeing on the flow and seeing a mockup made of the app's real parts; implementation comes after the user approves it.
- Text, inputs, lists, scrolling and links come from the app's existing components (BlockComponent, its fonts and theme, the graph's own wires), never stock Godot controls with overrides.
- Never use autowrap in narrow or flexible containers; test every screen at 670×360, 1152×648 and large, in ru/en/kz, and look at each screenshot critically before calling anything done.
- Keep the shared blur tint; don't override it per window.
Related: [[ui-caveats-and-duplication]], [[neuralese-style-is-shader]], [[driving-neuralese-ui]].
