shader_type canvas_item;
#include "res://shaders/std.gdshaderinc"
render_mode world_vertex_coords;
global uniform sampler2D bg: filter_linear_mipmap_anisotropic;
#include "res://.superpowers/low-perf-proxy/proto/block_body_layered.gdshaderinc"
