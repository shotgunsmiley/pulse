extends Node3D
# An adventurer (the player or a townsperson): a rig of low-poly parts (torso, head,
# face, hair, arms, legs, pickaxe). v5 animation: idle breathing, a walk with body bob,
# a strike swing, a cheer when a vein breaks, a stumble on a miss, and emotes.

signal impact

const MD = preload("res://scripts/model_data.gd")
const MB = preload("res://scripts/mesh_builder.gd")

var parts := {}
var walking := false
var swinging := false
var acting := false          # cheer / stumble / emote in progress
var walk_t := 0.0
var idle_t := 0.0
var arm_r_deg := 8.0
var arm_l_deg := 8.0
var torso_y := 0.0
var pick_light: OmniLight3D = null
var pick_tier := "starter"


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
	var order := ["torso", "head", "hair", "arm_l", "arm_r", "leg_l", "leg_r", "pickaxe"]
	if face > 0:
		rig["face"] = ["hero_face%d" % face, "head", [0, 0, 0]]
		order.insert(3, "face")
	for part in order:
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
	parts["pickaxe"].rotation.x = PI
	torso_y = parts["torso"].position.y
	if tier == "crystal" or tier == "void":
		pick_light = OmniLight3D.new()
		pick_light.light_color = Color("#5fe0cf") if tier == "crystal" else Color("#a979f0")
		pick_light.omni_range = 1.6
		pick_light.light_energy = 0.8
		pick_light.position = Vector3(0, 0.78, 0)
		parts["pickaxe"].add_child(pick_light)
	_apply_arms()


func _pick(appearance: Dictionary, key: String, count: int) -> int:
	return clampi(int(appearance.get(key, 0)), 0, count - 1)


func _apply_arms() -> void:
	if parts.has("arm_r"):
		parts["arm_r"].rotation.x = deg_to_rad(arm_r_deg)
		parts["arm_l"].rotation.x = deg_to_rad(arm_l_deg)


func set_walking(on: bool) -> void:
	walking = on
	if not on and parts.has("leg_l"):
		parts["leg_l"].rotation.x = 0.0
		parts["leg_r"].rotation.x = 0.0
		parts["torso"].position.y = torso_y
		if not swinging and not acting:
			arm_r_deg = 8.0
			arm_l_deg = 8.0
			_apply_arms()


func _process(delta: float) -> void:
	if not parts.has("leg_l"):
		return
	if pick_light:
		pick_light.light_energy = 0.7 + 0.25 * sin(Time.get_ticks_msec() * 0.004)
	if walking:
		walk_t += delta * 9.0
		var s := sin(walk_t)
		parts["leg_l"].rotation.x = s * 0.55
		parts["leg_r"].rotation.x = -s * 0.55
		parts["torso"].position.y = torso_y + absf(cos(walk_t)) * 0.035
		parts["torso"].rotation.y = s * 0.06
		if not swinging and not acting:
			arm_l_deg = -s * 28.0
			arm_r_deg = s * 20.0 + 8.0
			_apply_arms()
		return
	if swinging or acting:
		return
	# idle: slow breathing, a little sway, now and then a glance around
	idle_t += delta
	var b := sin(idle_t * 1.8)
	parts["torso"].position.y = torso_y + b * 0.008
	parts["torso"].rotation.y = sin(idle_t * 0.5) * 0.03
	parts["head"].rotation.y = sin(idle_t * 0.37) * 0.25 * clampf(sin(idle_t * 0.13) * 3.0, 0.0, 1.0)
	arm_r_deg = 8.0 + b * 2.0
	arm_l_deg = 8.0 - b * 2.0
	_apply_arms()


func _set_swing(v: Vector2) -> void:
	arm_r_deg = v.x
	arm_l_deg = v.y
	_apply_arms()


