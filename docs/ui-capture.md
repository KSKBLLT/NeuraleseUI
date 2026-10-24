# UI element capture

The developer capture command renders real controls from the running application to lossless PNG files with transparent backgrounds. It keeps the control in its live scene tree, so inherited themes, containers, anchors, transforms, shaders, and localization remain intact.

Capture one control:

```bash
GODOT_BIN=/path/to/godot bash tools/capture_ui_elements.sh \
  --ui-capture-node=fg/ColorRect/Control/export \
  --ui-capture-output=/tmp/export-button.png \
  --ui-capture-padding=12
```

Render a small control at three times its live pixel density. This changes the
Godot canvas transform before drawing; it does not resize an already captured
bitmap:

```bash
GODOT_BIN=/path/to/godot bash tools/capture_ui_elements.sh \
  --ui-capture-node=fg/ColorRect/Control/export \
  --ui-capture-output=/tmp/export-button-3x.png \
  --ui-capture-scale=3 \
  --ui-capture-padding=12
```

Capture a control inside a generated graph node:

```bash
GODOT_BIN=/path/to/godot bash tools/capture_ui_elements.sh \
  --ui-capture-graph=input_1d \
  --ui-capture-node=input/ColorRect2 \
  --ui-capture-output=/tmp/input1d-add.png \
  --ui-capture-scale=3
```

Flatten translucent component pixels as they appear over black while keeping
the surroundings and anti-aliased outer edge transparent:

```bash
GODOT_BIN=/path/to/godot bash tools/capture_ui_elements.sh \
  --ui-capture-node=fg/ColorRect/Control/ai \
  --ui-capture-output=/tmp/axon-black-matte.png \
  --ui-capture-alpha-mode=black_matte \
  --ui-capture-matte-alpha=0.5 \
  --ui-capture-scale=3
```

Capture several controls into one directory:

```bash
GODOT_BIN=/path/to/godot bash tools/capture_ui_elements.sh \
  --ui-capture-node=fg/ColorRect \
  --ui-capture-node=fg/ColorRect/Control/ai \
  --ui-capture-node=fg/ColorRect/Label \
  --ui-capture-output-dir=/tmp/neuralese-ui
```

Node paths are relative to the main `base` node. The command temporarily hides unrelated canvas items while preserving the target's ancestor layout and target descendants. The graph background layer and its `Ffff` image are explicitly hidden for both UI captures and node-icon generation, then restored to their previous visibility.

Programmatic use is available through the `ui` autoload:

```gdscript
var result := await ui.capture_control(
  $Button,
  "res://ui_captures/button.png",
  {
    "padding": 12,
    "render_scale": 3,
    "alpha_mode": "black_matte",
    "matte_alpha": 0.5,
  }
)
```

Requested render scale is capped when the scaled element would not fit inside
its viewport. The result reports both `render_scale_requested` and the effective
`render_scale`.
