---
name: neuralese-style-is-shader
description: "Neuralese surfaces have no colour of their own: blurred backdrop + per-instance tint/outline via the block shader; reuse its materials, never pick colours by eye"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 0fe21542-4155-4615-89f3-daf716df8888
  modified: 2026-10-11T15:53:29.162Z
---

Every Neuralese surface (dialog cards, BaseBComponent buttons, graph nodes) is the SDF rounded rect in `shaders/block_body.gdshaderinc`: fill = blurred backdrop (global `bg` texture or screen, mip LOD + 9-tap gaussian) * `mult`, alpha-blended with the per-instance `tuning` tint, plus a per-instance `outline_color`. The violet you see is the background image showing through, not a panel colour.

Materials: panels `scenes/splash.tres` (block_screen shader, corner ~13.9, outline 1.3, blur -3.38); full-screen backdrop `scenes/blur.tscn` (`ui.blur`, tuning black a=0.576); buttons `resources/add_button.tres` (block shader, corner ~16.9, outline 1.5, blur 4.48) with `resources/default_config.tres` hover x1.1*1.3 / press x0.9. Startup/onboarding dialogs use `"surface": "transparent"` over `ui.blur` with sizes from `StartupDialogStyle`. Graphics quality globals (`_quality_disable_blur`, `_quality_use_baked_blur`) change the look.

**Why:** I described panels as "dark translucent lilac" from screenshots; the user corrected me: they are blurred + transparent, read the code, do not invent colours, do not reinvent the wheel.

**How to apply:** new UI reuses these materials/scenes and copies instance params (`tuning`, `outline_color`) from the nearest existing surface; accent colours only from existing code (e.g. Brain Mapping status 77dfa2 / ef795f, built-in card `accent_color`). Related: [[brain-mapping-is-training-contract]].
