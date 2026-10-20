// One map tile: satellite imagery draped over a Terrarium elevation tile.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

uniform sampler2D imagery : source_color, filter_linear_mipmap, repeat_disable;
// Terrarium-encoded PNG, read with texelFetch so the encoding is never filtered.
uniform sampler2D heightmap : filter_nearest, repeat_disable;
uniform bool has_height = false;
// Sub-rectangle of the elevation tile covering this tile: xy offset, zw scale (in UV units).
uniform vec4 height_rect = vec4(0.0, 0.0, 1.0, 1.0);
// World units per km of elevation (the vertical exaggeration).
uniform float vertical_scale = 2.0;
// How far skirt vertices hang below the edge, hiding cracks between neighbouring tiles.
uniform float skirt_depth = 0.1;
// Coarser zoom levels are pushed away from the camera along the view ray: same pixels on screen,
// but they lose the depth test wherever a finer tile overlaps them.
uniform float depth_push = 0.0;
uniform float brightness = 0.6;
uniform float desaturate = 0.35;
uniform vec3 tint = vec3(0.82, 0.9, 1.0);

float elevation_km(vec2 uv) {
	ivec2 size = textureSize(heightmap, 0);
	vec2 huv = height_rect.xy + clamp(uv, 0.0, 1.0) * height_rect.zw;
	ivec2 px = clamp(ivec2(huv * vec2(size)), ivec2(0), size - 1);
	vec3 c = texelFetch(heightmap, px, 0).rgb * 255.0;
	float metres = c.r * 256.0 + c.g + c.b / 256.0 - 32768.0;
	return max(metres, 0.0) / 1000.0;
}

void vertex() {
	if (has_height) {
		VERTEX.y = elevation_km(UV) * vertical_scale;
	}
	if (UV2.x > 0.5) {
		VERTEX.y -= skirt_depth;
	}
	if (depth_push > 0.0) {
		vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		world += (world - CAMERA_POSITION_WORLD) * depth_push;
		VERTEX = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
	}
}

void fragment() {
	vec3 c = texture(imagery, UV).rgb;
	float luma = dot(c, vec3(0.299, 0.587, 0.114));
	ALBEDO = mix(c, vec3(luma), desaturate) * tint * brightness;
}
