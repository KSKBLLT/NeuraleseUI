// Pixel design mode: light Material 3 scheme (seed #8C52FF, the logo violet).
// Toggled by the `_design_pixel` shader global; see scripts/ui/design.gd.
// The colours here mirror scripts/ui/design.gd — change both together.

global uniform bool _design_pixel;

const vec3 D_SURFACE = vec3(0.996, 0.969, 1.0);      // #FEF7FF
const vec3 D_SC_LOWEST = vec3(1.0);                  // #FFFFFF
const vec3 D_SC_LOW = vec3(0.973, 0.945, 0.980);     // #F8F1FA
const vec3 D_SC_HIGH = vec3(0.925, 0.902, 0.933);    // #ECE6EE
const vec3 D_SC_HIGHEST = vec3(0.902, 0.878, 0.918); // #E6E0EA
const vec3 D_ON_SURFACE = vec3(0.114, 0.106, 0.125); // #1D1B20
const vec3 D_ON_SURFACE_VAR = vec3(0.290, 0.267, 0.333); // #4A4455
const vec3 D_OUTLINE_VAR = vec3(0.800, 0.765, 0.847);    // #CCC3D8
const vec3 D_PRIMARY = vec3(0.435, 0.176, 0.882);    // #6F2DE1
const vec3 D_ON_PRIMARY = vec3(1.0);
const vec3 D_TONAL = vec3(0.918, 0.867, 1.0);        // #EADDFF
const vec3 D_ON_TONAL = vec3(0.227, 0.114, 0.443);   // #3A1D71

// Roles set per CanvasItem by the adapter (instance uniform `design_role`).
const int D_ROLE_AUTO = 0;
const int D_ROLE_NODE = 1;      // graph node body
const int D_ROLE_FIELD = 2;     // block inside a graph node
const int D_ROLE_PRIMARY = 3;   // the one filled action on a screen
const int D_ROLE_TONAL = 4;     // selected tab, secondary action
const int D_ROLE_PANEL = 5;     // side panels, menus
const int D_ROLE_QUIET = 6;     // neutral button on a surface

float d_luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
float d_chroma(vec3 c) { return max(max(c.r, c.g), c.b) - min(min(c.r, c.g), c.b); }

// Pushes a colour's hue harder before tinting, so muted category colours
// still read as their hue once mixed with white.
vec3 d_hue_of(vec3 c) {
	float l = d_luma(c);
	return clamp(vec3(l) + (c - vec3(l)) * 1.8, 0.0, 1.0);
}

// Radius in local units for a role; `local_half` is the half size in local units.
float d_radius(int role, vec2 local_half) {
	float m = min(local_half.x, local_half.y);
	if (role == D_ROLE_NODE) { return 20.0; }
	if (role == D_ROLE_FIELD) { return min(12.0, m); }
	if (role == D_ROLE_PANEL) { return min(28.0, m); }
	if (role == D_ROLE_PRIMARY || role == D_ROLE_TONAL || role == D_ROLE_QUIET) { return m; }
	// auto: anything button-sized is a pill, large surfaces get the panel radius
	if (m <= 24.0) { return m; }
	if (m >= 110.0) { return 28.0; }
	return 16.0;
}

// Text colour: light text written for the dark theme becomes dark ink;
// coloured text keeps its hue at a readable depth.
vec3 d_text(vec3 c, int text_role) {
	if (text_role == 1) { return D_ON_PRIMARY; }
	if (text_role == 2) { return c; }
	if (text_role == 3) { return D_ON_SURFACE; }
	if (d_chroma(c) > 0.18) {
		return clamp(d_hue_of(c) * 0.42, 0.0, 1.0);
	}
	float t = clamp((1.0 - d_luma(c)) / 0.55, 0.0, 1.0);
	return mix(D_ON_SURFACE, D_ON_SURFACE_VAR, t);
}
