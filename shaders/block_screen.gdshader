shader_type canvas_item;
#include "res://shaders/std.gdshaderinc"
render_mode world_vertex_coords;
global uniform sampler2D bg: filter_linear_mipmap_anisotropic;
#define BLOCK_SAMPLE_SCREEN_TEXTURE
#include "res://shaders/block_body.gdshaderinc"
