// shape: 0=rect,1=triangle,2=rhombus, 3=circle
uniform int shape: hint_range(0,2) = 0;

uniform vec4 mult_tuning: source_color = vec4(1.0);
instance uniform vec4 tuning: source_color = vec4(1.0);
uniform vec4 color_mult: source_color = vec4(1.0);

#include "res://shaders/smooth_extents.gdshaderinc"
#include "res://shaders/design.gdshaderinc"

// Pixel design mode (see shaders/design.gdshaderinc): role and optional exact
// colours, set per item by scripts/ui/design.gd. Ignored in the classic look.
instance uniform int design_role = 0;
instance uniform vec4 design_fill = vec4(0.0);
instance uniform vec4 design_line = vec4(0.0);

global uniform float _view_scale = 1.0;
global uniform bool _quality_disable_blur = false;
global uniform bool _quality_use_baked_blur = false;
instance uniform vec2 corner_radius_width_add = vec2(0,0);
uniform float corner_radius: hint_range(0.0, 100.0) = 8.0;
uniform bool blurred_background = true;
uniform float outline_width: hint_range(0.0, 50.0) = 0.0;
uniform float mult = 2.0;
instance uniform vec4 outline_color: source_color = vec4(1.0);

uniform float blur_level: hint_range(-7.0, 7.0) = 2.5;
uniform float gaussian_mix: hint_range(0.0, 1.0) = 1.0;
uniform float gaussian_step: hint_range(0.0, 8.0) = 1.0;

varying vec2 view_scale;
varying vec2 vert_scale;
varying vec2 vert;
varying vec4 modulate;

void vertex() {
	vert = VERTEX;
	modulate = COLOR;
	view_scale = vec2(length(CANVAS_MATRIX[0].xy), length(CANVAS_MATRIX[1].xy));
	vert_scale = vec2(length(MODEL_MATRIX[0].xy), length(MODEL_MATRIX[1].xy));
}

bool in_bounds(vec2 uv) {
	return uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0;
}

uniform bool use_bg = true;
// The workspace background baked at 1/8 resolution (scripts/bg.gd), about
// what mip level 3 of `bg` would be.
global uniform sampler2D bg_soft: filter_linear;

#ifdef BLOCK_SAMPLE_SCREEN_TEXTURE
uniform sampler2D screen: hint_screen_texture, filter_linear_mipmap;
#endif

vec4 sample_backdrop(vec2 uv, float lod) {
#ifdef BLOCK_SAMPLE_SCREEN_TEXTURE
	// Medium publishes a 1/4-resolution baked backdrop through `bg`; avoid
	// sampling the live screen there without swapping the shared Shader resource.
	if (!use_bg && !_quality_use_baked_blur) {
		return textureLod(screen, uv, lod);
	}
#endif
	if (_quality_use_baked_blur) {
		return textureLod(bg, uv, lod);
	}
	// On High `bg` is the sharp background viewport, and a viewport texture has
	// no mipmaps: a level of detail cannot blur it, and the gaussian taps then
	// lay sharp copies of the background over each other (a kaleidoscope on
	// the pixel-art backdrop). Past level 1 the sharp image gives way to the
	// bake, fully by level 3, as mipmaps would.
	float soft = clamp((lod - 1.0) * 0.5, 0.0, 1.0);
	if (soft >= 1.0) {
		return textureLod(bg_soft, uv, 0.0);
	}
	vec4 sharp = textureLod(bg, uv, 0.0);
	return soft > 0.0 ? mix(sharp, textureLod(bg_soft, uv, 0.0), soft) : sharp;
}

vec4 sample_screen_safe(vec2 uv, float lod) {
	vec4 cont = sample_backdrop(uv, lod);
	return in_bounds(uv) ? cont : vec4(cont.rgb, 0.0);
}

vec4 gaussian9_mip(vec2 uv, float lod, vec2 step_px) {
	vec2 sx = vec2(step_px.x, 0.0);
	vec2 sy = vec2(0.0, step_px.y);

	vec4 c  = sample_screen_safe(uv, lod) * 4.0;

	vec4 ax = sample_screen_safe(uv - sx, lod) * 2.0
	        + sample_screen_safe(uv + sx, lod) * 2.0;

	vec4 ay = sample_screen_safe(uv - sy, lod) * 2.0
	        + sample_screen_safe(uv + sy, lod) * 2.0;

	vec4 d  = sample_screen_safe(uv + sx + sy, lod)
	        + sample_screen_safe(uv + sx - sy, lod)
	        + sample_screen_safe(uv - sx + sy, lod)
	        + sample_screen_safe(uv - sx - sy, lod);

	return (c + ax + ay + d) / 16.0;
}

