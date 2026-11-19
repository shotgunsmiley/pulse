// Pulse v5 world shader: 2007-era chunky pixel textures without UV maps.
// Each vertex colour's alpha holds a material id (see gen/models.py MAT_OF); the shader
// projects that tile of the texture atlas onto the model from three sides (triplanar)
// and multiplies it with the colour. Leaves sway in the wind and winter adds snow on top.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_disabled;

uniform sampler2D atlas : filter_nearest, repeat_disable;
uniform float tex_scale = 1.6;      // tiles per metre
uniform float snow = 0.0;           // 0..1, winter coverage on upward faces
uniform float wind = 1.0;
uniform bool is_hero = false;

varying vec3 obj_pos;
varying vec3 obj_nrm;
varying flat int mat_id;

void vertex() {
	obj_pos = VERTEX;
	obj_nrm = NORMAL;
	mat_id = int(COLOR.a * 16.0);
	if (mat_id == 5 && !is_hero && VERTEX.y > 1.0) {
		vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float k = (VERTEX.y - 1.0) * 0.035 * wind;
		VERTEX.x += sin(TIME * 1.3 + w.x * 0.4 + w.z * 0.3) * k;
		VERTEX.z += cos(TIME * 1.1 + w.z * 0.5) * k * 0.6;
	}
	COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
}

vec3 tile_sample(vec2 uv, int id) {
	vec2 cell = vec2(float(id % 4), float(id / 4));
	vec2 f = fract(uv);
	return texture(atlas, (cell + clamp(f, 0.002, 0.998)) * 0.25).rgb;
}

void fragment() {
	// The generated models do not all share one triangle winding, so orient every
	// normal toward the camera: a surface you can see always faces you.
	vec3 nv = NORMAL;
	if (dot(nv, VIEW) < 0.0) {
		nv = -nv;
	}
	NORMAL = nv;
	vec3 base = COLOR.rgb;
	if (mat_id > 0) {
		vec3 n = abs(normalize(obj_nrm));
		n = pow(n, vec3(4.0));
		n /= (n.x + n.y + n.z + 0.0001);
		vec3 p = obj_pos * tex_scale;
		vec3 t = tile_sample(p.zy, mat_id) * n.x + tile_sample(p.xz, mat_id) * n.y + tile_sample(p.xy, mat_id) * n.z;
		base *= t * 2.0;
	}
	if (!is_hero && snow > 0.0) {
		float up = (INV_VIEW_MATRIX * vec4(nv, 0.0)).y;
		float s = clamp((up - 0.55) * 3.0, 0.0, 1.0) * snow;
		base = mix(base, vec3(0.86, 0.9, 0.95), s);
	}
	ALBEDO = base;
}
