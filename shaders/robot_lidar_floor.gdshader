shader_type canvas_item;

// The background of the robot's lidar view (scripts/robot/robot_lidar_view.gd):
// a dark blue gradient, and faint dots where the map knows the floor is free,
// away from the robot (near it the range rings show the floor). One dot per
// other cell, as the lidar mockup drew them (prototypes/lidar, style B): each
// pixel finds the floor under it and lights by the nearest dot's projection.

#include "res://shaders/robot_lidar.gdshaderinc"

uniform sampler2D known_tex : filter_nearest;   // the map's cells: red over 0.5 where the floor was seen free
uniform vec4 grid;                              // the map's first cell corner (x, y), columns, rows
uniform vec2 robot;
uniform bool floor_dots = true;                 // the simple look (Low graphics) has the gradient only

varying vec2 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	vec3 colour = mix(vec3(2.0, 4.0, 24.0), vec3(0.0, 0.0, 6.0), clamp(v_local.y / view_size.y, 0.0, 1.0)) / 255.0;
	vec3 ray = cam_f + ((v_local.x - center.x) / focal) * cam_r - ((v_local.y - center.y) / focal) * cam_u;
	if (floor_dots && ray.z < -1e-4) {
		vec2 ground = cam_pos.xy + ray.xy * (-cam_pos.z / ray.z);
		int i = 2 * int(round(((ground.x - grid.x) / LIDAR_CELL - 0.5) * 0.5));
		int j = int(floor((ground.y - grid.y) / LIDAR_CELL));
		if (i >= 0 && j >= 0 && i < int(grid.z) && j < int(grid.w) && texelFetch(known_tex, ivec2(i, j), 0).r > 0.5) {
			vec2 cell = grid.xy + (vec2(float(i), float(j)) + 0.5) * LIDAR_CELL;
			if (distance(cell, robot) >= LIDAR_SCAN_R * 0.8) {
				// A 1.1 px dot over this pixel: the part of the pixel it covers.
				vec2 off = abs(lidar_project(vec3(cell, 0.0)).xy - v_local);
				float cover = clamp(1.05 - off.x, 0.0, 1.0) * clamp(1.05 - off.y, 0.0, 1.0);
				colour += vec3(60.0, 200.0, 220.0) / 255.0 * 0.12 * cover;
			}
		}
	}
	COLOR = vec4(colour, lidar_inside(v_local));
}
