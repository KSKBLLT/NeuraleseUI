shader_type canvas_item;
render_mode blend_add, unshaded;

// Every glowing point of the robot's lidar view (scripts/robot/robot_lidar_view.gd):
// one instance of a single-vertex point each, placed here from small data
// textures so the CPU never touches them one by one. A point is one vertex, so
// this runs once per point (a quad would run it four times). Instances, in order:
//   inner   az_count x 12: per direction around the robot, the 12 nearest range
//           rings on the floor up to the first wall; rings beyond it are drawn
//           as scan lines up the wall
//   outer   az_count / 2 x 14: the 14 farther rings, every other direction
//   beams   az_count x 6: beams climbing the wall a direction meets
//   sparks  echoes seen from one place only, flickering
//   trail   where the robot drove
// All additive, as the lidar mockup drew them (prototypes/lidar, style B).

#include "res://shaders/robot_lidar.gdshaderinc"

uniform sampler2D scan_tex : filter_nearest;    // az_count x 1: distance, kind (0 none, 1 wall, 3 blob), how grown, 0
uniform sampler2D spark_tex : filter_nearest;   // max_sparks x 1: x, y, z, phase
uniform sampler2D trail_tex : filter_nearest;   // trail points x 1: x, y
uniform sampler2D known_tex : filter_nearest;   // the map's cells: red over 0.5 where the floor was seen free
uniform vec4 grid;                              // the map's first cell corner (x, y), columns, rows
uniform vec2 scan_origin;
uniform int az_count = 540;
uniform int max_sparks = 512;
uniform int spark_count = 0;
uniform int trail_count = 0;
uniform float sweep = 0.0;                      // where the sweep is, radians
uniform float flicker = 0.0;                    // the sparks' clock, radians
uniform float point_scale = 1.0;                // the simple look has fewer, larger rings' points

const int INNER = 12;
const int OUTER = 14;
const int BEAMS = 6;
const float SENSOR_H = 0.22;                    // the scan lines are drawn as if from this height
const float WALL_H = 0.5;
const float BLOB_H = 0.24;

varying vec4 v_color;
varying vec2 v_local;

bool lidar_known(vec2 p) {
	ivec2 cell = ivec2(floor((p - grid.xy) / LIDAR_CELL));
	if (cell.x < 0 || cell.y < 0 || cell.x >= int(grid.z) || cell.y >= int(grid.w)) {
		return false;
	}
	return texelFetch(known_tex, cell, 0).r > 0.5;
}

void vertex() {
	int id = INSTANCE_ID;
	int inner_n = az_count * INNER;
	int outer_n = (az_count / 2) * OUTER;
	int scan_n = inner_n + outer_n + az_count * BEAMS;
	vec3 world = vec3(0.0);
	vec3 colour = vec3(0.0);
	float alpha = 0.0;
	float size = 0.0;                           // pixels
	bool shown = false;
	vec2 screen = vec2(-100000.0);
	if (id < scan_n) {
		int az;
		int slot;                               // 0..25 a ring outwards, 26..31 a beam upwards
		if (id < inner_n) {
			az = id / INNER;
			slot = id - az * INNER;
		} else if (id < inner_n + outer_n) {
			int k = id - inner_n;
			az = (k / OUTER) * 2;
			slot = INNER + k % OUTER;
		} else {
			int k = id - inner_n - outer_n;
			az = k / BEAMS;
			slot = INNER + OUTER + k % BEAMS;
		}
		vec4 s = texelFetch(scan_tex, ivec2(az, 0), 0);
		float dw = s.r;
		int kind = int(s.g + 0.5);
		float grown = s.b;
		float h = kind == 3 ? BLOB_H : WALL_H;
		float z = -1.0;
		float r = 0.0;
		if (slot < INNER + OUTER) {
			r = 0.2 * pow(1.125, float(slot));
			if (r < dw) {
				z = 0.0;
			} else if (kind > 0) {
				// A ring beyond the wall lands on it as a scan line, as high as
				// a sensor at SENSOR_H would see it.
				z = SENSOR_H * (1.0 - dw / r);
				r = dw;
				if (z > h * grown) {
					z = -1.0;
				}
			}
		} else if (kind > 0) {
			float angles[6] = float[](0.0, 3.0, 6.0, 9.0, 12.0, 16.0);
			z = SENSOR_H + dw * tan(radians(angles[slot - INNER - OUTER]));
			r = dw;
			if (z > h * grown) {
				z = -1.0;
			}
		}
		if (z >= 0.0) {
			float ang = float(az) / float(az_count) * TAU;
			world = vec3(scan_origin + vec2(cos(ang), sin(ang)) * r, z);
			vec3 p = lidar_project(world);
			if (p.z >= 0.08) {
				float behind = sweep - ang;
				behind -= floor(behind / TAU) * TAU;
				float boost = 0.5 + 0.5 * exp(-behind / 1.1);
				colour = lidar_ramp(r);
				if (z == 0.0 && r < dw) {
					alpha = (lidar_known(world.xy) ? 0.85 : 0.35) * boost;
					size = max(0.9, 1.6 / p.z) * point_scale;
				} else {
					alpha = 0.9 * boost * grown;
					size = max(1.0, 1.92 / p.z) * point_scale;
				}
				screen = p.xy;
				shown = true;
			}
		}
	} else if (id < scan_n + max_sparks) {
		int n = id - scan_n;
		if (n < spark_count) {
			vec4 s = texelFetch(spark_tex, ivec2(n, 0), 0);
			vec3 p = lidar_project(s.xyz);
			if (p.z >= 0.08) {
				colour = vec3(185.0, 166.0, 255.0) / 255.0;
				alpha = 0.1 + 0.15 * (0.5 + 0.5 * sin(flicker + s.w));
				size = 1.3;
				screen = p.xy;
				shown = true;
			}
		}
	} else {
		int n = id - scan_n - max_sparks;
		if (n < trail_count) {
			vec4 s = texelFetch(trail_tex, ivec2(n, 0), 0);
			vec3 p = lidar_project(vec3(s.xy, 0.004));
			if (p.z >= 0.08) {
				colour = vec3(60.0, 220.0, 200.0) / 255.0;
				alpha = 0.1;
				size = 1.6;
				screen = p.xy;
				shown = true;
			}
		}
	}
	// Points under a pixel and a half are drawn a pixel and a half wide with
	// the light they would have had, so they do not drop out between pixels.
	float wide = max(size, 1.5);
	v_color = vec4(colour, shown ? alpha * (size / wide) * (size / wide) : 0.0);
	POINT_SIZE = shown ? wide : 0.0;
	VERTEX = screen;
	v_local = screen;
}

void fragment() {
	COLOR = vec4(v_color.rgb, v_color.a * lidar_inside(v_local));
}
