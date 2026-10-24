extends Node

## Scene-owned knobs for the temporary decorative inference traversal.
## This has no relationship to ONNX execution or model outputs.

@export_group("BFS Timeline")
@export_range(0.0, 2.0, 0.01, "suffix:s") var hop_delay := 0.22

@export_group("Spline Pulse")
@export_range(0.05, 3.0, 0.01, "suffix:s") var spline_flow_duration := 0.72
@export var spline_flow_color := Color.WHITE
@export_range(0.05, 2.0, 0.05) var spline_initial_energy := 1.0
@export_range(0.0, 2.0, 0.05) var spline_repeat_energy := 0.65
@export_range(1.0, 5.0, 0.05) var spline_max_energy := 2.5
@export_range(0.0, 2.0, 0.01, "suffix:s") var spline_release_delay := 0.16
@export_range(0.05, 2.0, 0.01, "suffix:s") var spline_tail_duration := 0.38

@export_group("Node Highlight")
@export var node_highlight_color := Color("fff3a6")
@export_range(0.01, 1.0, 0.01, "suffix:s") var node_highlight_fade_in := 0.08
@export_range(0.0, 2.0, 0.01, "suffix:s") var node_highlight_hold := 0.10
@export_range(0.01, 2.0, 0.01, "suffix:s") var node_highlight_fade_out := 0.32
@export_range(0.0, 1.0, 0.01) var node_highlight_shadow_opacity := 0.50
@export_range(0.0, 2.0, 0.05) var node_repeat_energy := 0.55
@export_range(1.0, 5.0, 0.05) var node_max_energy := 2.25

@export_group("")