vec4 design_block(vec2 p, vec2 half, vec2 v_scale, vec2 i_scale, vec4 tint) {
	float px_per_unit = max(min(v_scale.x, v_scale.y) * i_scale.x, 0.0001);
	int role = design_role;
	float r = min(d_radius(role, half / px_per_unit) * px_per_unit, min(half.x, half.y));
	vec2 q = abs(p) - (half - vec2(r));
	float sdf = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
	float mask = smoothstep(1.0, -1.0, sdf);

	// The hue this block carries in the classic look: its outline, else its tint.
	vec3 src = outline_color.rgb;
	if (d_chroma(src) < 0.12 && d_chroma(tuning.rgb) > 0.12) { src = tuning.rgb; }
	bool hued = d_chroma(src) >= 0.12;
	vec3 hue = d_hue_of(src);

	vec3 fill;
	vec3 line;
	float line_w = 1.0;
	if (role == D_ROLE_NODE) {
		fill = design_fill.a > 0.0 ? design_fill.rgb : mix(D_SC_LOWEST, hue, 0.10);
		line = design_line.a > 0.0 ? design_line.rgb : mix(D_SC_LOWEST, hue, 0.30);
	} else if (role == D_ROLE_FIELD) {
		fill = D_SC_LOWEST;
		line = design_line.a > 0.0 ? design_line.rgb : (hued ? mix(D_SC_LOWEST, hue, 0.28) : D_OUTLINE_VAR);
	} else if (role == D_ROLE_PRIMARY) {
		fill = design_fill.a > 0.0 ? design_fill.rgb : D_PRIMARY; line = fill; line_w = 0.0;
	} else if (role == D_ROLE_TONAL) {
		fill = design_fill.a > 0.0 ? design_fill.rgb : D_TONAL; line = fill; line_w = 0.0;
	} else if (role == D_ROLE_PANEL) {
		fill = design_fill.a > 0.0 ? design_fill.rgb : D_SC_LOW; line = fill; line_w = 0.0;
	} else if (role == D_ROLE_QUIET) {
		fill = D_SC_HIGH; line = D_SC_HIGH; line_w = 0.0;
	} else if (hued) {
		fill = mix(D_SC_LOWEST, hue, 0.14);
		line = mix(D_SC_LOWEST, hue, 0.38);
	} else {
		fill = D_SC_LOWEST;
		line = D_OUTLINE_VAR;
	}

	float w = line_w * px_per_unit;
	float band = w > 0.01 ? smoothstep(-w - 0.75, -w + 0.75, sdf) : 0.0;
	vec4 col = vec4(mix(fill, line, band), 1.0);

	// Invisible in the classic look (no glass, no tint, no outline) stays invisible.
	float tint_a = tuning.a * mult_tuning.a * color_mult.a;
	bool glass = blurred_background && !_quality_disable_blur;
	if (!glass && tint_a < 0.02 && role == D_ROLE_AUTO) {
		col.a = (outline_width + corner_radius_width_add.y) > 0.01 ? band * outline_color.a : 0.0;
	}

	// Classic hover brightens with modulate > 1: show it as an 8% state layer.
	if (d_luma(tint.rgb) > 1.02) {
		col.rgb = mix(col.rgb, role == D_ROLE_PRIMARY ? vec3(1.0) : D_ON_SURFACE, 0.08);
	}
	col.a *= mask * tint.a;
	return col;
}

void fragment() {
	vec2 size_px = vec2(1.0 / dFdx(UV).x, 1.0 / dFdy(UV).y);
	vec2 half = size_px * 0.5;
	vec2 p = UV * size_px - half;

	if (_design_pixel) {
		COLOR = design_block(p, half, view_scale, vert_scale, modulate);
		COLOR.a *= alphamult(vert);
	} else {

	float radius_added = corner_radius_width_add.x + corner_radius;
	float r = radius_added * min(view_scale.x, view_scale.y) * vert_scale.x;
	float w = (outline_width + corner_radius_width_add.y) * min(view_scale.x, view_scale.y) * vert_scale.y;

	float sdf;
	if (false) {
	} else {
		vec2 q = abs(p) - (half - vec2(r));
		sdf = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
	}

	float mask = smoothstep(1.0, -1.0, sdf);
	float ol = smoothstep(w + 1.0, w - 1.0, abs(sdf));
	if (outline_width + corner_radius_width_add.y < 0.01) { ol = 0.0; }

	vec4 col;
	vec4 out_col = outline_color;

	if (blurred_background && !_quality_disable_blur) {
		float lod = blur_level < 0.0 ? -blur_level : blur_level * _view_scale;

		vec2 step_px = SCREEN_PIXEL_SIZE * max(gaussian_step, 0.0001) * (1.0 + blur_level);

		vec4 bg_lod = sample_backdrop(SCREEN_UV, lod);
		vec4 bg_;
		if (gaussian_mix > 0.001 && !_quality_use_baked_blur) {
			vec4 bg_gauss = gaussian9_mip(SCREEN_UV, lod, step_px);
			bg_ = mix(bg_lod, bg_gauss, gaussian_mix) * mult;
		} else {
			bg_ = bg_lod * mult;
		}

		if (ol < 0.999) {
			col = mix(alpha_blend(bg_, tuning * mult_tuning) * color_mult, out_col, ol);
		} else {
			col = out_col;
		}
	} else {
		col = mix(tuning * mult_tuning * color_mult, outline_color, ol);
	}

	col.a *= mask;
	COLOR = col * modulate;
	COLOR.a *= alphamult(vert);
	}
}
