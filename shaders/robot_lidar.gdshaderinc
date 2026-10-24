// The robot's lidar view (scripts/robot/robot_lidar_view.gd), shared by its
// floor and its points: the camera, the colours of the range rings, and the
// view's rounded corners. World units are metres with z up; the view's units
// are its own pixels.

// A pinhole camera at cam_pos looking along cam_f, cam_r to its right and
// cam_u up; focal in pixels, the optical centre at center.
uniform vec3 cam_pos;
uniform vec3 cam_f;
uniform vec3 cam_r;
uniform vec3 cam_u;
uniform float focal = 400.0;
uniform vec2 center;
uniform vec2 view_size;
uniform float corner_radius = 14.0;

const float LIDAR_CELL = 0.05;     // RobotLidarMap.CELL
const float LIDAR_SCAN_R = 4.0;    // how far the lidar's rings reach

// A point of the world on the view: x, y in pixels; z its depth (in front of
// the camera when over 0.08).
vec3 lidar_project(vec3 p) {
	vec3 d = p - cam_pos;
	float zc = dot(d, cam_f);
	return vec3(center.x + focal * dot(d, cam_r) / zc, center.y - focal * dot(d, cam_u) / zc, zc);
}

// The colour of a distance: orange near the robot, then yellow, green, cyan,
// blue, violet at the rings' reach.
vec3 lidar_ramp(float d) {
	float stops[6] = float[](0.0, 0.5, 1.1, 1.8, 2.7, 4.0);
	vec3 colours[6] = vec3[](
		vec3(255.0, 80.0, 30.0), vec3(255.0, 176.0, 20.0), vec3(140.0, 255.0, 60.0),
		vec3(30.0, 230.0, 190.0), vec3(30.0, 130.0, 255.0), vec3(70.0, 40.0, 255.0));
	int i = 0;
	for (int n = 0; n < 4; n++) {
		if (d > stops[i + 1]) {
			i++;
		}
	}
	float t = clamp((d - stops[i]) / (stops[i + 1] - stops[i]), 0.0, 1.0);
	return mix(colours[i], colours[i + 1], t) / 255.0;
}

// 1 inside the view's rounded rectangle, 0 outside, smooth over a pixel.
float lidar_inside(vec2 p) {
	vec2 q = abs(p - view_size * 0.5) - (view_size * 0.5 - vec2(corner_radius));
	float sdf = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner_radius;
	return clamp(0.5 - sdf, 0.0, 1.0);
}
