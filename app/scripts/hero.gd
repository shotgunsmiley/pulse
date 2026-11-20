extends Node3D
# An adventurer (the player, a townsperson or a duel opponent). v5.1: a jointed body
# (shoulder + elbow, hip + knee) built to 2007-era proportions.
# Animations: idle breathing, walking with knee bend, pickaxe swing, cheer, stumble,
# emotes, and for Quickdraw duels: draw sword, en-garde, lunge-strike, knocked down,
# get up, victory.

signal impact

const MD = preload("res://scripts/model_data.gd")
const MB = preload("res://scripts/mesh_builder.gd")
const PARTS := ["torso", "head", "hair", "face", "uparm_l", "forearm_l", "uparm_r", "forearm_r", "thigh_l", "shin_l", "thigh_r", "shin_r", "pickaxe", "sword"]

var parts := {}
var walking := false
var swinging := false
var acting := false
var walk_t := 0.0
var idle_t := 0.0
var torso_y := 0.0
var pick_light: OmniLight3D = null
var pick_tier := "starter"
var tool := "pickaxe"        # "pickaxe", "sword" or "none"
var stance := false          # holding the en-garde pose (duels)
var home_yaw := 0.0          # facing to return to after a duel knockdown


func build(appearance: Dictionary, tier: String) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	parts.clear()
	pick_light = null
	pick_tier = tier
	var A: Dictionary = MD.APPEARANCE
	var slots: Dictionary = MD.SLOTS
	var picks: Dictionary = A["pick"]
	var ov := {
		int(slots["skin"]): Color(A["skin"][_pick(appearance, "skin", A["skin"].size())]),
		int(slots["hair"]): Color(A["hair_color"][_pick(appearance, "hair_color", A["hair_color"].size())]),
		int(slots["shirt"]): Color(A["shirt"][_pick(appearance, "shirt", A["shirt"].size())]),
		int(slots["pants"]): Color(A["pants"][_pick(appearance, "pants", A["pants"].size())]),
		int(slots["accent"]): Color(A["accent"][_pick(appearance, "accent", A["accent"].size())]),
		int(slots["pick"]): Color(picks.get(tier, picks["starter"])),
	}
	var rig: Dictionary = MD.HERO_RIG.duplicate(true)
	rig["hair"] = ["hero_hair%d" % _pick(appearance, "hair_style", 4), "head", [0, 0, 0]]
	var face := _pick(appearance, "face", MD.FACES)
	if face > 0:
		rig["face"] = ["hero_face%d" % face, "head", [0, 0, 0]]
	for part in PARTS:
		if not rig.has(part):
			continue
		var e: Array = rig[part]
		var pivot := Node3D.new()
		pivot.name = part
		var off: Array = e[2]
		pivot.position = Vector3(off[0], off[1], off[2])
		var parent_name: String = e[1]
		if parent_name == "":
			add_child(pivot)
		else:
			parts[parent_name].add_child(pivot)
		pivot.add_child(MB.instance(e[0], ov, true))
		parts[part] = pivot
	# names older code uses
	parts["arm_r"] = parts["uparm_r"]
	parts["arm_l"] = parts["uparm_l"]
	parts["leg_l"] = parts["thigh_l"]
	parts["leg_r"] = parts["thigh_r"]
	torso_y = parts["torso"].position.y
	if tier == "crystal" or tier == "void":
		pick_light = OmniLight3D.new()
		pick_light.light_color = Color("#5fe0cf") if tier == "crystal" else Color("#a979f0")
		pick_light.omni_range = 1.6
		pick_light.light_energy = 0.8
		pick_light.position = Vector3(0, 0.7, 0)
		parts["pickaxe"].add_child(pick_light)
	set_tool(tool)
	_rest_pose()


func _pick(appearance: Dictionary, key: String, count: int) -> int:
	return clampi(int(appearance.get(key, 0)), 0, count - 1)


