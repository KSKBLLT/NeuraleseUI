---
name: brain-mapping-is-training-contract
description: "Simulations' Brain Mapping is the record of what the model was trained on (inputs/outputs), not a UI design source"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 0fe21542-4155-4615-89f3-daf716df8888
  modified: 2026-10-11T15:36:41.628Z
---

In teachneurons, the Simulations Brain Mapping (`model_binding` on the agent: sensor/actuator ranges over the model's input/output indices) tells you how the child trained the model. Use it as the input to robot I/O auto-mapping. Do not treat its panel as the design reference for new UI.

The robot task's model: inputs are ray casts (ray_distance, 8 rays, 132 deg arc, 320 units) plus whatever else the binding enables (e.g. speed); outputs are steering and throttle (brake possible). Read the binding, never assume.

**Why:** the user corrected me when I proposed reusing the Brain Mapping panel as the robot UI style; style must come from looking at the running app.

**How to apply:** for robot mapping, read the agent's `model_binding` from the world/dataset that trained the model; for visual style, run Neuralese and capture screenshots. Related: [[robot-drive-conversion-is-canon]].
