extends Node3D
# v5.5 WORLD BOSSES - the five monsters that come to the town square.
# Every monster is built in code from chunky low-poly shapes (like the rest of the game)
# and drawn with the world shader, so it gets the same pixel texture. Each one has its
# own idle loop, a flinch when hit, a show-off attack every few seconds, an arrival,
# a death and an escape. The server decides everything; this is only the picture.
#   golem   Rock Golem      - hardens to granite (only perfect hits count)
#   wyrm    Cave Wyrm       - burrows under the square for a few seconds
#   spider  Crystal Spider  - fast and twitchy, crystals on its back
#   wraith  Void Wraith     - floats, feeds on misses
#   drake   Ember Drake     - fire shield, rages when low

signal gone

const MB = preload("res://scripts/mesh_builder.gd")

# How far from its centre a fighter stands, and how tall it is (for the name tag).
const REACH := {"golem": 2.5, "wyrm": 2.7, "spider": 3.0, "wraith": 2.3, "drake": 3.3}
const HEIGHT := {"golem": 3.9, "wyrm": 4.3, "spider": 2.6, "wraith": 3.7, "drake": 3.9}
const LIGHT := {"golem": "#ffb35c", "wyrm": "#ff6a4a", "spider": "#5fe0cf", "wraith": "#b48cf0", "drake": "#ff9a40"}

var kind := ""
var parts := {}
var body: Node3D
var mat: ShaderMaterial
var light: OmniLight3D
var shield: MeshInstance3D = null
var harden: Node3D = null
var embers: CPUParticles3D = null
var wisps: CPUParticles3D = null
var t := 0.0
var speed := 1.0
var hit_t := 0.0
var atk_t := -1.0
var atk_wait := 3.0
var flash := 0.0
var sink := 0.0           # wyrm: how far underground (0 = up)
var sink_goal := 0.0
var tricks := {}
var busy := false         # arriving, dying or fleeing: no idle control of the body
var dead := false         # dying or fled: ignore anything the server says now
var seg_base := []        # wyrm segments: their rest positions
var tint_now := Vector3.ONE


# ------------------------------------------------------------------ mesh kit
# Collects triangles for one moving part; solid faces get the world shader, glowing
# faces (eyes, crystals, embers) go into an unshaded second surface.
class Kit:
	var solid := SurfaceTool.new()
	var glow := SurfaceTool.new()
	var ns := 0
	var ng := 0
	var seed := 1

	func _init() -> void:
		solid.begin(Mesh.PRIMITIVE_TRIANGLES)
		glow.begin(Mesh.PRIMITIVE_TRIANGLES)

	func _rnd() -> float:
		seed = (seed * 1103515245 + 12345) % 2147483648
		return float(seed % 10000) / 10000.0

	func tri(a: Vector3, b: Vector3, c: Vector3, col: Color, m: int = 0, g: bool = false) -> void:
		var n := (b - a).cross(c - a).normalized()
		var st: SurfaceTool = glow if g else solid
		var cc := col
		if not g:
			# a little hand-shaded wobble per face, like the generated models
			var k := 0.9 + _rnd() * 0.2
			cc = Color(col.r * k, col.g * k, col.b * k, (float(m) + 0.5) / 16.0)
		for p in [a, b, c]:
			st.set_color(cc)
			st.set_normal(n)
			st.add_vertex(p)
		if g:
			ng += 1
		else:
			ns += 1

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, m: int = 0, g: bool = false) -> void:
		tri(a, b, c, col, m, g)
		tri(a, c, d, col, m, g)

	func _bas(rot: Vector3) -> Basis:
		return Basis.from_euler(rot * (PI / 180.0))

	# A box, optionally narrower at the top (taper) and turned (degrees).
	func box(c: Vector3, s: Vector3, col: Color, m: int = 0, g: bool = false, rot: Vector3 = Vector3.ZERO, taper: float = 1.0) -> void:
		var b := _bas(rot)
		var h := s * 0.5
		var v := []
		for y in [-1, 1]:
			var k := taper if y > 0 else 1.0
			for corner in [[-1, -1], [1, -1], [1, 1], [-1, 1]]:
				v.append(c + b * Vector3(h.x * corner[0] * k, h.y * y, h.z * corner[1] * k))
		quad(v[0], v[1], v[2], v[3], col, m, g)
		quad(v[4], v[5], v[6], v[7], col, m, g)
		for i in range(4):
			var j := (i + 1) % 4
			quad(v[i], v[j], v[j + 4], v[i + 4], col, m, g)

	# A box stretched between two points (arms, legs, bones).
	func limb(a: Vector3, z: Vector3, w: float, d: float, col: Color, m: int = 0, g: bool = false, taper: float = 1.0) -> void:
		var dir := z - a
		var y := dir.normalized()
		var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
		var zz := x.cross(y).normalized()
		var bas := Basis(x, y, zz)
		var h := dir.length() * 0.5
		var v := []
		for yy in [-1, 1]:
			var k := taper if yy > 0 else 1.0
			for corner in [[-1, -1], [1, -1], [1, 1], [-1, 1]]:
				v.append(a + dir * 0.5 + bas * Vector3(w * 0.5 * corner[0] * k, h * yy, d * 0.5 * corner[1] * k))
		quad(v[0], v[1], v[2], v[3], col, m, g)
		quad(v[4], v[5], v[6], v[7], col, m, g)
		for i in range(4):
			var j := (i + 1) % 4
			quad(v[i], v[j], v[j + 4], v[i + 4], col, m, g)

	# A lumpy low-poly ellipsoid (rocks, bodies, heads).
	func blob(c: Vector3, r: Vector3, col: Color, m: int = 0, g: bool = false, seg: int = 7, rings: int = 5, jitter: float = 0.0, rot: Vector3 = Vector3.ZERO) -> void:
		var b := _bas(rot)
		var grid := []
		for i in range(rings + 1):
			var lat := PI * float(i) / float(rings) - PI / 2.0
			var row := []
			for j in range(seg):
				var lon := TAU * float(j) / float(seg) + (0.0 if i % 2 == 0 else PI / float(seg))
				var k := 1.0 + (jitter * (_rnd() - 0.5) * 2.0 if i > 0 and i < rings else 0.0)
				var p := Vector3(cos(lat) * cos(lon) * r.x, sin(lat) * r.y, cos(lat) * sin(lon) * r.z) * k
				row.append(c + b * p)
			grid.append(row)
		for i in range(rings):
			for j in range(seg):
				var j2 := (j + 1) % seg
				var a0: Vector3 = grid[i][j]
				var a1: Vector3 = grid[i][j2]
				var b0: Vector3 = grid[i + 1][j]
				var b1: Vector3 = grid[i + 1][j2]
				if i == 0:
					tri(a0, b1, b0, col, m, g)
				elif i == rings - 1:
					tri(a0, a1, b0, col, m, g)
				else:
					quad(a0, a1, b1, b0, col, m, g)

	# A cone or frustum from c along dir.
	func cone(c: Vector3, dir: Vector3, r0: float, r1: float, col: Color, m: int = 0, g: bool = false, seg: int = 6) -> void:
		var y := dir.normalized()
		var x := y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
		var z := x.cross(y).normalized()
		var top := c + dir
		var lo := []
		var hi := []
		for j in range(seg):
			var a := TAU * float(j) / float(seg)
			var o := x * cos(a) + z * sin(a)
			lo.append(c + o * r0)
			hi.append(top + o * r1)
		for j in range(seg):
			var j2 := (j + 1) % seg
			if r1 <= 0.001:
				tri(lo[j], lo[j2], top, col, m, g)
			else:
				quad(lo[j], lo[j2], hi[j2], hi[j], col, m, g)
				tri(top, hi[j], hi[j2], col, m, g)
			tri(c, lo[j2], lo[j], col, m, g)

	func spike(c: Vector3, dir: Vector3, r: float, col: Color, m: int = 0, g: bool = false) -> void:
		cone(c, dir, r, 0.0, col, m, g, 4)

	func mesh(m: ShaderMaterial) -> ArrayMesh:
		var out := ArrayMesh.new()
		if ns > 0:
			solid.commit(out)
			out.surface_set_material(out.get_surface_count() - 1, m)
		if ng > 0:
			glow.commit(out)
			out.surface_set_material(out.get_surface_count() - 1, MB.glow_material())
		return out


