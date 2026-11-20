extends Node3D
# The 3D world: the town hub, the Deep Veins mine, the underground lake, expedition
# floors and the home cabin, plus the adventurer and a third-person camera.
# Tap a building or vein to walk there; drag to look around.
# v5: textured models, a real sky with day/night from the phone's clock, flickering
# torches, a crystal that pulses with the network, weather, townsfolk, birds, pets,
# and mining effects (chips, sparks, cracks, ore flying to your bag, screen shake).

signal place_tapped(place: String)
signal vein_tapped(tier: int)
signal arrived(place: String)
signal intro_finished

const MD = preload("res://scripts/model_data.gd")
const MB = preload("res://scripts/mesh_builder.gd")
const HeroScript = preload("res://scripts/hero.gd")
const SKY_SHADER = preload("res://shaders/sky.gdshader")
const WATER_SHADER = preload("res://shaders/water.gdshader")
const CLOUDS = preload("res://textures/clouds.png")

const PLACES := {"mine": "town_mine", "forge": "town_forge", "arena": "town_arena", "hall": "town_gambit_hall",
	"tavern": "town_tavern", "board": "town_board", "market": "town_market", "network": "town_network"}
const PLACE_MODELS := {"mine_entrance": "mine", "forge": "forge", "arena": "arena", "gambit_hall": "hall",
	"tavern": "tavern", "notice_board": "board", "stall0": "market", "stall1": "market", "monument": "network"}
const VEIN_MODELS := {1: "vein_coal", 2: "vein_iron", 3: "vein_crystal", 4: "vein_void"}
const ORE_COLORS := {1: Color("#2c2b2a"), 2: Color("#8a5536"), 3: Color("#3fd0bd"), 4: Color("#8a5cd0")}
const CHIP_COLORS := {1: Color("#55524c"), 2: Color("#77726a"), 3: Color("#3a322c"), 4: Color("#2a2420")}

var area := ""
var area_opts := {}
var area_root: Node3D
var hero   # hero.gd instance (left untyped so its own methods can be called)
var camera: Camera3D
var sun: DirectionalLight3D
var env: Environment
var sky_mat: ShaderMaterial
var pickables := []        # [{"pos": Vector3, "kind": "place"/"vein", "id": ...}]
var cam_yaw := 0.0
var cam_dist := 7.4
var cam_height := 5.2
var low_frame := false     # true while a panel covers the bottom of the screen
var walking_tween: Tween = null
const CELL := 0.5          # walk grid resolution (metres)
const HERO_PAD := 0.35     # how close a body may get to a solid object
var astar: AStarGrid2D = null
var grid_half := 15.0
var grid_n := 0
var solids: Array = []
var input_enabled := true
var _press_pos := Vector2.ZERO
var _dragged := false
var _pressed := false

var flickers := []         # [{"l": OmniLight3D, "base": float, "kind": String, "seed": float}]
var monument_light: OmniLight3D = null
var pulse_boost := 0.0
var shake := 0.0
var vein_nodes := {}       # tier -> MeshInstance3D
var vein_cracks := {}      # tier -> [Node3D]
var hidden_fx: CPUParticles3D = null
var combo_fx: CPUParticles3D = null
var npcs := []
var birds := []
var pet: Node3D = null
var pet_kind := ""
var pet_t := 0.0
var weather: CPUParticles3D = null
var season := ""
var night := 0.0
var sky_timer := 0.0
var lantern: OmniLight3D = null
var water: MeshInstance3D = null
var bobber: Node3D = null
var line_mesh: ImmediateMesh = null
var rod: MeshInstance3D = null
var cinematic := false
var trophies_root: Node3D = null
var debug_hour := -1.0     # set >= 0 to force a time of day (screenshots)


func _ready() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.fog_enabled = true
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = SKY_SHADER
	sky_mat.set_shader_parameter("clouds", CLOUDS)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	env.sky = sky
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -38, 0)
	add_child(sun)
	camera = Camera3D.new()
	camera.fov = 55.0
	camera.far = 160.0
	camera.current = true
	add_child(camera)
	area_root = Node3D.new()
	add_child(area_root)
	hero = HeroScript.new()
	add_child(hero)
	var m: int = int(Time.get_datetime_dict_from_system()["month"])
	set_season("winter" if m in [12, 1, 2] else "spring" if m in [3, 4, 5] else "summer" if m in [6, 7, 8] else "fall")


func build_hero(appearance: Dictionary, pick_tier: String) -> void:
	hero.build(appearance, pick_tier)
	rod = null
	if area == "lake":
		_hold_rod(true)


