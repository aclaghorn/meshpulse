// Camera-facing ribbon for packet trails and route lines. UV.y runs across the ribbon;
// vertex COLOR.a fades along it. Bright white-hot core inside a coloured glow.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform float energy = 3.0;
uniform float core_whiteness = 1.2;

void fragment() {
	float across = abs(UV.y * 2.0 - 1.0);
	float core = exp(-across * across * 22.0);
	float glow = exp(-across * across * 3.5) * 0.55;
	ALBEDO = COLOR.rgb * energy + vec3(core * core_whiteness);
	ALPHA = clamp(COLOR.a * (core + glow), 0.0, 1.0);
}
