extends RefCounted
# Turns the generated model data (model_data.gd) into meshes.
# Each triangle has a palette colour. Optional extras per model:
#   "k"  - one brightness byte per vertex (128 = normal) for a hand-shaded wobble
#   "vc" - three colour bytes per vertex (blended terrain), used instead of the palette
#   "s"  - 1 = smooth (gouraud) shading, otherwise every face is flat
# Glowing colours (crystals, lamps, fire) go into a second surface drawn unshaded.
# v5: solid surfaces use the world shader, which lays a chunky pixel texture over each
# colour. The texture tile (material id) rides in the vertex colour's alpha channel.

const MD = preload("res://scripts/model_data.gd")
const WORLD_SHADER = preload("res://shaders/world.gdshader")
const ATLAS = preload("res://textures/atlas.png")

static var _cache := {}
static var _solid: ShaderMaterial = null
static var _hero: ShaderMaterial = null
static var _glow: StandardMaterial3D = null


static func solid_material() -> ShaderMaterial:
	if _solid == null:
		_solid = ShaderMaterial.new()
		_solid.shader = WORLD_SHADER
		_solid.set_shader_parameter("atlas", ATLAS)
	return _solid


static func hero_material() -> ShaderMaterial:
	if _hero == null:
		_hero = ShaderMaterial.new()
		_hero.shader = WORLD_SHADER
		_hero.set_shader_parameter("atlas", ATLAS)
		_hero.set_shader_parameter("is_hero", true)
		_hero.set_shader_parameter("tex_scale", 5.0)
	return _hero


static func glow_material() -> StandardMaterial3D:
	if _glow == null:
		_glow = StandardMaterial3D.new()
		_glow.vertex_color_use_as_albedo = true
		_glow.vertex_color_is_srgb = true
		_glow.cull_mode = BaseMaterial3D.CULL_DISABLED
		_glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return _glow


static func set_snow(amount: float) -> void:
	solid_material().set_shader_parameter("snow", clampf(amount, 0.0, 1.0))


static func set_wind(amount: float) -> void:
	solid_material().set_shader_parameter("wind", amount)


# overrides: {palette_index: Color} - used to recolour the hero (skin, hair, clothes, pickaxe).
# hero = true uses the character material (finer texture, no snow, no sway).
static func build(model_name: String, overrides: Dictionary = {}, hero: bool = false) -> ArrayMesh:
	var key := model_name + str(overrides) + ("h" if hero else "")
	if _cache.has(key):
		return _cache[key]
	var model: Dictionary = MD.MODELS[model_name]
	var verts: PackedFloat32Array = Marshalls.base64_to_raw(model["v"]).to_float32_array()
	var cols: PackedByteArray = Marshalls.base64_to_raw(model["c"])
	var bright := PackedByteArray()
	if model.has("k"):
		bright = Marshalls.base64_to_raw(model["k"])
	var vcols := PackedByteArray()
	if model.has("vc"):
		vcols = Marshalls.base64_to_raw(model["vc"])
	var smooth: bool = int(model.get("s", 0)) == 1
	var st_solid := SurfaceTool.new()
	var st_glow := SurfaceTool.new()
	st_solid.begin(Mesh.PRIMITIVE_TRIANGLES)
	st_glow.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n_solid := 0
	var n_glow := 0
	var mats: Array = MD.MATS
	for t in range(cols.size()):
		var ci: int = cols[t]
		var entry: Array = MD.PALETTE[ci]
		var base: Color = overrides.get(ci, Color(entry[0]))
		var glow: bool = entry[1]
		var mat_a := (float(mats[ci]) + 0.5) / 16.0
		var b := t * 9
		var p := [Vector3(verts[b], verts[b + 1], verts[b + 2]),
			Vector3(verts[b + 3], verts[b + 4], verts[b + 5]),
			Vector3(verts[b + 6], verts[b + 7], verts[b + 8])]
		var nrm: Vector3 = (p[1] - p[0]).cross(p[2] - p[0]).normalized()
		var st := st_glow if glow else st_solid
		for n in range(3):
			var vi := t * 3 + n
			var col := base
			if not glow:
				if vcols.size() > 0 and not overrides.has(ci):
					col = Color8(vcols[vi * 3], vcols[vi * 3 + 1], vcols[vi * 3 + 2])
				if bright.size() > 0:
					var f := float(bright[vi]) / 128.0
					col = Color(col.r * f, col.g * f, col.b * f, 1.0)
				col.a = mat_a
			st.set_color(col)
			if glow or not smooth:
				st.set_normal(nrm)
			st.add_vertex(p[n])
		if glow:
			n_glow += 1
		else:
			n_solid += 1
	var mesh := ArrayMesh.new()
	if n_solid > 0:
		if smooth:
			st_solid.index()
			st_solid.generate_normals()
		st_solid.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, hero_material() if hero else solid_material())
	if n_glow > 0:
		st_glow.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, glow_material())
	_cache[key] = mesh
	return mesh


static func instance(model_name: String, overrides: Dictionary = {}, hero: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = build(model_name, overrides, hero)
	return mi