func show_area(area_name: String, opts: Dictionary = {}) -> void:
	if area_name == area and opts == area_opts:
		return
	area = area_name
	area_opts = opts
	for c in area_root.get_children():
		area_root.remove_child(c)
		c.queue_free()
	pickables.clear()
	flickers.clear()
	vein_nodes.clear()
	vein_cracks.clear()
	npcs.clear()
	birds.clear()
	monument_light = null
	hidden_fx = null
	water = null
	bobber = null
	line_mesh = null
	trophies_root = null
	if lantern:
		lantern.queue_free()
		lantern = null
	var town := area_name == "town"
	var layout: Array
	var lights: Array
	match area_name:
		"town":
			layout = MD.TOWN
			lights = MD.TOWN_LIGHTS
			solids = MD.TOWN_SOLIDS
		"cabin":
			layout = MD.CABIN
			lights = MD.CABIN_LIGHTS
			solids = MD.CABIN_SOLIDS
		"lake":
			layout = MD.LAKE
			lights = MD.LAKE_LIGHTS
			solids = MD.LAKE_SOLIDS
		"expedition":
			layout = MD.EXPED
			lights = MD.EXPED_LIGHTS
			solids = MD.EXPED_SOLIDS
		_:
			layout = MD.MINE
			lights = MD.MINE_LIGHTS
			solids = MD.MINE_SOLIDS
	for item in layout:
		var mi := MB.instance(item["m"])
		var p: Array = item["p"]
		mi.position = Vector3(p[0], p[1], p[2])
		mi.rotation_degrees.y = float(item.get("r", 0))
		var s := float(item.get("s", 1.0))
		mi.scale = Vector3(s, s, s)
		area_root.add_child(mi)
		if town and PLACE_MODELS.has(item["m"]):
			pickables.append({"pos": mi.position + Vector3(0, 1.5, 0), "kind": "place", "id": PLACE_MODELS[item["m"]]})
		if item.has("vein"):
			pickables.append({"pos": mi.position + Vector3(0, 1.0, 0), "kind": "vein", "id": int(item["vein"])})
			vein_nodes[int(item["vein"])] = mi
	if area_name == "expedition":
		var tier := clampi(int(opts.get("tier", 1)), 1, 4)
		var v := MB.instance(VEIN_MODELS[tier])
		var ep: Array = MD.EXPED_VEIN
		v.position = Vector3(ep[0], ep[1], ep[2])
		v.rotation_degrees.y = float(opts.get("floor", 1)) * 47.0
		area_root.add_child(v)
		vein_nodes[tier] = v
	var cave := area_name in ["mine", "lake", "expedition"]
	for L in lights:
		var o := OmniLight3D.new()
		var lp: Array = L["p"]
		o.position = Vector3(lp[0], lp[1], lp[2])
		o.light_color = Color(L["c"])
		o.omni_range = float(L["r"]) * (1.4 if cave else 1.0)
		o.light_energy = float(L["e"]) * (2.4 if cave else (1.3 if area_name == "cabin" else 1.0))
		area_root.add_child(o)
		var kind := "fire" if L["c"] in ["#ffb35c", "#ff9a40", "#ffd9a0"] else "crystal"
		flickers.append({"l": o, "base": o.light_energy, "kind": kind, "seed": randf() * 100.0})
		if town and lp[0] == 0 and lp[2] == 0:
			monument_light = o
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_sun_scatter = 0.0
	env.fog_aerial_perspective = 0.0
	env.fog_density = 1.0
	env.fog_light_energy = 1.0
	cam_dist = 7.4
	cam_height = 5.2
	if town:
		env.background_mode = Environment.BG_SKY
		env.fog_depth_begin = 30.0
		env.fog_depth_end = 70.0
		env.fog_depth_curve = 1.4
		_update_sky(true)
		_spawn_townsfolk()
		_spawn_birds()
		MB.set_snow(0.75 if season == "winter" else 0.0)
	else:
		env.background_mode = Environment.BG_COLOR
		MB.set_snow(0.0)
		sun.light_energy = 0.0 if area_name == "cabin" else 0.35
		sun.light_color = Color("#d8c8b0")
		if area_name == "cabin":
			env.background_color = Color("#1a120c")
			env.ambient_light_color = Color("#b8987a")
			env.ambient_light_energy = 0.8
			env.fog_light_color = Color("#1a120c")
			env.fog_depth_begin = 14.0
			env.fog_depth_end = 30.0
			env.fog_depth_curve = 1.0
			cam_dist = 3.0
			cam_height = 3.1
		else:
			var deep := float(opts.get("floor", 0))
			env.background_color = Color("#0c0a09") if area_name == "expedition" else Color("#120e0b")
			env.ambient_light_color = Color("#8f8270").darkened(clampf(deep * 0.03, 0.0, 0.45))
			env.ambient_light_energy = 0.7
			env.fog_light_color = env.background_color
			env.fog_depth_begin = maxf(3.0, 8.0 - deep * 0.3)
			env.fog_depth_end = maxf(11.0, 22.0 - deep * 0.6)
			env.fog_depth_curve = 1.2
	if area_name == "lake":
		_build_water()
	if area_name == "expedition":
		lantern = OmniLight3D.new()
		lantern.light_color = Color("#ffcf8a")
		lantern.omni_range = 7.0
		lantern.light_energy = 1.6
		lantern.position = Vector3(0.3, 1.6, 0.2)
		hero.add_child(lantern)
	_set_weather_visible(town)
	_build_grid({"town": 14.5, "cabin": 3.9}.get(area_name, 8.5))
	var spawn_key: String = {"town": "town_spawn", "cabin": "cabin_spawn", "lake": "lake_spawn", "expedition": "exped_spawn"}.get(area_name, "mine_spawn")
	_place_hero(MD.SPOTS[spawn_key])
	_hold_rod(area_name == "lake")
	if pet != null:
		pet.position = hero.position + Vector3(0.8, 0, 0.8)