func set_tool(kind: String) -> void:
	tool = kind
	if parts.has("pickaxe"):
		parts["pickaxe"].visible = kind == "pickaxe"
		parts["sword"].visible = kind == "sword"
		# tools hang point-down from the hand at rest
		parts["pickaxe"].rotation = Vector3(PI, 0, 0)
		parts["sword"].rotation = Vector3(PI * 0.62, 0, 0)


# ------------------------------------------------------------------ pose helpers (degrees)
func _arms(r: float, l: float, er: float = 12.0, el: float = 12.0) -> void:
	parts["uparm_r"].rotation.x = deg_to_rad(r)
	parts["uparm_l"].rotation.x = deg_to_rad(l)
	parts["forearm_r"].rotation.x = deg_to_rad(er)
	parts["forearm_l"].rotation.x = deg_to_rad(el)


func _legs(tl: float, tr: float, kl: float = 0.0, kr: float = 0.0) -> void:
	parts["thigh_l"].rotation.x = deg_to_rad(tl)
	parts["thigh_r"].rotation.x = deg_to_rad(tr)
	parts["shin_l"].rotation.x = deg_to_rad(-kl)
	parts["shin_r"].rotation.x = deg_to_rad(-kr)


func _rest_pose() -> void:
	if not parts.has("torso"):
		return
	for k in ["torso", "head", "uparm_l", "uparm_r", "forearm_l", "forearm_r", "thigh_l", "thigh_r", "shin_l", "shin_r"]:
		parts[k].rotation = Vector3.ZERO
	parts["torso"].position.y = torso_y
	_arms(6, 6)
	parts["uparm_r"].rotation.z = deg_to_rad(-4)
	parts["uparm_l"].rotation.z = deg_to_rad(4)


func _pose_v(v: Vector4) -> void:      # tween target: (shoulder r, shoulder l, elbow r, elbow l)
	_arms(v.x, v.y, v.z, v.w)


func _cur_arms() -> Vector4:
	return Vector4(rad_to_deg(parts["uparm_r"].rotation.x), rad_to_deg(parts["uparm_l"].rotation.x),
		rad_to_deg(parts["forearm_r"].rotation.x), rad_to_deg(parts["forearm_l"].rotation.x))


func set_walking(on: bool) -> void:
	walking = on
	if not on and parts.has("torso") and not swinging and not acting and not stance:
		_rest_pose()


func _process(delta: float) -> void:
	if not parts.has("torso"):
		return
	if pick_light:
		pick_light.light_energy = 0.7 + 0.25 * sin(Time.get_ticks_msec() * 0.004)
	if walking:
		walk_t += delta * 8.5
		var s := sin(walk_t)
		var c := cos(walk_t)
		# hips swing, knees bend on the back-swing, a little bounce each step
		_legs(s * 32.0, -s * 32.0, maxf(0.0, -s) * 45.0 + 8.0, maxf(0.0, s) * 45.0 + 8.0)
		parts["torso"].position.y = torso_y + absf(c) * 0.03
		parts["torso"].rotation.y = s * 0.07
		if not swinging and not acting:
			_arms(-s * 26.0 + 4.0, s * 26.0 + 4.0, 18.0 + maxf(0.0, s) * 20.0, 18.0 + maxf(0.0, -s) * 20.0)
		return
	if swinging or acting or stance:
		return
	idle_t += delta
	var b := sin(idle_t * 1.8)
	parts["torso"].position.y = torso_y + b * 0.006
	parts["torso"].rotation.y = sin(idle_t * 0.5) * 0.03
	parts["head"].rotation.y = sin(idle_t * 0.37) * 0.25 * clampf(sin(idle_t * 0.13) * 3.0, 0.0, 1.0)
	_arms(6.0 + b * 2.0, 6.0 - b * 2.0, 12.0 + b * 2.0, 12.0 - b * 2.0)
	_legs(0, 0, 3, 3)


