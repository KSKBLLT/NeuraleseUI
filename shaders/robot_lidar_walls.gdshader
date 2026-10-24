shader_type canvas_item;
render_mode blend_add, unshaded;

// The walls the robot's lidar view remembers (scripts/robot/robot_lidar_view.gd),
// drawn as the lidar mockup drew them (prototypes/lidar, style B): faint dots
// every 4 cm along each wall, at its foot and at its top. One instance of a
// unit quad per wall and height, stretched into a thin strip from one end to
// the other; the fragment cuts it into dots.

#include "res://shaders/robot_lidar.gdshaderinc"

uniform sampler2D wall_tex : filter_nearest;    // max_walls x 2: x1, y1, x2, y2 / alpha, dots, 0, 0
uniform int wall_count = 0;

const float WALL_H = 0.5;

varying vec4 v_color;
varying vec2 v_local;
varying vec2 v_along;                           // position along the wall in dots / depth, 1 / depth

void vertex() {
	int n = INSTANCE_ID / 2;
	vec2 screen = vec2(-100000.0);
	v_color = vec4(0.0);
	v_along = vec2(0.0, 1.0);
	if (n < wall_count) {
		vec4 ends = texelFetch(wall_tex, ivec2(n, 0), 0);
		vec4 info = texelFetch(wall_tex, ivec2(n, 1), 0);
		float z = INSTANCE_ID % 2 == 0 ? 0.02 : WALL_H * info.r;
		vec3 a = lidar_project(vec3(ends.xy, z));
		vec3 b = lidar_project(vec3(ends.zw, z));
		if (a.z >= 0.08 && b.z >= 0.08) {
			// A pixel and a half wide, and as much past each end.
			float t = VERTEX.x + 0.5;
			vec2 along = normalize(b.xy - a.xy + vec2(1e-4, 0.0));
			vec2 across = vec2(-along.y, along.x);
			screen = mix(a.xy, b.xy, t) + along * VERTEX.x * 1.5 + across * VERTEX.y * 1.5;
			float depth = mix(a.z, b.z, t);
			v_along = vec2(t * info.g / depth, 1.0 / depth);
			// Dots 1.2 px wide in a strip 1.5 px wide: the light they would have had.
			v_color = vec4(vec3(120.0, 200.0, 255.0) / 255.0, 0.3 * info.r * (1.2 / 1.5));
		}
	}
	VERTEX = screen;
	v_local = screen;
}

void fragment() {
	// How far this pixel is from the nearest dot along the wall, in pixels.
	float s = v_along.x / v_along.y;
	float per_px = max(length(vec2(dFdx(s), dFdy(s))), 1e-4);
	float gap_px = abs(s - round(s)) / per_px;
	COLOR = vec4(v_color.rgb, v_color.a * clamp(0.6 + 0.5 - gap_px, 0.0, 1.0) * lidar_inside(v_local));
}
