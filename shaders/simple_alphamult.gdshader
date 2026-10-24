shader_type canvas_item;
render_mode world_vertex_coords;
varying vec2 vert;

#include "res://shaders/smooth_extents.gdshaderinc"
#include "res://shaders/design.gdshaderinc"

// Pixel design mode: 0 = adapt light text to dark ink, 1 = text on a filled
// primary button, 2 = keep the colour as authored, 3 = plain ink (node titles).
// Set by scripts/ui/design.gd.
instance uniform int design_text_role = 0;

varying vec2 vert_scale;
void vertex() {
	vert = VERTEX;
	vert_scale = vec2(length(MODEL_MATRIX[0].xy), length(MODEL_MATRIX[1].xy));
}

void fragment() {
	if (_design_pixel) {
		COLOR.rgb = d_text(COLOR.rgb, design_text_role);
	}
	COLOR.a *= alphamult(vert);
}

//void light() {
//	// Called for every pixel for every light affecting the CanvasItem.
//	// Uncomment to replace the default light processing function with this one.
//}