func _vec(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func _place_hero(spot: Dictionary) -> void:
	if walking_tween:
		walking_tween.kill()
	hero.position = _vec(spot["p"])
	_face(_vec(spot["look"]))
	cam_yaw = hero.rotation.y
	_snap_camera()


func _face(target: Vector3, who: Node3D = null) -> void:
	var body: Node3D = hero if who == null else who
	var t := Vector3(target.x, body.position.y, target.z)
	if t.distance_to(body.position) > 0.05:
		body.look_at(t, Vector3.UP)


func spot_for_place(place: String) -> Dictionary:
	if place == "town":
		return MD.SPOTS["town_spawn"]
	return MD.SPOTS.get(PLACES.get(place, ""), MD.SPOTS["town_spawn"])


func spot_for_vein(tier: int) -> Dictionary:
	if area == "expedition":
		return MD.SPOTS["exped_vein"]
	return MD.SPOTS["vein%d" % tier]


func spot(name: String) -> Dictionary:
	return MD.SPOTS.get(name, MD.SPOTS["town_spawn"])


# ------------------------------------------------------------------ sky, day and night
func _update_sky(force: bool = false) -> void:
	if area != "town":
		return
	var d := Time.get_datetime_dict_from_system()
	var h := float(d["hour"]) + float(d["minute"]) / 60.0
	if debug_hour >= 0.0:
		h = debug_hour
	var elev := sin((h - 6.0) / 24.0 * TAU)            # -1 midnight, 0 at 6:00 and 18:00, 1 at noon
	var day := clampf(elev * 2.5 + 0.35, 0.0, 1.0)
	night = 1.0 - clampf(elev * 4.0 + 0.6, 0.0, 1.0)
	var dusk := clampf(1.0 - absf(elev) * 4.0, 0.0, 1.0)
	var zen := Color("#0b1022").lerp(Color("#5b86b8"), day)
	var hor := Color("#1a2236").lerp(Color("#a9bccb"), day).lerp(Color("#e0956a"), dusk * 0.55)
	sky_mat.set_shader_parameter("zenith", zen)
	sky_mat.set_shader_parameter("horizon", hor)
	sky_mat.set_shader_parameter("ground", hor.darkened(0.45))
	sky_mat.set_shader_parameter("night", night)
	sky_mat.set_shader_parameter("cloud_col", Color("#3a4258").lerp(Color("#fff8ee"), day).lerp(Color("#f0b090"), dusk * 0.5))
	sky_mat.set_shader_parameter("cloud_cover", 0.9 if season == "winter" else 0.72)
	var az := (h / 24.0) * TAU
	var sun_dir := Vector3(sin(az) * 0.8, maxf(elev, -0.2), -cos(az) * 0.6).normalized()
	sky_mat.set_shader_parameter("sun_dir", sun_dir)
	sun.look_at_from_position(sun_dir * 10.0, Vector3.ZERO, Vector3.UP if absf(sun_dir.y) < 0.95 else Vector3.FORWARD)
	sun.light_energy = clampf(elev * 2.0 + 0.15, 0.0, 1.3)
	sun.light_color = Color("#ffb070").lerp(Color("#fff0d6"), clampf(elev * 3.0, 0.0, 1.0))
	env.ambient_light_color = Color("#5a6a90").lerp(Color("#c4c2b4"), day)
	env.ambient_light_energy = lerpf(0.45, 0.95, day)
	env.fog_light_color = hor
	for f in flickers:
		if f["kind"] == "fire":
			f["base_now"] = float(f["base"]) * (1.0 + night * 0.9)


# ------------------------------------------------------------------ weather
func set_season(s: String) -> void:
	season = s
	if weather:
		weather.queue_free()
		weather = null
	if s == "winter" or s == "fall" or s == "spring":
		weather = CPUParticles3D.new()
		weather.amount = 180 if s == "winter" else 40
		weather.lifetime = 6.0
		weather.preprocess = 6.0
		weather.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		weather.emission_box_extents = Vector3(14, 0.5, 14)
		weather.direction = Vector3(0.2, -1, 0.1)
		weather.spread = 15.0
		weather.gravity = Vector3(0, -1.2 if s == "winter" else -0.8, 0)
		weather.initial_velocity_min = 0.4
		weather.initial_velocity_max = 1.0
		var qm := QuadMesh.new()
		qm.size = Vector2(0.08, 0.08) if s == "winter" else Vector2(0.14, 0.1)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.albedo_color = {"winter": Color("#f4f8ff"), "fall": Color("#c8682a"), "spring": Color("#f0b8c8")}[s]
		qm.material = mat
		weather.mesh = qm
		weather.angular_velocity_min = -90.0
		weather.angular_velocity_max = 90.0
		add_child(weather)
	if area != "":
		_set_weather_visible(area == "town")
		if area == "town":
			MB.set_snow(0.75 if s == "winter" else 0.0)
			_update_sky(true)


func _set_weather_visible(on: bool) -> void:
	if weather:
		weather.visible = on
		weather.emitting = on


# ------------------------------------------------------------------ network pulse
# Called by the app every time this phone's heartbeat is accepted by the network.
func network_pulse() -> void:
	pulse_boost = 1.0


# ------------------------------------------------------------------ townsfolk + birds
func _spawn_townsfolk() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2007
	for i in range(5):
		var n = HeroScript.new()
		area_root.add_child(n)
		n.build(HeroScript.random_look(rng), "starter")
		var w: Array = MD.WANDER[i * 2 % MD.WANDER.size()]
		n.position = Vector3(w[0], 0, w[2])
		n.scale = Vector3.ONE * rng.randf_range(0.92, 1.05)
		npcs.append({"n": n, "wait": rng.randf_range(0.5, 4.0), "busy": false})


func _npc_step(npc: Dictionary, delta: float) -> void:
	if npc["busy"]:
		return
	npc["wait"] = float(npc["wait"]) - delta
	if npc["wait"] > 0.0:
		return
	npc["busy"] = true
	var n: Node3D = npc["n"]
	var w: Array = MD.WANDER[randi() % MD.WANDER.size()]
	var pts := _path_between(Vector2(n.position.x, n.position.z), Vector2(w[0], w[2]))
	if pts.is_empty():
		npc["busy"] = false
		npc["wait"] = 2.0
		return
	n.set_walking(true)
	var tw := n.create_tween()
	var prev: Vector3 = n.position
	for q in pts:
		var p3 := Vector3(q.x, 0, q.y)
		var d: float = prev.distance_to(p3)
		if d < 0.05:
			continue
		tw.tween_callback(_face.bind(p3, n))
		tw.tween_property(n, "position", p3, d / 1.6)
		prev = p3
	tw.tween_callback(func():
		if is_instance_valid(n):
			n.set_walking(false)
			if randf() < 0.3:
				n.emote(["wave", "laugh", "flex"][randi() % 3])
		npc["busy"] = false
		npc["wait"] = randf_range(2.0, 7.0))


func _spawn_birds() -> void:
	for i in range(4):
		var b := MB.instance("bird")
		area_root.add_child(b)
		birds.append({"n": b, "r": randf_range(9.0, 18.0), "h": randf_range(10.0, 14.0), "a": randf() * TAU,
			"s": randf_range(0.25, 0.45) * (1 if i % 2 == 0 else -1), "c": Vector3(randf_range(-6, 6), 0, randf_range(-6, 6))})


# ------------------------------------------------------------------ pets
func set_pet(kind: String) -> void:
	if pet != null:
		pet.queue_free()
		pet = null
	pet_kind = kind
	if kind == "":
		return
	pet = Node3D.new()
	add_child(pet)
	pet.add_child(MB.instance("pet_" + kind))
	if kind == "bat":
		for side in [-1, 1]:
			var w := MB.instance("pet_bat_wing")
			w.name = "wing_l" if side < 0 else "wing_r"
			w.scale = Vector3(side, 1, 1)
			w.position = Vector3(0.06 * side, 0.04, 0)
			pet.add_child(w)
	if kind == "sprite":
		var l := OmniLight3D.new()
		l.light_color = Color("#5fe0cf")
		l.omni_range = 2.0
		l.light_energy = 0.7
		pet.add_child(l)
	pet.position = hero.position + Vector3(0.8, 0, 0.8)


func _pet_step(delta: float) -> void:
	if pet == null or hero == null:
		return
	pet_t += delta
	var side: Vector3 = hero.global_transform.basis.x
	var back: Vector3 = hero.global_transform.basis.z
	var goal: Vector3 = hero.position + side * 0.7 + back * 0.6
	var fly := pet_kind != "golem"
	goal.y = (1.1 + sin(pet_t * 2.2) * 0.15) if fly else 0.0
	var d := pet.position.distance_to(goal)
	if d > 0.15:
		pet.position = pet.position.lerp(goal, clampf(delta * (2.0 + d), 0.0, 1.0))
		var flat := Vector3(goal.x, pet.position.y, goal.z)
		if flat.distance_to(pet.position) > 0.2:
			pet.look_at(flat, Vector3.UP)
	if pet_kind == "golem":
		pet.rotation.z = sin(pet_t * 9.0) * 0.08 * clampf(d * 2.0, 0.0, 1.0)
	elif pet_kind == "bat":
		var f := sin(pet_t * 18.0) * 0.8
		var wl = pet.get_node_or_null("wing_l")
		var wr = pet.get_node_or_null("wing_r")
		if wl:
			wl.rotation.z = f
			wr.rotation.z = -f
	elif pet_kind == "sprite":
		pet.rotation.y += delta * 2.0


# ------------------------------------------------------------------ mining effects
func _burst(pos: Vector3, color: Color, amount: int, speed: float, size: float, glow: bool, life: float = 0.7) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = amount
	p.lifetime = life
	p.direction = Vector3(0, 1, 0)
	p.spread = 70.0
	p.initial_velocity_min = speed * 0.5
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -9.0, 0) if not glow else Vector3(0, -3.0, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var bm := BoxMesh.new()
	bm.size = Vector3(size, size, size)
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	if glow:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.material = m
	p.mesh = bm
	p.position = pos
	area_root.add_child(p)
	p.emitting = true
	var tw := p.create_tween()
	tw.tween_interval(life + 0.4)
	tw.tween_callback(p.queue_free)


func _vein_point(tier: int) -> Vector3:
	var v = vein_nodes.get(tier)
	if v == null:
		return hero.position + (-hero.global_transform.basis.z) * 1.4 + Vector3(0, 0.9, 0)
	return (v as Node3D).position + Vector3(0, 0.9, 0) + (hero.position - (v as Node3D).position).normalized() * 0.8


# quality: "perfect" / "great" / "good" / "miss"
func hit_fx(tier: int, quality: String) -> void:
	var at := _vein_point(tier)
	if quality == "miss":
		_burst(at, CHIP_COLORS.get(tier, Color("#55524c")), 4, 2.0, 0.05, false)
		shake = maxf(shake, 0.02)
		return
	var big := quality == "perfect"
	_burst(at, CHIP_COLORS.get(tier, Color("#55524c")), 18 if big else 10, 4.5 if big else 3.2, 0.09, false)
	_burst(at, Color("#ffd36b"), 16 if big else 6, 5.5 if big else 3.5, 0.035, true, 0.45)
	if tier >= 3:
		_burst(at, ORE_COLORS[tier], 10 if big else 5, 3.0, 0.06, true, 0.8)
	shake = maxf(shake, {"perfect": 0.16, "great": 0.09, "good": 0.05}.get(quality, 0.03))
	if big:
		var fl := OmniLight3D.new()
		fl.light_color = Color("#ffe0a0")
		fl.omni_range = 4.0
		fl.light_energy = 3.0
		fl.position = at
		area_root.add_child(fl)
		var tw := fl.create_tween()
		tw.tween_property(fl, "light_energy", 0.0, 0.25)
		tw.tween_callback(fl.queue_free)
	var v = vein_nodes.get(tier)
	if v != null:
		var tw2 := create_tween()
		var base: Vector3 = (v as Node3D).position
		tw2.tween_property(v, "position", base + Vector3(randf_range(-0.05, 0.05), 0, randf_range(-0.05, 0.05)), 0.04)
		tw2.tween_property(v, "position", base, 0.06)


# Health left as a fraction: the vein shrinks a little and cracks pile up at its base.
func vein_damage(tier: int, frac: float) -> void:
	var v = vein_nodes.get(tier)
	if v == null:
		return
	var s := lerpf(0.86, 1.0, clampf(frac, 0.0, 1.0))
	(v as Node3D).scale = Vector3(s, s, s)
	var want := int((1.0 - clampf(frac, 0.0, 1.0)) * 5.0)
	var have: Array = vein_cracks.get(tier, [])
	while have.size() < want:
		var r := MB.instance("rock%d" % (have.size() % 3))
		var a := randf() * TAU
		r.position = (v as Node3D).position + Vector3(cos(a) * 1.15, -0.1, sin(a) * 1.15)
		r.scale = Vector3.ONE * randf_range(0.18, 0.3)
		area_root.add_child(r)
		have.append(r)
	vein_cracks[tier] = have


func vein_cleared(tier: int) -> void:
	var at := _vein_point(tier)
	_burst(at, CHIP_COLORS.get(tier, Color("#55524c")), 30, 6.0, 0.12, false, 1.0)
	_burst(at, ORE_COLORS.get(tier, Color.WHITE), 20, 5.0, 0.07, true, 1.0)
	shake = 0.25
	for r in vein_cracks.get(tier, []):
		if is_instance_valid(r):
			r.queue_free()
	vein_cracks[tier] = []
	var v = vein_nodes.get(tier)
	if v != null:
		(v as Node3D).scale = Vector3(0.3, 0.3, 0.3)
		var tw := create_tween()
		tw.tween_property(v, "scale", Vector3.ONE, 0.6).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	hero.cheer()


# Small chunks of ore fly from the vein up to the top of the screen (the ore counter).
func ore_fly(tier: int, count: int) -> void:
	var at := _vein_point(tier)
	for i in range(clampi(count, 1, 8)):
		var bm := BoxMesh.new()
		bm.size = Vector3(0.12, 0.12, 0.12)
		var m := StandardMaterial3D.new()
		m.albedo_color = ORE_COLORS.get(tier, Color.WHITE)
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bm.material = m
		var mi := MeshInstance3D.new()
		mi.mesh = bm
		mi.position = at
		area_root.add_child(mi)
		var target := camera.project_position(Vector2(120 + i * 18, 150), 2.5)
		mi.set_meta("t", target)
		var mid := at.lerp(target, 0.5) + Vector3(randf_range(-0.6, 0.6), 1.2, randf_range(-0.6, 0.6))
		var tw := mi.create_tween()
		tw.tween_interval(i * 0.05)
		tw.tween_property(mi, "position", mid, 0.25).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(mi, "rotation", Vector3(3, 2, 1), 0.5)
		tw.tween_property(mi, "position", target, 0.3).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(mi, "scale", Vector3(0.3, 0.3, 0.3), 0.3)
		tw.tween_callback(mi.queue_free)


func set_hidden_vein(tier: int) -> void:
	if hidden_fx:
		hidden_fx.queue_free()
		hidden_fx = null
	var v = vein_nodes.get(tier)
	if tier <= 0 or v == null:
		return
	hidden_fx = CPUParticles3D.new()
	hidden_fx.amount = 24
	hidden_fx.lifetime = 1.4
	hidden_fx.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	hidden_fx.emission_sphere_radius = 1.2
	hidden_fx.gravity = Vector3(0, 0.6, 0)
	var qm := QuadMesh.new()
	qm.size = Vector2(0.07, 0.07)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.albedo_color = Color("#ffe27a")
	qm.material = m
	hidden_fx.mesh = qm
	hidden_fx.position = (v as Node3D).position + Vector3(0, 1.0, 0)
	area_root.add_child(hidden_fx)


# Streak flame on the pickaxe: 0 = off, grows with the combo.
func set_combo(level: int) -> void:
	if combo_fx and is_instance_valid(combo_fx):
		combo_fx.queue_free()
	combo_fx = null
	if level <= 0 or not hero.parts.has("pickaxe"):
		return
	combo_fx = CPUParticles3D.new()
	combo_fx.amount = 8 + level * 6
	combo_fx.lifetime = 0.5
	combo_fx.direction = Vector3(0, 1, 0)
	combo_fx.spread = 20.0
	combo_fx.gravity = Vector3(0, 2.5, 0)
	combo_fx.initial_velocity_min = 0.2
	combo_fx.initial_velocity_max = 0.6
	combo_fx.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	combo_fx.emission_sphere_radius = 0.08
	var qm := QuadMesh.new()
	qm.size = Vector2(0.06 + level * 0.015, 0.06 + level * 0.015)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.albedo_color = Color("#ff8a2a") if level < 4 else Color("#7fe3d3")
	qm.material = m
	combo_fx.mesh = qm
	combo_fx.position = Vector3(0, 0.78, 0)
	hero.parts["pickaxe"].add_child(combo_fx)


# Payday: a shower of coins around the hero.
func coin_shower() -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.4
	p.amount = 40
	p.lifetime = 1.6
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 1.2
	p.gravity = Vector3(0, -6.0, 0)
	p.initial_velocity_min = 0.5
	p.initial_velocity_max = 1.5
	p.angular_velocity_min = -360.0
	p.angular_velocity_max = 360.0
	var cm := CylinderMesh.new()
	cm.top_radius = 0.07
	cm.bottom_radius = 0.07
	cm.height = 0.02
	cm.radial_segments = 8
	var m := StandardMaterial3D.new()
	m.albedo_color = Color("#e8b04a")
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.material = m
	p.mesh = cm
	p.position = hero.position + Vector3(0, 3.0, 0)
	add_child(p)
	p.emitting = true
	pulse_boost = 1.0
	var tw := p.create_tween()
	tw.tween_interval(2.2)
	tw.tween_callback(p.queue_free)


func set_lantern(frac: float) -> void:
	if lantern:
		lantern.light_energy = lerpf(0.35, 1.6, clampf(frac, 0.0, 1.0))
		lantern.omni_range = lerpf(3.0, 7.0, clampf(frac, 0.0, 1.0))


# ------------------------------------------------------------------ fishing
func _build_water() -> void:
	water = MeshInstance3D.new()
	var pm := PlaneMesh.new()
	var r: float = MD.LAKE_WATER["radius"]
	pm.size = Vector2(r * 2.2, r * 2.2)
	pm.subdivide_width = 12
	pm.subdivide_depth = 12
	var m := ShaderMaterial.new()
	m.shader = WATER_SHADER
	pm.material = m
	water.mesh = pm
	var c: Array = MD.LAKE_WATER["center"]
	water.position = Vector3(c[0], 0.06, c[1])
	area_root.add_child(water)


func _hold_rod(on: bool) -> void:
	if not hero.parts.has("pickaxe"):
		return
	hero.parts["pickaxe"].visible = not on
	if on and rod == null:
		rod = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.008
		cm.bottom_radius = 0.02
		cm.height = 1.6
		var m := StandardMaterial3D.new()
		m.albedo_color = Color("#6b4a2b")
		cm.material = m
		rod.mesh = cm
		rod.position = Vector3(0, -0.3, -0.55)
		rod.rotation.x = -1.2
		hero.parts["forearm_r" if hero.parts.has("forearm_r") else "arm_r"].add_child(rod)
	if rod:
		rod.visible = on


func _rod_tip() -> Vector3:
	if rod == null:
		return hero.position + Vector3(0, 1.5, 0)
	return rod.global_transform * Vector3(0, 0.8, 0)


func cast_line() -> void:
	if bobber:
		bobber.queue_free()
	bobber = Node3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.06
	sm.height = 0.12
	var m := StandardMaterial3D.new()
	m.albedo_color = Color("#d83a2a")
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	bobber.add_child(mi)
	area_root.add_child(bobber)
	var lm := MeshInstance3D.new()
	line_mesh = ImmediateMesh.new()
	lm.mesh = line_mesh
	var lmat := StandardMaterial3D.new()
	lmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lmat.albedo_color = Color("#e8e0d0")
	lm.material_override = lmat
	area_root.add_child(lm)
	bobber.position = _rod_tip()
	var land := Vector3(randf_range(-0.6, 0.6), 0.1, -2.6 - randf() * 1.2)
	var tw := create_tween()
	tw.tween_property(hero.parts["arm_r"], "rotation:x", deg_to_rad(150), 0.15)
	tw.tween_property(hero.parts["arm_r"], "rotation:x", deg_to_rad(40), 0.12)
	tw.parallel().tween_property(bobber, "position", (bobber.position + land) * 0.5 + Vector3(0, 1.4, 0), 0.25)
	tw.tween_property(bobber, "position", land, 0.3).set_ease(Tween.EASE_IN)


func bobber_bite() -> void:
	if bobber == null:
		return
	var y := bobber.position.y
	var tw := create_tween()
	for i in range(3):
		tw.tween_property(bobber, "position:y", y - 0.12, 0.08)
		tw.tween_property(bobber, "position:y", y, 0.1)
	_burst(bobber.position, Color("#9ff3e6"), 8, 1.6, 0.04, true, 0.5)


func reel(caught: bool) -> void:
	if bobber == null:
		return
	if caught:
		var f := MB.instance("trophy_fish")
		f.position = bobber.position
		area_root.add_child(f)
		var tw := f.create_tween()
		tw.tween_property(f, "position", hero.position + Vector3(0, 2.2, 0), 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_property(f, "rotation:y", TAU * 2, 0.5)
		tw.tween_interval(0.6)
		tw.tween_callback(f.queue_free)
		_burst(bobber.position, Color("#9ff3e6"), 14, 3.0, 0.05, true, 0.6)
	var tw2 := create_tween()
	tw2.tween_property(bobber, "position", _rod_tip(), 0.35)
	tw2.tween_callback(func():
		if bobber:
			bobber.queue_free()
			bobber = null
		if line_mesh:
			line_mesh.clear_surfaces())
	tw2.tween_property(hero.parts["arm_r"], "rotation:x", deg_to_rad(8), 0.2)


# ------------------------------------------------------------------ cabin trophies
func set_trophies(shelves: Array) -> void:
	if trophies_root:
		trophies_root.queue_free()
	trophies_root = Node3D.new()
	area_root.add_child(trophies_root)
	for i in range(mini(shelves.size(), MD.SHELF_SLOTS.size())):
		var t = shelves[i]
		if t == null or typeof(t) != TYPE_DICTIONARY:
			continue
		var id := str(t.get("id", ""))
		var model := "trophy_badge"
		if id.begins_with("fish:"):
			model = "trophy_fish"
		elif id.begins_with("gem:"):
			var g := id.substr(4)
			model = "trophy_gem_" + ("void" if g == "voidstone" else g)
		elif id.begins_with("pet:"):
			model = "pet_" + id.substr(4)
		var mi := MB.instance(model)
		var s: Array = MD.SHELF_SLOTS[i]
		mi.position = Vector3(s[0], s[1], s[2])
		trophies_root.add_child(mi)


# ------------------------------------------------------------------ intro fly-through
func play_intro() -> void:
	cinematic = true
	input_enabled = false
	var pts := [Vector3(0, 30, 40), Vector3(26, 18, 10), Vector3(14, 9, -20), Vector3(-8, 6, -16), Vector3(0, 5.2, 13.9)]
	var looks := [Vector3(0, 0, 0), Vector3(0, 2, 0), Vector3(0, 1, -10), Vector3(0, 1.5, -13), Vector3(0, 1, 6.5)]
	camera.position = pts[0]
	camera.look_at(looks[0], Vector3.UP)
	var tw := create_tween()
	for i in range(1, pts.size()):
		var a: Vector3 = looks[i - 1]
		var b: Vector3 = looks[i]
		var from: Vector3 = pts[i - 1]
		var to: Vector3 = pts[i]
		tw.tween_method(func(t: float):
			camera.position = from.lerp(to, t)
			camera.look_at(a.lerp(b, t), Vector3.UP), 0.0, 1.0, 2.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	cinematic = false
	input_enabled = true
	intro_finished.emit()


# ------------------------------------------------------------------ solid objects + paths
func _blocked(p: Vector2, pad: float = HERO_PAD) -> bool:
	for s in solids:
		var d := p - Vector2(float(s[0]), float(s[1]))
		if s.size() == 3:
			if d.length() < float(s[2]) + pad:
				return true
		else:
			var r := float(s[4])
			var lx := d.x * cos(r) - d.y * sin(r)
			var lz := d.x * sin(r) + d.y * cos(r)
			if absf(lx) < float(s[2]) + pad and absf(lz) < float(s[3]) + pad:
				return true
	return false


func _build_grid(limit: float) -> void:
	grid_half = limit + 1.0
	grid_n = int(ceil(grid_half * 2.0 / CELL)) + 1
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, grid_n, grid_n)
	astar.cell_size = Vector2(CELL, CELL)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()
	var square := area == "cabin"
	for i in range(grid_n):
		for k in range(grid_n):
			var p := _cell_pos(Vector2i(i, k))
			var out := (absf(p.x) > limit or absf(p.y) > limit) if square else p.length() > limit
			if out or _blocked(p):
				astar.set_point_solid(Vector2i(i, k), true)


func _cell_pos(c: Vector2i) -> Vector2:
	return Vector2(-grid_half + c.x * CELL, -grid_half + c.y * CELL)


func _cell_of(p: Vector2) -> Vector2i:
	var c := Vector2i(roundi((p.x + grid_half) / CELL), roundi((p.y + grid_half) / CELL))
	return Vector2i(clampi(c.x, 0, grid_n - 1), clampi(c.y, 0, grid_n - 1))


# Nearest walkable cell (searching outward in rings).
func _free_cell(c: Vector2i) -> Vector2i:
	if not astar.is_point_solid(c):
		return c
	for r in range(1, 24):
		var best := Vector2i(-1, -1)
		var best_d := 1e9
		for i in range(-r, r + 1):
			for k in range(-r, r + 1):
				if maxi(absi(i), absi(k)) != r:
					continue
				var q := c + Vector2i(i, k)
				if q.x < 0 or q.y < 0 or q.x >= grid_n or q.y >= grid_n or astar.is_point_solid(q):
					continue
				var d := Vector2(i, k).length()
				if d < best_d:
					best_d = d
					best = q
		if best.x >= 0:
			return best
	return c


func _clear_line(a: Vector2, b: Vector2) -> bool:
	var steps := int(ceil(a.distance_to(b) / 0.2))
	for i in range(1, steps + 1):
		var p := a.lerp(b, float(i) / float(steps))
		if p.length() > grid_half - 1.0 or _blocked(p, HERO_PAD * 0.9):
			return false
	return true


# Waypoints (x/z) from start to target, going around anything solid.
func _path_between(start: Vector2, target: Vector2) -> Array:
	var goal := target
	var goal_cell := _free_cell(_cell_of(goal))
	if _blocked(goal) or goal.length() > grid_half - 1.0:
		goal = _cell_pos(goal_cell)
	if _clear_line(start, goal):
		return [goal]
	var ids: Array = astar.get_id_path(_free_cell(_cell_of(start)), goal_cell)
	if ids.is_empty():
		return [goal] if not _blocked(goal) else []
	var pts: Array = []
	for c in ids:
		pts.append(_cell_pos(c))
	pts.append(goal)
	var out: Array = []
	var cur := start
	var i := 0
	while i < pts.size():
		var j := pts.size() - 1
		while j > i and not _clear_line(cur, pts[j]):
			j -= 1
		out.append(pts[j])
		cur = pts[j]
		i = j + 1
	return out


func _path_to(target: Vector2) -> Array:
	return _path_between(Vector2(hero.position.x, hero.position.z), target)


func _walk_path(points: Array) -> void:
	if walking_tween:
		walking_tween.kill()
	if points.is_empty():
		return
	hero.set_walking(true)
	walking_tween = create_tween()
	var prev: Vector3 = hero.position
	for q in points:
		var p3 := Vector3(q.x, 0, q.y)
		var d: float = prev.distance_to(p3)
		if d < 0.05:
			continue
		walking_tween.tween_callback(_face.bind(p3, null))
		walking_tween.tween_property(hero, "position", p3, clampf(d / 4.2, 0.08, 4.0))
		prev = p3
	walking_tween.tween_interval(0.01)
	await walking_tween.finished
	hero.set_walking(false)


# Walk to a spot, then face what it looks at. Emits arrived(tag) at the end.
func walk_to(spot_d: Dictionary, tag: String = "") -> void:
	var target := _vec(spot_d["p"])
	if hero.position.distance_to(target) > 0.1:
		await _walk_path(_path_to(Vector2(target.x, target.z)))
	_face(_vec(spot_d["look"]))
	cam_yaw = hero.rotation.y
	arrived.emit(tag)


func walk_to_point(p: Vector3) -> void:
	var lim: float = {"town": 14.0, "cabin": 3.8}.get(area, 8.0)
	var flat := Vector2(p.x, p.z)
	if flat.length() > lim:
		flat = flat.normalized() * lim
	await _walk_path(_path_to(flat))


func _cam_target() -> Vector3:
	var c := _cam_raw()
	if area == "cabin":
		c = Vector3(clampf(c.x, -4.2, 4.2), minf(c.y, 3.3), clampf(c.z, -4.2, 4.2))
	return c


func _cam_raw() -> Vector3:
	var back := Vector3(sin(cam_yaw), 0, cos(cam_yaw))
	if low_frame:
		var y := cam_yaw + 0.8
		var side := Vector3(sin(y), 0, cos(y))
		return hero.position + side * (5.4 if area != "cabin" else 4.0) + Vector3(0, 4.0 if area != "cabin" else 2.8, 0)
	return hero.position + back * cam_dist + Vector3(0, cam_height, 0)


func _look_point() -> Vector3:
	var fwd := Vector3(-sin(cam_yaw), 0, -cos(cam_yaw))
	if low_frame:
		return hero.position + fwd * 1.1 + Vector3(0, -1.5, 0)
	return hero.position + Vector3(0, 1.0, 0)


func _snap_camera() -> void:
	camera.position = _cam_target()
	camera.look_at(_look_point(), Vector3.UP)


func _process(delta: float) -> void:
	if hero == null:
		return
	var t := Time.get_ticks_msec() / 1000.0
	# torches flicker; crystals breathe and flare on each network pulse
	pulse_boost = maxf(0.0, pulse_boost - delta * 0.8)
	for f in flickers:
		var l: OmniLight3D = f["l"]
		if not is_instance_valid(l):
			continue
		var base := float(f.get("base_now", f["base"]))
		var sd := float(f["seed"])
		if f["kind"] == "fire":
			l.light_energy = base * (0.86 + 0.1 * sin(t * 9.0 + sd) + 0.06 * sin(t * 23.0 + sd * 2.0))
		else:
			l.light_energy = base * (0.85 + 0.15 * sin(t * 1.6 + sd)) + (pulse_boost * 2.5 if l == monument_light else pulse_boost * 0.6)
	sky_timer -= delta
	if sky_timer <= 0.0:
		sky_timer = 5.0
		_update_sky()
	for npc in npcs:
		if is_instance_valid(npc["n"]):
			_npc_step(npc, delta)
	for b in birds:
		var n: Node3D = b["n"]
		if not is_instance_valid(n):
			continue
		b["a"] = float(b["a"]) + delta * float(b["s"])
		var a := float(b["a"])
		var c: Vector3 = b["c"]
		n.position = c + Vector3(cos(a) * float(b["r"]), float(b["h"]) + sin(a * 3.0) * 0.4, sin(a) * float(b["r"]))
		n.rotation.y = -a + (PI if float(b["s"]) > 0 else 0.0)
		n.scale = Vector3(1.0, 1.0 + sin(t * 10.0 + a) * 0.6, 1.0)
	_pet_step(delta)
	if weather and weather.visible:
		weather.position = Vector3(hero.position.x, 10.0, hero.position.z)
	if bobber and line_mesh:
		line_mesh.clear_surfaces()
		line_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		line_mesh.surface_add_vertex(_rod_tip())
		line_mesh.surface_add_vertex(bobber.position)
		line_mesh.surface_end()
	if cinematic:
		return
	var k := 1.0 - exp(-delta * 5.0)
	camera.position = camera.position.lerp(_cam_target(), k)
	camera.look_at(_look_point(), Vector3.UP)
	if shake > 0.0:
		camera.position += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * shake * 0.3
		shake = maxf(0.0, shake - delta * 1.2)


func _unhandled_input(event) -> void:
	if not input_enabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressed = true
			_press_pos = event.position
			_dragged = false
		else:
			if _pressed and not _dragged:
				_tap(event.position)
			_pressed = false
	elif event is InputEventMouseMotion and _pressed:
		if event.position.distance_to(_press_pos) > 18.0:
			_dragged = true
		if _dragged:
			cam_yaw -= event.relative.x * 0.008


func _tap(pos: Vector2) -> void:
	var best = null
	var best_d := 150.0
	for p in pickables:
		if camera.is_position_behind(p["pos"]):
			continue
		var sp := camera.unproject_position(p["pos"])
		var d := sp.distance_to(pos)
		if d < best_d:
			best_d = d
			best = p
	if best != null:
		if best["kind"] == "place":
			place_tapped.emit(best["id"])
		else:
			vein_tapped.emit(best["id"])
		return
	var origin := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	if dir.y < -0.01:
		var tt := -origin.y / dir.y
		walk_to_point(origin + dir * tt)
