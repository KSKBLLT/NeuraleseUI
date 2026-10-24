shader_type canvas_item;

#include "res://shaders/smooth_extents.gdshaderinc"
#include "res://shaders/design.gdshaderinc"

// Pixel design: 2 keeps colours (images use this shader too); the design
// autoload sets 0 on labels so their light text becomes dark ink.
instance uniform int design_text_role = 2;

void fragment() {
	vec2 screen_coord = SCREEN_UV / SCREEN_PIXEL_SIZE;
	if (_design_pixel) {
		COLOR.rgb = d_text(COLOR.rgb, design_text_role);
	}
	COLOR.a *= alphamult(screen_coord);
}