# ------------------------------------------------------------------ building
func build(k: String) -> void:
	kind = k
	for c in get_children():
		remove_child(c)
		c.queue_free()
	parts.clear()
	seg_base.clear()
	mat = MB.hero_material().duplicate()
	mat.set_shader_parameter("tex_scale", 2.6)
	body = Node3D.new()
	body.name = "body"
	add_child(body)
	light = OmniLight3D.new()
	light.light_color = Color(LIGHT.get(k, "#ffffff"))
	light.omni_range = 6.0
	light.light_energy = 1.2
	light.position = Vector3(0, 2.2, 0.8)
	body.add_child(light)
	match k:
		"golem":
			_golem()
		"wyrm":
			_wyrm()
		"spider":
			_spider()
		"wraith":
			_wraith()
		_:
			_drake()
	_shadow()
	atk_wait = randf_range(2.5, 4.5)


func _piv(pname: String, parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = pname
	n.position = pos
	parent.add_child(n)
	parts[pname] = n
	return n


func _put(pivot: Node3D, kit: Kit) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = kit.mesh(mat)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pivot.add_child(mi)
	return mi


func _kit(s: int) -> Kit:
	var k := Kit.new()
	k.seed = s
	return k


func _shadow() -> void:
	var sh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	var w: float = REACH.get(kind, 2.5) * 1.25
	pm.size = Vector2(w, w)
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in range(32):
		for x in range(32):
			var d := Vector2(x - 15.5, y - 15.5).length() / 16.0
			img.set_pixel(x, y, Color(0, 0, 0, clampf(0.55 * (1.0 - d * d), 0.0, 0.55)))
	m.albedo_texture = ImageTexture.create_from_image(img)
	pm.material = m
	sh.mesh = pm
	sh.position = Vector3(0, 0.03, 0)
	sh.name = "shadow"
	add_child(sh)


# --- Rock Golem: a walking pile of boulders with a fire in its chest
func _golem() -> void:
	var stone := Color("#8a857c")
	var dark := Color("#5f5a52")
	var moss := Color("#5a7a3a")
	var ember := Color("#ffb35c")
	for side in [-1, 1]:
		var leg := _piv("leg_" + ("l" if side < 0 else "r"), body, Vector3(side * 0.55, 1.05, 0))
		var kl := _kit(11 + side)
		kl.box(Vector3(0, -0.45, 0), Vector3(0.62, 0.95, 0.66), dark, 3, false, Vector3.ZERO, 0.85)
		kl.box(Vector3(0, -0.95, 0.12), Vector3(0.78, 0.22, 0.92), dark, 3)
		_put(leg, kl)
	var torso := _piv("torso", body, Vector3(0, 1.0, 0))
	var kt := _kit(21)
	kt.blob(Vector3(0, 0.95, 0), Vector3(1.05, 0.9, 0.78), stone, 3, false, 7, 5, 0.14)
	kt.blob(Vector3(0, 0.3, 0.05), Vector3(0.8, 0.45, 0.62), dark, 3, false, 6, 4, 0.12)
	kt.blob(Vector3(0, 1.62, -0.15), Vector3(0.62, 0.16, 0.48), moss, 0, false, 6, 3, 0.2)
	kt.blob(Vector3(-0.55, 1.5, 0.2), Vector3(0.22, 0.08, 0.2), moss, 0)
	for sd in [-1, 1]:
		kt.blob(Vector3(sd * 1.02, 1.38, 0), Vector3(0.48, 0.42, 0.46), stone, 3, false, 6, 4, 0.16)
	# the fire inside, showing through cracks in the chest
	var crack := [Vector3(-0.05, 1.42, 0.7), Vector3(0.1, 1.2, 0.77), Vector3(-0.08, 1.02, 0.79), Vector3(0.12, 0.82, 0.77), Vector3(-0.02, 0.6, 0.72)]
	for i in range(crack.size() - 1):
		kt.limb(crack[i], crack[i + 1], 0.07, 0.05, ember, 0, true)
	kt.limb(Vector3(0.1, 1.2, 0.77), Vector3(0.36, 1.28, 0.7), 0.05, 0.04, ember, 0, true)
	kt.limb(Vector3(-0.08, 1.02, 0.79), Vector3(-0.34, 0.95, 0.72), 0.05, 0.04, ember, 0, true)
	_put(torso, kt)
	var head := _piv("head", torso, Vector3(0, 1.85, 0.32))
	var kh := _kit(31)
	kh.box(Vector3(0, 0.12, 0), Vector3(0.6, 0.48, 0.55), stone, 3, false, Vector3.ZERO, 0.8)
	kh.box(Vector3(0, 0.3, 0.2), Vector3(0.7, 0.14, 0.26), dark, 3)
	kh.box(Vector3(-0.15, 0.15, 0.29), Vector3(0.12, 0.07, 0.04), ember, 0, true)
	kh.box(Vector3(0.15, 0.15, 0.29), Vector3(0.12, 0.07, 0.04), ember, 0, true)
	_put(head, kh)
	for side in [-1, 1]:
		var s := "l" if side < 0 else "r"
		var arm := _piv("arm_" + s, torso, Vector3(side * 1.2, 1.38, 0))
		var ka := _kit(41 + side)
		ka.box(Vector3(side * 0.05, -0.45, 0), Vector3(0.46, 0.92, 0.48), stone, 3, false, Vector3.ZERO, 1.1)
		_put(arm, ka)
		var fore := _piv("fore_" + s, arm, Vector3(side * 0.05, -0.92, 0))
		var kf := _kit(51 + side)
		kf.box(Vector3(0, -0.38, 0), Vector3(0.5, 0.78, 0.5), dark, 3, false, Vector3.ZERO, 1.15)
		kf.blob(Vector3(0, -0.92, 0.04), Vector3(0.42, 0.36, 0.42), stone, 3, false, 6, 4, 0.18)
		_put(fore, kf)
	# granite skin: pale crystal spikes that burst out while it is hardened
	harden = _piv("harden", torso, Vector3.ZERO)
	var kx := _kit(61)
	var ice := Color("#d8e6f0")
	for sp in [[Vector3(-1.0, 1.7, 0), Vector3(-0.3, 0.6, -0.1)], [Vector3(1.0, 1.7, 0), Vector3(0.3, 0.6, -0.1)],
			[Vector3(0, 1.5, -0.6), Vector3(0, 0.5, -0.5)], [Vector3(-0.5, 1.2, -0.65), Vector3(-0.2, 0.3, -0.6)],
			[Vector3(0.5, 1.2, -0.65), Vector3(0.2, 0.3, -0.6)], [Vector3(-1.2, 1.2, 0.2), Vector3(-0.5, 0.2, 0.1)],
			[Vector3(1.2, 1.2, 0.2), Vector3(0.5, 0.2, 0.1)]]:
		kx.spike(sp[0], sp[1], 0.14, ice, 0, true)
	_put(harden, kx)
	harden.visible = false


# --- Cave Wyrm: a huge armoured worm bursting out of a crater
func _wyrm() -> void:
	var hide := Color("#7a6a58")
	var plate := Color("#a8804a")
	var bone := Color("#e8dcc0")
	var dirt := Color("#5e4632")
	var crater := _piv("crater", self, Vector3.ZERO)
	var kc := _kit(5)
	kc.blob(Vector3(0, 0.0, 0), Vector3(1.7, 0.32, 1.7), dirt, 0, false, 9, 4, 0.18)
	for i in range(7):
		var a := TAU * i / 7.0
		kc.blob(Vector3(cos(a) * 1.6, 0.18, sin(a) * 1.6), Vector3(0.32, 0.24, 0.3), Color("#55524c"), 3, false, 5, 3, 0.25)
	kc.blob(Vector3(0, 0.12, 0), Vector3(1.0, 0.12, 1.0), Color("#2a1e14"), 0, false, 8, 2)
	_put(crater, kc)
	var n := 8
	var prev: Node3D = body
	for i in range(n):
		var f := float(i) / float(n - 1)
		var r := lerpf(0.72, 0.46, f)
		# rises out of the crater and arches forward over its prey
		var base := Vector3(sin(f * PI * 1.2) * 0.45, 0.15 + sin(f * PI * 0.55) * 3.3, f * f * 1.7 - 0.4)
		var seg := _piv("seg%d" % i, body, base)
		seg_base.append(base)
		var ks := _kit(100 + i)
		ks.blob(Vector3.ZERO, Vector3(r, r * 0.62, r), hide, 0, false, 8, 4, 0.06)
		ks.blob(Vector3(0, -r * 0.1, r * 0.5), Vector3(r * 0.62, r * 0.36, r * 0.45), plate, 0, false, 6, 3)
		ks.blob(Vector3(0, r * 0.25, -r * 0.1), Vector3(r * 0.9, r * 0.3, r * 0.85), Color("#5e5244"), 0, false, 7, 3)
		ks.spike(Vector3(0, r * 0.45, -r * 0.55), Vector3(0, 0.42, -0.35), 0.13, bone)
		_put(seg, ks)
		prev = seg
	var head := _piv("head", prev, Vector3(0, 0.3, 0.25))
	var kh := _kit(120)
	kh.box(Vector3(0, 0.1, 0.25), Vector3(0.82, 0.5, 0.95), hide, 0, false, Vector3(-8, 0, 0), 0.85)
	kh.box(Vector3(0, 0.38, 0.05), Vector3(0.9, 0.18, 0.7), plate, 0)
	for sd in [-1, 1]:
		kh.spike(Vector3(sd * 0.3, 0.45, -0.15), Vector3(sd * 0.25, 0.5, -0.55), 0.1, bone)
		kh.box(Vector3(sd * 0.25, 0.22, 0.7), Vector3(0.13, 0.09, 0.05), Color("#ff6a4a"), 0, true)
		for tt in range(3):
			kh.spike(Vector3(sd * (0.12 + tt * 0.1), -0.13, 0.62 - tt * 0.12), Vector3(0, -0.18, 0.02), 0.04, bone)
	_put(head, kh)
	var jaw := _piv("jaw", head, Vector3(0, -0.15, 0.0))
	var kj := _kit(121)
	kj.box(Vector3(0, -0.06, 0.38), Vector3(0.7, 0.16, 0.8), plate, 0)
	for sd in [-1, 1]:
		for tt in range(3):
			kj.spike(Vector3(sd * (0.12 + tt * 0.1), 0.02, 0.62 - tt * 0.12), Vector3(0, 0.16, 0.0), 0.04, bone)
	_put(jaw, kj)


# --- Crystal Spider: eight jointed legs and a back full of glowing crystal
func _spider() -> void:
	var shell := Color("#3d3a45")
	var dark := Color("#2a2830")
	var crystal := Color("#7fe3d3")
	var core := _piv("core", body, Vector3(0, 1.15, 0))
	var kc := _kit(201)
	kc.blob(Vector3(0, 0.0, 0.45), Vector3(0.58, 0.42, 0.62), shell, 3, false, 7, 4, 0.08)
	kc.blob(Vector3(0, 0.3, -0.7), Vector3(0.95, 0.78, 1.05), dark, 3, false, 8, 5, 0.1)
	for sp in [[Vector3(0, 0.95, -0.7), Vector3(0, 0.7, -0.1)], [Vector3(-0.45, 0.8, -0.5), Vector3(-0.3, 0.55, 0.0)],
			[Vector3(0.45, 0.8, -0.5), Vector3(0.3, 0.55, 0.0)], [Vector3(-0.35, 0.75, -1.1), Vector3(-0.25, 0.5, -0.3)],
			[Vector3(0.35, 0.75, -1.1), Vector3(0.25, 0.5, -0.3)], [Vector3(0, 0.55, -1.5), Vector3(0, 0.3, -0.5)],
			[Vector3(-0.7, 0.45, -0.8), Vector3(-0.5, 0.35, -0.1)], [Vector3(0.7, 0.45, -0.8), Vector3(0.5, 0.35, -0.1)]]:
		kc.cone(sp[0], sp[1], 0.16, 0.0, crystal, 0, true, 5)
	for e in [[-0.13, 0.12], [0.13, 0.12], [-0.25, 0.05], [0.25, 0.05], [-0.07, 0.22], [0.07, 0.22]]:
		kc.box(Vector3(e[0], e[1], 1.03), Vector3(0.08, 0.08, 0.05), crystal, 0, true)
	_put(core, kc)
	var fangs := _piv("fangs", core, Vector3(0, -0.15, 0.95))
	var kf := _kit(202)
	for sd in [-1, 1]:
		kf.spike(Vector3(sd * 0.14, 0.0, 0.0), Vector3(sd * -0.04, -0.35, 0.12), 0.07, Color("#e8dcc0"))
	_put(fangs, kf)
	for side in [-1, 1]:
		for i in range(4):
			var hip := _piv("leg%d%s" % [i, "l" if side < 0 else "r"], core, Vector3(side * 0.42, 0.0, 0.7 - i * 0.32))
			hip.rotation.y = side * (-0.65 + i * 0.42) * -1.0
			var kl := _kit(210 + i * 2 + (side + 1) / 2)
			var knee := Vector3(side * 1.05, 0.75, 0.0)
			var foot := Vector3(side * 1.75, -1.15, 0.0)
			kl.limb(Vector3.ZERO, knee, 0.16, 0.16, shell, 3)
			kl.limb(knee, foot, 0.13, 0.13, dark, 3, false, 0.5)
			kl.cone(knee + Vector3(0, 0.02, 0), Vector3(0, 0.2, 0), 0.07, 0.0, crystal, 0, true, 4)
			_put(hip, kl)


# --- Void Wraith: a floating hooded cloak with nothing inside but two eyes
func _wraith() -> void:
	var robe := Color("#2e2640")
	var hood := Color("#241d33")
	var bone := Color("#c8c0d8")
	var eye := Color("#d2b0ff")
	var fl := _piv("float", body, Vector3(0, 0.6, 0))
	var kr := _kit(301)
	kr.cone(Vector3(0, 0.0, 0), Vector3(0, 2.0, 0), 0.95, 0.38, robe, 0, false, 9)
	for i in range(9):
		var a := TAU * (i + 0.5) / 9.0
		kr.spike(Vector3(cos(a) * 0.85, 0.12, sin(a) * 0.85), Vector3(cos(a) * 0.25, -0.75 - 0.25 * float(i % 3), sin(a) * 0.25), 0.2, robe)
	kr.box(Vector3(0, 1.2, 0.33), Vector3(0.5, 0.08, 0.05), Color("#6a3fa8"), 0, true)
	_put(fl, kr)
	var head := _piv("head", fl, Vector3(0, 2.15, 0))
	var kh := _kit(302)
	kh.blob(Vector3(0, 0.05, -0.04), Vector3(0.5, 0.56, 0.5), hood, 0, false, 8, 5)
	kh.spike(Vector3(0, 0.45, -0.2), Vector3(0, 0.3, -0.35), 0.18, hood)
	kh.blob(Vector3(0, -0.02, 0.2), Vector3(0.34, 0.38, 0.3), Color("#07060b"), 0, false, 7, 4)
	kh.box(Vector3(-0.13, 0.04, 0.44), Vector3(0.11, 0.06, 0.04), eye, 0, true)
	kh.box(Vector3(0.13, 0.04, 0.44), Vector3(0.11, 0.06, 0.04), eye, 0, true)
	_put(head, kh)
	for side in [-1, 1]:
		var s := "l" if side < 0 else "r"
		var arm := _piv("arm_" + s, fl, Vector3(side * 0.42, 1.85, 0.05))
		var ka := _kit(310 + side)
		ka.cone(Vector3.ZERO, Vector3(side * 0.35, -0.95, 0.35), 0.17, 0.26, robe, 0, false, 6)
		var hand := Vector3(side * 0.38, -1.02, 0.38)
		for f in range(3):
			ka.spike(hand, Vector3(side * (0.05 + f * 0.06), -0.38, 0.12 + f * 0.05), 0.04, bone)
		_put(arm, ka)
	wisps = CPUParticles3D.new()
	wisps.amount = 26
	wisps.lifetime = 1.6
	wisps.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	wisps.emission_sphere_radius = 0.8
	wisps.direction = Vector3(0, 1, 0)
	wisps.spread = 25.0
	wisps.initial_velocity_min = 0.3
	wisps.initial_velocity_max = 0.8
	wisps.gravity = Vector3(0, 0.4, 0)
	wisps.scale_amount_min = 0.5
	wisps.scale_amount_max = 1.2
	wisps.mesh = _cube(0.07, Color("#9a6ae0"))
	wisps.position = Vector3(0, 0.5, 0)
	fl.add_child(wisps)


# --- Ember Drake: horns, wings, a long tail and glowing scales
func _drake() -> void:
	var scale_c := Color("#8a2e1c")
	var dark := Color("#5a1e14")
	var belly := Color("#e0a040")
	var horn := Color("#e8dcc0")
	var fire := Color("#ffb35c")
	var torso := _piv("torso", body, Vector3(0, 1.45, -0.2))
	var kt := _kit(401)
	kt.blob(Vector3(0, 0, 0), Vector3(0.82, 0.72, 1.35), scale_c, 0, false, 8, 5, 0.05)
	kt.blob(Vector3(0, -0.32, 0.15), Vector3(0.6, 0.4, 1.05), belly, 0, false, 7, 4)
	for i in range(5):
		kt.spike(Vector3(0, 0.68, 0.7 - i * 0.38), Vector3(0, 0.36, -0.18), 0.12, horn)
	for e in [Vector3(0.6, 0.15, 0.4), Vector3(-0.6, 0.15, 0.4), Vector3(0.55, -0.1, -0.5), Vector3(-0.55, -0.1, -0.5)]:
		kt.box(e, Vector3(0.05, 0.12, 0.22), fire, 0, true, Vector3(0, 0, 20.0 * signf(e.x)))
	_put(torso, kt)
	var neck := _piv("neck", torso, Vector3(0, 0.35, 1.15))
	var kn := _kit(402)
	kn.blob(Vector3(0, 0.25, 0.15), Vector3(0.42, 0.45, 0.42), scale_c, 0, false, 7, 4)
	kn.blob(Vector3(0, 0.75, 0.35), Vector3(0.36, 0.42, 0.36), scale_c, 0, false, 7, 4)
	kn.blob(Vector3(0, 0.55, 0.45), Vector3(0.26, 0.42, 0.18), belly, 0, false, 6, 3)
	_put(neck, kn)
	var head := _piv("head", neck, Vector3(0, 1.15, 0.5))
	var kh := _kit(403)
	kh.box(Vector3(0, 0.05, 0.2), Vector3(0.62, 0.48, 0.7), scale_c, 0, false, Vector3.ZERO, 0.9)
	kh.box(Vector3(0, -0.02, 0.68), Vector3(0.44, 0.3, 0.55), dark, 0, false, Vector3(6, 0, 0), 0.85)
	for sd in [-1, 1]:
		kh.spike(Vector3(sd * 0.22, 0.25, -0.05), Vector3(sd * 0.18, 0.35, -0.62), 0.09, horn)
		kh.box(Vector3(sd * 0.22, 0.14, 0.52), Vector3(0.12, 0.07, 0.05), Color("#ffe060"), 0, true)
		kh.box(Vector3(sd * 0.1, 0.02, 0.96), Vector3(0.05, 0.05, 0.03), fire, 0, true)
	_put(head, kh)
	var jaw := _piv("jaw", head, Vector3(0, -0.18, 0.25))
	var kj := _kit(404)
	kj.box(Vector3(0, -0.05, 0.4), Vector3(0.4, 0.12, 0.55), belly, 0)
	_put(jaw, kj)
	for side in [-1, 1]:
		var s := "l" if side < 0 else "r"
		for fb in [[0.75, "f"], [-0.75, "b"]]:
			var leg := _piv("leg_%s%s" % [fb[1], s], torso, Vector3(side * 0.6, -0.35, fb[0]))
			var kl := _kit(410 + side + (2 if fb[1] == "b" else 0))
			var knee := Vector3(side * 0.12, -0.55, 0.15 if fb[1] == "f" else -0.2)
			kl.limb(Vector3.ZERO, knee, 0.32, 0.36, scale_c)
			kl.limb(knee, Vector3(side * 0.12, -1.08, 0.2), 0.24, 0.26, dark)
			kl.box(Vector3(side * 0.12, -1.12, 0.36), Vector3(0.34, 0.12, 0.42), dark)
			for cl in [-1, 0, 1]:
				kl.spike(Vector3(side * 0.12 + cl * 0.1, -1.12, 0.58), Vector3(0, -0.04, 0.16), 0.04, horn)
			_put(leg, kl)
		var wing := _piv("wing_" + s, torso, Vector3(side * 0.5, 0.55, 0.25))
		var kw := _kit(420 + side)
		var root := Vector3.ZERO
		var elbow := Vector3(side * 1.3, 0.75, -0.25)
		var tip := Vector3(side * 2.7, 0.35, -0.9)
		var f1 := Vector3(side * 2.0, -0.35, -1.2)
		var f2 := Vector3(side * 1.1, -0.45, -1.15)
		kw.limb(root, elbow, 0.12, 0.12, dark)
		kw.limb(elbow, tip, 0.08, 0.08, dark)
		var mem := Color("#b8452a")
		kw.tri(root, elbow, f2, mem)
		kw.tri(elbow, f1, f2, mem)
		kw.tri(elbow, tip, f1, mem)
		kw.tri(root, f2, Vector3(0, -0.2, -0.9), mem)
		_put(wing, kw)
	var prev: Node3D = torso
	var at := Vector3(0, 0.0, -1.25)
	for i in range(5):
		var tail := _piv("tail%d" % i, prev, at)
		var r := lerpf(0.42, 0.14, float(i) / 4.0)
		var k := _kit(430 + i)
		k.blob(Vector3(0, 0, -0.3), Vector3(r, r * 0.85, 0.42), scale_c, 0, false, 6, 4)
		k.spike(Vector3(0, r * 0.7, -0.3), Vector3(0, 0.22, -0.12), 0.07, horn)
		if i == 4:
			k.cone(Vector3(0, 0, -0.65), Vector3(0, 0, -0.55), 0.22, 0.0, horn, 0, false, 4)
		_put(tail, k)
		prev = tail
		at = Vector3(0, -0.05 if i < 2 else 0.0, -0.6)
	# fire shield: a glowing bubble, shown by the trick
	shield = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 2.7
	sm.height = 4.6
	sm.radial_segments = 14
	sm.rings = 7
	var mm := StandardMaterial3D.new()
	mm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.cull_mode = BaseMaterial3D.CULL_DISABLED
	mm.albedo_color = Color(1.0, 0.55, 0.2, 0.22)
	sm.material = mm
	shield.mesh = sm
	shield.position = Vector3(0, 1.7, 0)
	shield.visible = false
	body.add_child(shield)
	embers = CPUParticles3D.new()
	embers.amount = 30
	embers.lifetime = 1.3
	embers.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	embers.emission_box_extents = Vector3(0.8, 0.5, 1.4)
	embers.direction = Vector3(0, 1, 0)
	embers.spread = 30.0
	embers.initial_velocity_min = 0.6
	embers.initial_velocity_max = 1.6
	embers.gravity = Vector3(0, 0.8, 0)
	embers.mesh = _cube(0.06, Color("#ff9a40"))
	embers.position = Vector3(0, 1.5, -0.2)
	embers.emitting = false
	body.add_child(embers)


func _cube(s: float, c: Color) -> BoxMesh:
	var bm := BoxMesh.new()
	bm.size = Vector3(s, s, s)
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.material = m
	return bm


func _burst(pos: Vector3, color: Color, amount: int, spd: float, size: float, life: float = 0.8, grav: float = -6.0) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.92
	p.amount = amount
	p.lifetime = life
	p.direction = Vector3(0, 1, 0)
	p.spread = 75.0
	p.initial_velocity_min = spd * 0.4
	p.initial_velocity_max = spd
	p.gravity = Vector3(0, grav, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.3
	p.mesh = _cube(size, color)
	p.position = pos
	add_child(p)
	p.emitting = true
	var tw := p.create_tween()
	tw.tween_interval(life + 0.5)
	tw.tween_callback(p.queue_free)


# ------------------------------------------------------------------ what the server says
func set_tricks(tr: Dictionary, hp_frac: float) -> void:
	if dead:
		return
	tricks = tr
	var tint := Vector3.ONE
	speed = 1.0
	if kind == "golem":
		var hard := tr.has("hardened")
		if harden != null:
			if hard and not harden.visible:
				harden.scale = Vector3(0.2, 0.2, 0.2)
				var tw := harden.create_tween()
				tw.tween_property(harden, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
				_burst(Vector3(0, 2.4, 0), Color("#d8e6f0"), 30, 4.0, 0.08)
			harden.visible = hard
		if hard:
			tint = Vector3(0.8, 0.9, 1.15)
			speed = 0.5
	elif kind == "wyrm":
		var down := tr.has("burrowed")
		if down and sink_goal == 0.0:
			_burst(Vector3(0, 0.3, 0), Color("#8a6438"), 40, 5.0, 0.12, 1.0, -9.0)
		elif not down and sink_goal > 0.0:
			_burst(Vector3(0, 0.3, 0), Color("#8a6438"), 50, 6.5, 0.12, 1.1, -9.0)
		sink_goal = 5.0 if down else 0.0
	elif kind == "drake":
		var on := tr.has("shield")
		if shield != null:
			shield.visible = on
		var rage := tr.has("enraged")
		if embers != null:
			embers.emitting = rage
		if rage:
			tint = Vector3(1.3, 0.8, 0.7)
			speed = 1.6
			light.light_color = Color("#ff4a2a")
	elif kind == "spider":
		speed = 1.5
	if hp_frac < 0.25 and kind != "drake":
		speed *= 1.25
	tint_now = tint
	mat.set_shader_parameter("tint", tint)


# mine = this player's own strike (full flash); other fighters only make it flicker.
func hit(quality: String, dmg: int, mine: bool = true) -> void:
	if dead:
		return
	if not mine:
		hit_t = maxf(hit_t, 0.12)
		flash = maxf(flash, 0.12)
		_burst(Vector3(randf_range(-0.6, 0.6), HEIGHT.get(kind, 3.0) * 0.45, 0.4), Color("#d0c8b8"), 4, 2.5, 0.06, 0.4)
		return
	hit_t = 0.3
	flash = 0.6 if dmg > 0 else 0.25
	var at := Vector3(randf_range(-0.4, 0.4), HEIGHT.get(kind, 3.0) * 0.55, 0.6)
	if kind == "wyrm":
		at.y = maxf(0.5, 3.2 - sink)
	if dmg <= 0:
		_burst(at, Color("#d8e6f0") if kind == "golem" else Color("#9a9a9a"), 8, 2.5, 0.06, 0.5)
		return
	var col: Color = {"golem": Color("#8a857c"), "wyrm": Color("#c89a5a"), "spider": Color("#7fe3d3"),
		"wraith": Color("#9a6ae0"), "drake": Color("#ffb35c")}.get(kind, Color.WHITE)
	_burst(at, col, 14 if quality == "perfect" else 8, 4.0, 0.09, 0.6)
	if quality == "perfect":
		_burst(at, Color("#ffd36b"), 10, 5.0, 0.06, 0.5, -3.0)


func heal_fx() -> void:
	_burst(Vector3(0, 2.2, 0), Color("#c9a0ff"), 18, 1.5, 0.08, 1.0, 2.0)
	flash = 0.3


# ------------------------------------------------------------------ comings and goings
func arrive() -> void:
	busy = true
	var tw := create_tween()
	match kind:
		"wyrm":
			sink = 6.0
			sink_goal = 0.0
			_burst(Vector3(0, 0.3, 0), Color("#8a6438"), 60, 7.0, 0.14, 1.2, -9.0)
			tw.tween_interval(1.4)
		"drake", "wraith":
			body.position = Vector3(0, 9.0, -6.0)
			tw.tween_property(body, "position", Vector3.ZERO, 1.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.tween_callback(func(): _burst(Vector3(0, 0.2, 0), Color("#8a8070"), 40, 5.0, 0.1, 0.9, -9.0))
		"spider":
			body.position = Vector3(0, 10.0, 0)
			tw.tween_property(body, "position", Vector3.ZERO, 1.1).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
		_:
			body.position = Vector3(0, -4.2, 0)
			_burst(Vector3(0, 0.2, 0), Color("#77726a"), 60, 6.0, 0.14, 1.2, -9.0)
			tw.tween_property(body, "position", Vector3.ZERO, 1.8).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func(): busy = false)


func die() -> void:
	if dead:
		return
	dead = true
	busy = true
	sink_goal = -1.0
	var top := HEIGHT.get(kind, 3.0) as float
	for i in range(4):
		var tw0 := create_tween()
		tw0.tween_interval(i * 0.22)
		tw0.tween_callback(func(): _burst(Vector3(randf_range(-1, 1), randf_range(0.6, top), randf_range(-0.6, 0.6)),
			Color("#ffd36b") if i % 2 == 0 else Color.WHITE, 24, 5.5, 0.09, 0.9, -4.0))
	var tw := create_tween()
	flash = 1.0
	match kind:
		"wyrm":
			tw.tween_method(func(v: float): sink = v, sink, 6.5, 1.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		"wraith":
			tw.tween_property(body, "scale", Vector3(1.6, 0.05, 1.6), 1.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		"spider":
			tw.tween_property(body, "rotation:z", PI, 0.7).set_trans(Tween.TRANS_BACK)
			tw.parallel().tween_property(body, "position:y", 1.2, 0.35)
			tw.tween_property(body, "position:y", 0.2, 0.35)
			tw.tween_interval(0.8)
			tw.tween_property(body, "scale", Vector3(0.01, 0.01, 0.01), 0.6)
		_:
			tw.tween_property(body, "rotation:x", -PI / 2.0, 1.1).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
			tw.tween_interval(0.9)
			tw.tween_property(body, "scale", Vector3(0.01, 0.01, 0.01), 0.7)
	tw.tween_callback(func():
		_burst(Vector3(0, 0.6, 0), Color("#ffd36b"), 50, 6.0, 0.1, 1.2, -6.0)
		visible = false
		gone.emit())


func flee() -> void:
	if dead:
		return
	dead = true
	busy = true
	sink_goal = -1.0
	var tw := create_tween()
	match kind:
		"wyrm":
			tw.tween_method(func(v: float): sink = v, sink, 6.5, 1.4)
		"drake", "wraith":
			tw.tween_property(body, "position", Vector3(0, 12.0, -10.0), 2.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		_:
			tw.tween_property(body, "position", Vector3(0, 0, -9.0), 2.4)
			tw.parallel().tween_property(body, "scale", Vector3(0.3, 0.3, 0.3), 2.4)
	tw.tween_callback(func():
		visible = false
		gone.emit())


func roar() -> void:
	atk_t = 0.0


# ------------------------------------------------------------------ animation
func _process(delta: float) -> void:
	if body == null:
		return
	t += delta * speed
	hit_t = maxf(0.0, hit_t - delta)
	flash = maxf(0.0, flash - delta * 3.0)
	mat.set_shader_parameter("flash", flash)
	if atk_t >= 0.0:
		atk_t += delta * 0.9 * speed
		if atk_t >= 1.0:
			atk_t = -1.0
			atk_wait = randf_range(2.8, 5.0)
	else:
		atk_wait -= delta
		if atk_wait <= 0.0 and not busy:
			atk_t = 0.0
	if sink_goal >= 0.0:
		sink = move_toward(sink, sink_goal, delta * (7.0 if sink_goal > sink else 4.0))
	var a := atk_t if atk_t >= 0.0 else -1.0
	var swell := sin(clampf(a, 0.0, 1.0) * PI) if a >= 0.0 else 0.0
	var kick := sin(minf(1.0, hit_t / 0.3) * PI) * 0.12
	match kind:
		"golem":
			_anim_golem(swell, kick)
		"wyrm":
			_anim_wyrm(swell, kick)
		"spider":
			_anim_spider(swell, kick)
		"wraith":
			_anim_wraith(swell, kick)
		_:
			_anim_drake(swell, kick)
	light.light_energy = 1.1 + 0.25 * sin(t * 5.0) + flash * 2.0


func _rot(pname: String, v: Vector3) -> void:
	if parts.has(pname):
		parts[pname].rotation = v


func _anim_golem(swell: float, kick: float) -> void:
	var breathe := sin(t * 1.4)
	_rot("torso", Vector3(-kick * 1.5 + swell * 0.25, sin(t * 0.7) * 0.08, sin(t * 0.9) * 0.04))
	parts["torso"].position.y = 1.0 + breathe * 0.04
	_rot("head", Vector3(-swell * 0.3, sin(t * 0.5) * 0.2, 0))
	for s in ["l", "r"]:
		var sd := -1.0 if s == "l" else 1.0
		# both fists lift and slam down on the attack
		_rot("arm_" + s, Vector3(sin(t * 1.4 + sd) * 0.12 - swell * 2.2, 0, sd * (0.08 + swell * 0.25)))
		_rot("fore_" + s, Vector3(-0.15 - swell * 0.6, 0, 0))
		_rot("leg_" + s, Vector3(sin(t * 0.7 + sd) * 0.05, 0, 0))
	if not busy:
		body.position = Vector3(0, 0, -kick * 2.0)


func _anim_wyrm(swell: float, kick: float) -> void:
	var n := seg_base.size()
	for i in range(n):
		var f := float(i) / float(max(1, n - 1))
		var b: Vector3 = seg_base[i]
		var sway := Vector3(sin(t * 1.3 - f * 2.2) * 0.55 * f, sin(t * 2.0 - f * 3.0) * 0.08, sin(t * 0.9 - f * 1.5) * 0.3 * f)
		var lunge := Vector3(0, -swell * 0.5 * f, swell * 1.4 * f * f)
		var p := b + sway + lunge - Vector3(0, sink, -kick * 3.0 * f)
		parts["seg%d" % i].position = p
		parts["seg%d" % i].visible = p.y > -0.55
	_rot("head", Vector3(0.25 + swell * 0.5 - kick * 2.0, sin(t * 0.8) * 0.3, 0))
	_rot("jaw", Vector3(0.15 + swell * 0.7 + 0.08 * sin(t * 3.0), 0, 0))


func _anim_spider(swell: float, kick: float) -> void:
	var core: Node3D = parts["core"]
	core.position.y = 1.15 + sin(t * 4.0) * 0.06 + swell * 0.45
	core.rotation = Vector3(-swell * 0.45 - kick * 2.0, sin(t * 0.6) * 0.25, sin(t * 2.0) * 0.04)
	for side in ["l", "r"]:
		var sd := -1.0 if side == "l" else 1.0
		for i in range(4):
			var ph := t * 6.0 + i * 1.6 + (0.0 if side == "l" else PI)
			var lift := maxf(0.0, sin(ph)) * 0.25
			var leg: Node3D = parts["leg%d%s" % [i, side]]
			var base_yaw := sd * (-0.65 + i * 0.42) * -1.0
			leg.rotation = Vector3(0, base_yaw + cos(ph) * 0.12, sd * lift - (sd * swell * 0.9 if i == 0 else 0.0))
	_rot("fangs", Vector3(0.2 * sin(t * 7.0) + swell * 0.6, 0, 0))
	if not busy:
		body.position = Vector3(sin(t * 0.9) * 0.25, 0, -kick * 2.0)


func _anim_wraith(swell: float, kick: float) -> void:
	var fl: Node3D = parts["float"]
	fl.position = Vector3(0, 0.6 + sin(t * 1.6) * 0.18, -kick * 2.0)
	fl.rotation = Vector3(sin(t * 1.1) * 0.05 - kick, sin(t * 0.4) * 0.25, sin(t * 0.8) * 0.06)
	for s in ["l", "r"]:
		var sd := -1.0 if s == "l" else 1.0
		_rot("arm_" + s, Vector3(sin(t * 1.6 + sd) * 0.2 - swell * 1.4, 0, sd * (0.1 + swell * 0.4)))
	_rot("head", Vector3(sin(t * 0.7) * 0.1 - swell * 0.2, sin(t * 0.5) * 0.3, 0))


func _anim_drake(swell: float, kick: float) -> void:
	var torso: Node3D = parts["torso"]
	torso.position.y = 1.45 + sin(t * 1.5) * 0.06
	torso.rotation = Vector3(-kick * 1.5 - swell * 0.15, sin(t * 0.5) * 0.06, 0)
	_rot("neck", Vector3(-0.15 - swell * 0.35 + sin(t * 1.1) * 0.06, sin(t * 0.6) * 0.2, 0))
	_rot("head", Vector3(0.35 + swell * 0.4, 0, 0))
	_rot("jaw", Vector3(0.1 + swell * 0.6, 0, 0))
	var flap := sin(t * 2.2) * 0.35 + swell * 0.6
	_rot("wing_l", Vector3(0, -0.2, -0.25 + flap))
	_rot("wing_r", Vector3(0, 0.2, 0.25 - flap))
	for i in range(5):
		_rot("tail%d" % i, Vector3(0.05, sin(t * 1.4 - i * 0.6) * 0.22, 0))
	for nm in ["leg_fl", "leg_fr", "leg_bl", "leg_br"]:
		_rot(nm, Vector3(sin(t * 1.5 + nm.length()) * 0.04, 0, 0))
	# fire breath on the attack
	if swell > 0.6 and randf() < 0.5:
		var hp: Vector3 = parts["head"].global_position - global_position
		var fwd := global_transform.basis.z
		_burst(global_transform.basis.inverse() * (hp + fwd * 0.9), Color("#ff9a40") if randf() < 0.6 else Color("#ffe060"), 6, 3.0, 0.1, 0.5, 1.5)