# ------------------------------------------------------------------ mining
func swing() -> void:
	if swinging or not parts.has("torso"):
		return
	swinging = true
	if tool != "pickaxe":
		set_tool("pickaxe")
	var P: Dictionary = MD.POSES
	var up := Vector4(P["raise"]["arm_r"], P["raise"]["arm_l"], P["raise"]["elbow_r"], P["raise"]["elbow_l"])
	var down := Vector4(P["strike"]["arm_r"], P["strike"]["arm_l"], P["strike"]["elbow_r"], P["strike"]["elbow_l"])
	var idle := Vector4(6, 6, 12, 12)
	var tw := create_tween()
	tw.tween_method(_pose_v, _cur_arms(), up, 0.1).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(parts["torso"], "rotation:x", -0.14, 0.1)
	tw.parallel().tween_method(func(k: float): _legs(-8 * k, 10 * k, 14 * k, 10 * k), 0.0, 1.0, 0.1)
	tw.tween_method(_pose_v, up, down, 0.07).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(parts["torso"], "rotation:x", 0.22, 0.07)
	tw.tween_callback(func(): impact.emit())
	tw.tween_interval(0.1)
	tw.tween_method(_pose_v, down, idle, 0.22).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(parts["torso"], "rotation:x", 0.0, 0.22)
	tw.parallel().tween_method(func(k: float): _legs(-8 * k, 10 * k, 14 * k, 10 * k), 1.0, 0.0, 0.22)
	await tw.finished
	swinging = false


func _act(fn: Callable) -> void:
	if acting or swinging or not parts.has("torso"):
		return
	acting = true
	await fn.call()
	if not stance:
		_rest_pose()
	acting = false


func cheer() -> void:
	await _act(func():
		var tw := create_tween()
		tw.tween_method(_pose_v, _cur_arms(), Vector4(170, 170, 10, 10), 0.15)
		tw.parallel().tween_method(func(k: float): _legs(0, 0, 30 * k, 30 * k), 0.0, 1.0, 0.1)
		tw.tween_property(self, "position:y", 0.32, 0.18).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		tw.parallel().tween_method(func(k: float): _legs(0, 0, 30 * k, 30 * k), 1.0, 0.0, 0.12)
		tw.tween_property(self, "position:y", 0.0, 0.2).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_method(_pose_v, Vector4(170, 170, 10, 10), Vector4(150, 160, 40, 30), 0.12)
		tw.tween_method(_pose_v, Vector4(150, 160, 40, 30), Vector4(170, 170, 10, 10), 0.12)
		tw.tween_interval(0.15)
		await tw.finished)


func stumble() -> void:
	await _act(func():
		var tw := create_tween()
		tw.tween_property(parts["torso"], "rotation:x", -0.25, 0.1)
		tw.parallel().tween_method(_pose_v, _cur_arms(), Vector4(40, -30, 30, 20), 0.1)
		tw.parallel().tween_method(func(k: float): _legs(-12 * k, 6 * k, 10 * k, 20 * k), 0.0, 1.0, 0.1)
		tw.tween_property(parts["torso"], "rotation:z", 0.12, 0.08)
		tw.tween_property(parts["torso"], "rotation:z", -0.12, 0.1)
		tw.tween_property(parts["torso"], "rotation:z", 0.0, 0.08)
		tw.parallel().tween_property(parts["torso"], "rotation:x", 0.0, 0.15)
		tw.tween_property(parts["head"], "rotation:y", 0.35, 0.08)
		tw.tween_property(parts["head"], "rotation:y", -0.35, 0.12)
		tw.tween_property(parts["head"], "rotation:y", 0.0, 0.08)
		await tw.finished)


