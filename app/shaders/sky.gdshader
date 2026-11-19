// Pulse v5 sky: colour gradient that follows the time of day, a sun, stars at night
// and drifting clouds from a tiling noise texture.
shader_type sky;

uniform vec3 zenith : source_color = vec3(0.35, 0.52, 0.72);
uniform vec3 horizon : source_color = vec3(0.62, 0.7, 0.76);
uniform vec3 ground : source_color = vec3(0.32, 0.36, 0.3);
uniform vec3 cloud_col : source_color = vec3(1.0, 0.98, 0.94);
uniform sampler2D clouds : filter_linear, repeat_enable;
uniform float cloud_cover = 0.75;
uniform float night = 0.0;
uniform vec3 sun_dir = vec3(0.3, 0.6, -0.7);

float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = clamp(d.y, -1.0, 1.0);
	vec3 col = mix(horizon, zenith, pow(clamp(h, 0.0, 1.0), 0.6));
	if (h < 0.0) {
		col = mix(horizon, ground, clamp(-h * 4.0, 0.0, 1.0));
	}
	float sd = max(dot(d, normalize(sun_dir)), 0.0);
	col += vec3(1.0, 0.85, 0.6) * (pow(sd, 400.0) * 3.0 + pow(sd, 12.0) * 0.18) * (1.0 - night);
	if (night > 0.0 && h > 0.0) {
		vec2 g = floor(d.xz / (d.y + 0.3) * 180.0);
		float st = step(0.996, hash(g)) * (0.6 + 0.4 * sin(TIME * 2.0 + hash(g * 1.7) * 30.0));
		col += vec3(st) * night * clamp(h * 3.0, 0.0, 1.0);
	}
	if (h > 0.02) {
		vec2 uv = d.xz / (d.y + 0.15) * 0.18 + vec2(TIME * 0.004, TIME * 0.0015);
		float c = texture(clouds, uv).r;
		c = smoothstep(1.0 - cloud_cover, 1.0, c) * clamp(h * 5.0, 0.0, 1.0);
		col = mix(col, cloud_col, c * 0.85);
	}
	COLOR = col;
}
