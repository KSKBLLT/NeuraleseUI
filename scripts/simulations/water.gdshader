shader_type canvas_item;

uniform vec4 water_color : source_color = vec4(0.3, 0.65, 1.0, 0.35);
uniform vec2 rect_size = vec2(100.0, 100.0);

void fragment() {
    // We want the wave to look consistent regardless of rect size, so we scale UVs by size to get pixel-like coordinates.
    vec2 pos = UV * rect_size;
    
    // Vectorized wave calculation (1 vec3 sin, 1 dot product instead of 3 scalar sines)
    vec3 wave_phases = pos.x * vec3(0.05, 0.02, 0.1) + TIME * vec3(3.0, -1.5, 4.5);
    float wave_y = 12.0 + dot(sin(wave_phases), vec3(4.0, 2.0, 1.0));
    
    // Mask for water surface (branchless: 0.0 above wave, 1.0 below wave)
    float water_mask = step(wave_y, pos.y);
    
    // Random Bubbles using pixel grid (div by 30.0 is mul by 0.03333333)
    vec2 cell_coord = vec2(pos.x, pos.y + TIME * 45.0) * 0.03333333; 
    vec2 cell_id = floor(cell_coord);
    vec2 local_uv = fract(cell_coord) - 0.5;
    
    // Pseudo-random value per cell
    float rand_val = fract(sin(dot(cell_id, vec2(12.9898, 78.233))) * 43758.5453);
    
    // Bubble properties and branchless mask
    float cell_has_bubble = step(0.85, rand_val);
    float b_size = rand_val * 0.2 - 0.1; // roughly 30% smaller, less variance
    local_uv.x -= cos(TIME * 2.0 + rand_val * 10.0) * 0.2; // bubble horizontal drift
    
    // Squared distance check to avoid expensive sqrt() in length()
    float is_bubble = step(dot(local_uv, local_uv), b_size * b_size) * cell_has_bubble;
    
    // Combine base color with additive bubble color, apply wave mask branchlessly
    COLOR = vec4(water_color.rgb + vec3(0.5 * is_bubble), water_color.a + 0.1 * is_bubble) * water_mask;
}
