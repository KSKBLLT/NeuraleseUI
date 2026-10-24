---
name: old-robot-export-layer-is-stale
description: docs/ROBOT_EXPORT.md and the NLR/1 robot layer in teachneurons (Aug 2026) are outdated; not a source of instructions
metadata:
  node_type: memory
  type: feedback
  originSessionId: 0fe21542-4155-4615-89f3-daf716df8888
  modified: 2026-10-12T08:50:03.232Z
---

In teachneurons, `docs/ROBOT_EXPORT.md` and the robot layer it describes (`local_runtime/neuralese_local/robot`: NLR/1 codec, RobotBridge, generated device scripts for micro:bit/SPIKE/ev3dev, USB/serial/TCP/BLE transports, `run_robot.py`) are an old experiment. Two commits by Yernar on 2026-08-11, untouched since. Only the `scripts/run_manager.gd` wrappers call it, and no scene does. The user says it is very old and out of date, especially the USB parts.

**Why:** in stages 1–2 I built on it without checking whether it was current: Dummy/EV3 wrapped into a fake NLR/1 device so the old bridge could be reused, the config schema extended, and docs written into ROBOT_EXPORT.md. The user called this out.

**How to apply:** the robotics prototype (`neuralese-robotics-prototype`) plus the user's decisions are the source for robot work. Before reusing anything from the old layer, ask the user. Related: [[robot-export-progress]], [[robot-drive-conversion-is-canon]].