# Raise, strike (emits impact), recover. Fast enough that the hit lands right on the tap.
func swing() -> void:
	if swinging or not parts.has("arm_r"):
		return
	swinging = true
	var P: Dictionary = MD.POSES
	var idle := Vector2(P["idle"]["arm_r"], P["idle"]["arm_l"])
	var up := Vector2(P["raise"]["arm_r"], P["raise"]["arm_l"])
	var down := Vector2(P["strike"]["arm_r"], P["strike"]["arm_l"])
	var tw := create_tween()
	tw.tween_method(_set_swing, Vector2(arm_r_deg, arm_l_deg), up, 0.1).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(parts["torso"], "rotation:x", -0.12, 0.1)
	tw.tween_method(_set_swing, up, down, 0.07).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(parts["torso"], "rotation:x", 0.18, 0.07)
	tw.tween_callback(func(): impact.emit())
	tw.tween_interval(0.1)
	tw.tween_method(_set_swing, down, idle, 0.22).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(parts["torso"], "rotation:x", 0.0, 0.22)
	await tw.finished
	swinging = false


func _act(fn: Callable) -> void:
	if acting or swinging or not parts.has("arm_r"):
		return
	acting = true
	await fn.call()
	parts["torso"].rotation = Vector3.ZERO
	parts["torso"].position.y = torso_y
	parts["head"].rotation = Vector3.ZERO
	arm_r_deg = 8.0
	arm_l_deg = 8.0
	_apply_arms()
	acting = false


# Vein broken: both arms up and a hop.
func cheer() -> void:
	await _act(func():
		var tw := create_tween()
		tw.tween_method(_set_swing, Vector2(arm_r_deg, arm_l_deg), Vector2(170, 170), 0.15)
		tw.parallel().tween_property(self, "position:y", 0.35, 0.18).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(self, "position:y", 0.0, 0.2).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_method(_set_swing, Vector2(170, 170), Vector2(150, 160), 0.12)
		tw.tween_method(_set_swing, Vector2(150, 160), Vector2(170, 170), 0.12)
		tw.tween_interval(0.15)
		await tw.finished)


# Missed strike: lean back, wobble, shake the head.
func stumble() -> void:
	await _act(func():
		var tw := create_tween()
		tw.tween_property(parts["torso"], "rotation:x", -0.25, 0.1)
		tw.parallel().tween_method(_set_swing, Vector2(arm_r_deg, arm_l_deg), Vector2(40, -30), 0.1)
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
					tw.parallel().tween_method(_set_swing, Vector2(120, 20), Vector2(20, 120), 0.25)
					tw.parallel().tween_property(parts["torso"], "position:y", torso_y + 0.06 * (i % 2), 0.25)
				await tw.finished)
		"wave", "salute":
			await _act(func():
				var tw := create_tween()
				tw.tween_method(_set_swing, Vector2(arm_r_deg, arm_l_deg), Vector2(160, 8), 0.15)
				for i in range(3):
					tw.tween_property(parts["arm_r"], "rotation:z", 0.4, 0.14)
					tw.tween_property(parts["arm_r"], "rotation:z", -0.2, 0.14)
				tw.tween_property(parts["arm_r"], "rotation:z", 0.0, 0.1)
				await tw.finished)
		"flex", "fire":
			await _act(func():
				var tw := create_tween()
				tw.tween_method(_set_swing, Vector2(arm_r_deg, arm_l_deg), Vector2(95, 95), 0.15)
				tw.parallel().tween_property(parts["arm_r"], "rotation:z", 1.1, 0.15)
				tw.parallel().tween_property(parts["arm_l"], "rotation:z", -1.1, 0.15)
				tw.tween_property(parts["torso"], "position:y", torso_y + 0.05, 0.2)
				tw.tween_interval(0.5)
				tw.tween_property(parts["arm_r"], "rotation:z", 0.0, 0.15)
				tw.parallel().tween_property(parts["arm_l"], "rotation:z", 0.0, 0.15)
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


static func random_look(rng: RandomNumberGenerator) -> Dictionary:
	return {"skin": rng.randi_range(0, 4), "hair_style": rng.randi_range(0, 3), "hair_color": rng.randi_range(0, 4),
		"shirt": rng.randi_range(0, 5), "pants": rng.randi_range(0, 3), "accent": rng.randi_range(0, 3), "face": rng.randi_range(0, 5)}
