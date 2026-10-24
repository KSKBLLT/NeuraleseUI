---
name: robot-export-progress
description: "Where the robot integration lives (repo, branch, commits), what is done, and what is still open"
metadata:
  type: project
---

Work is in the user's tree D:\NRLSE\nnets\teachneurons, branch `robot-integration` (checkpoint 2f90351, then cherry-picks of the old worktree's Python stages). Not pushed. The old worktree teachneurons-robot-export (branch robot/drive-controller) is superseded.

Done (as of 2026-10-14):
- 705670a Python: odometry.py (wheel encoders + gyro -> rover pose in world units; quantity() ports SimulationKernelAgent.encode_* exactly, golden-tested against tests/godot/robot_pose_golden.gd), "derive":"pose" inputs with "world"/"odometry" config, several motors per drive side, model_contract groups from metadata.binding with needs (sensors/wheels/heading/field/goal), EV3 one batched direct command for sonars+gyro+encoders.
- ef63ba1 Godot: robot window inside the Export window ("Робот" pill): robot list (cards) -> one build screen (LDraw-rendered robot drawing facing right, fixed sensor spots, palette with the network's inputs/outputs under Brain Mapping names, "!" rows open what they need) -> wheel check (each motor turns, child presses the arrow) -> field (training world scaled to the robot; only when the network uses place/goal) -> drive (beams, wheel power, steer/throttle indicators, Stop/Space/Esc). Datasets store metadata.world (SimulationCompiler.training_world). PIN dialog uses the nested-window pattern. Harness: tests/godot/robot_window_harness.tscn with options in %TEMP%/robot_harness_options.txt (--robot-connect=dummy --robot-fill --robot-dataset=sim_top_down_full). Test: tests/godot/test_robot_window.tscn (in run_all.sh). Python: 361 tests via local_runtime/python/python.exe tests/run_tests.py.
- cd2e255 cards drawn with the same renders.

Rules settled with the user: every conversion from the robot's length (cm_per_unit = robot length / rover length; rays 320 units); drawings are LDraw renders (tools/robot_art, credits in game_assets/robots/SOURCES.md); no "Simulations bar" robot button (4 buttons don't fit at 576 px).

Open: the Export window header (136 px) leaves the robot little room at the 670x360 minimum window; SPIKE/micro:bit have drawings but no live driver; never tested on a real EV3 (RSSI distance, auto re-pair, gyro/encoder batch read, PIN flow); micro:bit drawing is CC BY-NC-SA.

Related: [[robot-drive-conversion-is-canon]], [[brain-mapping-is-training-contract]], [[robot-ui-rejected-2-of-10]], [[simplify-means-remove]], [[neuralese-nested-windows]].
