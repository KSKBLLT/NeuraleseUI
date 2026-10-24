shader_type canvas_item;

// Pixel design: paints the workspace background around the graph card and
// leaves the card clear, so the canvas reads as a rounded white card.
// Driven by scripts/ui/workspace.gd.

uniform vec4 card_rect = vec4(0.0); // x, y, width, height in local px
uniform float radius = 24.0;
uniform vec4 frame_color = vec4(0.953, 0.965, 0.984, 1.0);
uniform vec4 edge_color = vec4(0.0, 0.0, 0.0, 0.07);

varying vec2 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	vec2 half_size = card_rect.zw * 0.5;
	vec2 q = abs(local_pos - (card_rect.xy + half_size)) - (half_size - vec2(radius));
	float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	float outside = smoothstep(-0.5, 0.5, d);
	float edge = 1.0 - smoothstep(0.0, 1.0, abs(d));
	COLOR = mix(vec4(edge_color.rgb, edge_color.a * edge), frame_color, outside);
}