func emote(kind: String) -> void:
	match kind:
		"cheer", "gg":
			await cheer()
		"dance":
			await _act(func():
				var tw := create_tween()
				for i in range(4):
					tw.tween_property(self, "rotation:y", rotation.y + PI * 0.5 * (i + 1), 0.25)
					tw.parallel().tween_method(_pose_v, Vector4(120, 20, 60, 20), Vector4(20, 120, 20, 60), 0.25)
					tw.parallel().tween_method(func(k: float): _legs(20 * k, -20 * k, 30 * k, 10), 0.0 if i % 2 == 0 else 1.0, 1.0 if i % 2 == 0 else 0.0, 0.25)
				await tw.finished)
		"wave", "salute":
			await _act(func():
				var tw := create_tween()
				tw.tween_method(_pose_v, _cur_arms(), Vector4(150, 6, 70, 12), 0.15)
				for i in range(3):
					tw.tween_property(parts["forearm_r"], "rotation:z", 0.45, 0.14)
					tw.tween_property(parts["forearm_r"], "rotation:z", -0.25, 0.14)
				tw.tween_property(parts["forearm_r"], "rotation:z", 0.0, 0.1)
				await tw.finished)
		"flex", "fire":
			await _act(func():
				var tw := create_tween()
				tw.tween_method(_pose_v, _cur_arms(), Vector4(90, 90, 110, 110), 0.15)
				tw.parallel().tween_property(parts["uparm_r"], "rotation:z", -1.2, 0.15)
				tw.parallel().tween_property(parts["uparm_l"], "rotation:z", 1.2, 0.15)
				tw.tween_property(parts["torso"], "position:y", torso_y + 0.04, 0.2)
				tw.tween_interval(0.5)
				tw.tween_property(parts["uparm_r"], "rotation:z", 0.0, 0.15)
				tw.parallel().tween_property(parts["uparm_l"], "rotation:z", 0.0, 0.15)
				await tw.finished)
		"slump", "laugh", "wow":
			await _act(func():
				var tw := create_tween()
				tw.tween_property(parts["torso"], "rotation:x", 0.35 if kind == "slump" else -0.2, 0.25)
				tw.parallel().tween_property(parts["head"], "rotation:x", 0.4 if kind == "slump" else -0.3, 0.25)
				if kind == "laugh":
					for i in range(4):
						tw.tween_property(parts["torso"], "position:y", torso_y + 0.03, 0.08)
						tw.tween_property(parts["torso"], "position:y", torso_y, 0.08)
				else:
					tw.tween_interval(0.7)
				tw.tween_property(parts["head"], "rotation:x", 0.0, 0.2)
				await tw.finished)
		_:
			await cheer()


# ------------------------------------------------------------------ sword duels
# En-garde: knees bent, sword up and forward, off-hand back.
const GUARD := Vector4(62, 20, 70, 50)


func en_garde() -> void:
	stance = true
	if tool != "sword":
		set_tool("sword")
	parts["sword"].rotation = Vector3(deg_to_rad(95), 0, 0)
	for k in ["head", "uparm_l", "uparm_r"]:
		parts[k].rotation.z = 0.0
		parts[k].rotation.y = 0.0
	var tw := create_tween()
	tw.parallel().tween_property(parts["torso"], "rotation:z", 0.0, 0.2)
	tw.parallel().tween_property(parts["torso"], "rotation:y", 0.0, 0.2)
	tw.tween_method(_pose_v, _cur_arms(), GUARD, 0.25).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_method(func(k: float): _legs(18 * k, -14 * k, 28 * k, 22 * k), 0.0, 1.0, 0.25)
	tw.parallel().tween_property(parts["torso"], "position:y", torso_y - 0.06, 0.25)
	tw.parallel().tween_property(parts["torso"], "rotation:x", 0.08, 0.25)
	await tw.finished


