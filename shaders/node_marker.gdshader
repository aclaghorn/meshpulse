// Screen-constant glowing dot for a mesh node, drawn from a MultiMesh of quads.
// INSTANCE_CUSTOM: rgb = colour (HDR, brighter while a packet passes), a = diameter in pixels
// at the 960 px reference height, so dots scale with the window like the UI does.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform float reference_height = 960.0;

varying vec3 v_color;

void vertex() {
	v_color = INSTANCE_CUSTOM.rgb;
	vec4 center = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	// Pull slightly toward the camera so the dot never sinks into the terrain under it.
	center.xyz *= 0.985;
	float world_per_px = 2.0 * -center.z / (PROJECTION_MATRIX[1][1] * reference_height);
	center.xy += VERTEX.xy * INSTANCE_CUSTOM.a * world_per_px;
	POSITION = PROJECTION_MATRIX * center;
}

void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float ring = smoothstep(1.0, 0.82, d) * smoothstep(0.55, 0.72, d);
	float core = smoothstep(0.5, 0.3, d);
	float halo = smoothstep(1.0, 0.0, d) * 0.35;
	ALBEDO = v_color * (core * 1.2 + ring * 0.9 + halo);
	ALPHA = clamp(core + ring + halo, 0.0, 1.0);
}
