---
name: robot-drive-conversion-is-canon
description: "The prototype's steer/throttle -> motor conversion (AdaptiveRobotController) is hardware-proven; port it exactly, never re-derive or \"clean up\""
metadata:
  node_type: memory
  type: feedback
  originSessionId: 0fe21542-4155-4615-89f3-daf716df8888
  modified: 2026-10-12T03:56:37.759Z
---

The steer/throttle -> left/right motor conversion in D:\NRLSE\nnets\neuralese-robotics-prototype\run_real_model_drive.py (`AdaptiveRobotController.compute`) is the correct one: the real EV3 (KIRISIMA) turned correctly with it. The user stated it must be preserved so it keeps working.

Formula (as of 2026-10-11): v_turn = steer*80; v_forward = throttle_pct*(1-|steer|)^1.8; turn lock when |steer|>0.55 holds direction 350 ms and zeroes v_forward (spin in place); peak>100 trims the excess off both sides (preserves differential); slew limit 260 %/s; KIRISIMA ports left=D, right=B.

Measured on the two real datalogs: the "wall bypass" branch (front<0.5 and |model steer|<0.25 -> steer forced +-0.85, throttle<=25) DID fire: 5/1035 and 98/4220 frames. Its status label is always overwritten by the turn lock (0.85>0.55), so counting by status says 0 — I made exactly that error once. Count by the branch condition. Motors turned the model's way in 574/642 and 1920/2097 frames.

Replay fidelity (prototype class, clock = record timestamp_s, controller built at t=-1.0): turn lock and targets match 100% / 99.98% of frames; motors exact 96%; residual = slew-limiter dt jitter + .5 rounding of logged inputs.

**Why:** the user verified it on hardware; I earlier mislabelled this controller as "reflexes overriding the model" from reading code without checking the logs.

**How to apply:** port the function verbatim (only constants become named parameters with these defaults), and gate the port with a golden test that replays logs/datalog_*.jsonl through it and compares motors. The wall-bypass branch is ported behind `wall_bypass` (default pending the user's decision); schema_adapter's reflex is not ported. Check logs before calling any prototype behaviour "hardcoded". See [[godot-tooling-setup]].
