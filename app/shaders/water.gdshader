// Pulse v5 water for the underground lake: dark, gently rippling, with glints.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;

uniform vec3 deep : source_color = vec3(0.05, 0.16, 0.2);
uniform vec3 shallow : source_color = vec3(0.12, 0.4, 0.42);
uniform float bob = 0.0;     // bobber ripple strength

void vertex() {
	VERTEX.y += sin(TIME * 1.5 + VERTEX.x * 2.0) * 0.02 + cos(TIME * 1.2 + VERTEX.z * 2.5) * 0.02;
}

void fragment() {
	vec2 p = UV * 12.0;
	float r = sin(p.x * 3.0 + TIME * 1.4) * cos(p.y * 2.6 - TIME * 1.1);
	float edge = smoothstep(0.35, 0.5, distance(UV, vec2(0.5)));
	vec3 c = mix(deep, shallow, 0.35 + 0.25 * r + edge * 0.4);
	float glint = smoothstep(0.92, 1.0, sin(p.x * 7.0 + TIME * 2.0) * sin(p.y * 6.0 - TIME * 1.7));
	ALBEDO = c + vec3(0.5, 0.9, 0.85) * glint * 0.35;
	ALPHA = 0.9 * (1.0 - smoothstep(0.47, 0.5, distance(UV, vec2(0.5))));
}
