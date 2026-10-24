shader_type canvas_item;

// One-shot bake of the workspace background into a quarter-resolution texture.
// The 16 bilinear taps supply the smoothness that plain downsampling lacked in
// the original optimization, while the bake only runs after the source changes.
void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE;
	vec4 acc = vec4(0.0);
	for (int y = -1; y <= 2; y++) {
		for (int x = -1; x <= 2; x++) {
			vec2 offset = (vec2(float(x), float(y)) * 2.0 - vec2(1.0)) * px;
			acc += texture(TEXTURE, UV + offset);
		}
	}
	COLOR = acc / 16.0;
}