# Step in and slash. dist = how far to travel toward the opponent (local -z).
func lunge(dist: float, fast: bool = true) -> void:
	acting = true
	var fwd := -global_transform.basis.z.normalized()
	var start := position
	var t1 := 0.09 if fast else 0.16
	var tw := create_tween()
	tw.tween_method(_pose_v, _cur_arms(), Vector4(165, 30, 60, 40), t1).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(parts["torso"], "rotation:x", -0.15, t1)
	tw.tween_method(_pose_v, Vector4(165, 30, 60, 40), Vector4(50, -10, 0, 30), 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(self, "position", start + fwd * dist, 0.1)
	tw.parallel().tween_property(parts["torso"], "rotation:x", 0.3, 0.08)
	tw.parallel().tween_method(func(k: float): _legs(40 * k + 18 * (1 - k), -30 * k - 14 * (1 - k), 20, 10), 0.0, 1.0, 0.1)
	tw.tween_callback(func(): impact.emit())
	await tw.finished
	acting = false


# Hit: knocked backward onto the ground.
func knocked_down(spin: float = 0.0) -> void:
	acting = true
	stance = false
	# the blow twists the body so it falls diagonally (stays on screen)
	var back := global_transform.basis.z.normalized().rotated(Vector3.UP, spin)
	var tw := create_tween()
	tw.tween_property(parts["torso"], "rotation:x", -0.5, 0.08)
	tw.parallel().tween_property(self, "rotation:y", rotation.y + spin, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_method(_pose_v, _cur_arms(), Vector4(120, 130, 20, 20), 0.08)
	tw.parallel().tween_property(self, "position", position + back * 0.2, 0.12)
	tw.tween_property(self, "rotation:x", PI * 0.47, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(self, "position", position + back * 0.3 + Vector3(0, 0.12, 0), 0.32)
	tw.parallel().tween_method(func(k: float): _legs(30 * k, 20 * k, 10 * k, 30 * k), 0.0, 1.0, 0.3)
	tw.parallel().tween_method(_pose_v, Vector4(120, 130, 20, 20), Vector4(160, 140, 0, 10), 0.3)
	tw.tween_property(self, "position:y", 0.04, 0.06)
	tw.tween_property(self, "position:y", 0.12, 0.08)
	await tw.finished
	if parts["sword"].visible:
		parts["sword"].rotation.x = deg_to_rad(150)
	acting = false


func get_up(home: Vector3) -> void:
	acting = true
	var tw := create_tween()
	tw.tween_property(self, "rotation:x", 0.0, 0.35).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(self, "rotation:y", home_yaw, 0.4)
	tw.parallel().tween_property(self, "position", home, 0.4)
	tw.parallel().tween_property(parts["torso"], "rotation:x", 0.0, 0.35)
	await tw.finished
	acting = false
	await en_garde()


# Back to the start mark, still in guard.
func return_to(home: Vector3) -> void:
	acting = true
	var tw := create_tween()
	tw.tween_property(self, "position", home, 0.3).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(self, "rotation:y", home_yaw, 0.3)
	tw.parallel().tween_property(parts["torso"], "rotation:x", 0.08, 0.3)
	await tw.finished
	acting = false
	await en_garde()


func false_start() -> void:
	acting = true
	var tw := create_tween()
	tw.tween_property(parts["torso"], "rotation:x", 0.35, 0.1)
	tw.tween_property(parts["torso"], "rotation:z", 0.15, 0.08)
	tw.tween_property(parts["torso"], "rotation:z", -0.15, 0.1)
	tw.tween_property(parts["torso"], "rotation:z", 0.0, 0.08)
	tw.tween_property(parts["torso"], "rotation:x", 0.08, 0.15)
	await tw.finished
	acting = false


func victory() -> void:
	stance = false
	acting = true
	parts["sword"].rotation = Vector3(deg_to_rad(15), 0, 0)
	var tw := create_tween()
	tw.tween_method(_pose_v, _cur_arms(), Vector4(175, 10, 0, 20), 0.25)
	tw.parallel().tween_method(func(k: float): _legs(0, 0, 6, 6), 0.0, 1.0, 0.2)
	tw.parallel().tween_property(parts["torso"], "rotation:x", -0.1, 0.25)
	tw.parallel().tween_property(parts["torso"], "position:y", torso_y, 0.25)
	tw.tween_property(self, "position:y", 0.15, 0.15)
	tw.tween_property(self, "position:y", 0.0, 0.15)
	await tw.finished
	acting = false


static func random_look(rng: RandomNumberGenerator) -> Dictionary:
	return {"skin": rng.randi_range(0, 4), "hair_style": rng.randi_range(0, 3), "hair_color": rng.randi_range(0, 5),
		"shirt": rng.randi_range(0, 5), "pants": rng.randi_range(0, 3), "accent": rng.randi_range(0, 3), "face": rng.randi_range(0, 5)}
