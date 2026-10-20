// Radial glow quad: the packet head (ring = false) or the expanding pulse when a packet reaches a hop (ring = true).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform float energy = 4.0;
uniform bool ring = false;

void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float intensity;
	if (ring) {
		intensity = exp(-pow((d - 0.75) / 0.09, 2.0)) + exp(-d * d * 6.0) * 0.25;
	} else {
		intensity = exp(-d * d * 28.0) * 1.6 + exp(-d * d * 5.0) * 0.6;
	}
	intensity *= smoothstep(1.0, 0.9, d);
	ALBEDO = COLOR.rgb * energy + vec3(ring ? 0.0 : exp(-d * d * 60.0) * 2.0);
	ALPHA = clamp(COLOR.a * intensity, 0.0, 1.0);
}
