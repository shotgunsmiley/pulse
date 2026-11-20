extends SubViewportContainer
# QUICKDRAW SWORD DUEL - a small 3D arena shown above the Quickdraw pad.
# Two adventurers face off in guard. When a round is decided, the faster one lunges
# and strikes; the slower one is knocked to the ground, then gets up for the next
# round. At the end the overall winner raises their sword.
#   live play:  ready() -> go(op_rt) -> player_tap(rt) / early() / too_slow()
#   replays:    await replay(my_rts, op_rts)
# op_rt < 0 means unknown (a duel the other player has not played yet): the opponent
# just parries, and the real fight is shown once both have played.

signal round_done(winner: String)

const HeroScript = preload("res://scripts/hero.gd")

const ME_HOME := Vector3(-1.05, 0, 0)
const OP_HOME := Vector3(1.05, 0, 0)

var M
var vp: SubViewport
var cam: Camera3D
var me
var op
var me_name := "You"
var op_name := "Opponent"
var caption: Label
var names: HBoxContainer
var op_rt := -1
var go_ms := 0
var resolved := true
var gen := 0
var torches: Array = []
var shake := 0.0
var cam_base := Vector3(0, 1.25, 3.5)


func setup(m, me_look: Dictionary, me_tier: String, opp_name: String, op_look: Dictionary) -> void:
	M = m
	op_name = opp_name
	me_name = str(M.profile.get("username", "You")) if M and M.profile else "You"
	stretch = true
	custom_minimum_size = Vector2(0, 380)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp = SubViewport.new()
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_2X
	add_child(vp)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#1d1712")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#b8a080")
	env.ambient_light_energy = 0.75
	env.fog_enabled = true
	env.fog_light_color = Color("#1d1712")
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = 6.0
	env.fog_depth_end = 14.0
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 25, 0)
	sun.light_energy = 0.9
	sun.light_color = Color("#ffe2b8")
	vp.add_child(sun)
	_build_arena()
	me = HeroScript.new()
	vp.add_child(me)
	me.build(me_look, me_tier)
	op = HeroScript.new()
	vp.add_child(op)
	op.build(op_look, "iron")
	_place()
	cam = Camera3D.new()
	# keep the side-to-side view fixed so both fighters fit on any screen shape
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.fov = 74
	vp.add_child(cam)
	cam.current = true
	cam.position = cam_base
	cam.look_at(Vector3(0, 1.0, 0), Vector3.UP)
	# names along the top, caption along the bottom
	var over := VBoxContainer.new()
	over.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	over.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(over)
	names = HBoxContainer.new()
	over.add_child(names)
	for n in [me_name, op_name]:
		var l := Label.new()
		l.text = n
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if n == me_name else HORIZONTAL_ALIGNMENT_RIGHT
		l.add_theme_font_size_override("font_size", 30)
		l.add_theme_constant_override("outline_size", 8)
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		l.add_theme_color_override("font_color", Color("#ffd36b") if n == me_name else Color("#ff8a6a"))
		l.add_theme_color_override("font_shadow_color", Color.BLACK)
		l.add_theme_constant_override("shadow_offset_x", 2)
		l.add_theme_constant_override("shadow_offset_y", 2)
		names.add_child(l)
	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	over.add_child(sp)
	caption = Label.new()
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.add_theme_font_size_override("font_size", 34)
	caption.add_theme_constant_override("outline_size", 10)
	caption.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	caption.add_theme_color_override("font_color", Color.WHITE)
	caption.add_theme_color_override("font_shadow_color", Color.BLACK)
	caption.add_theme_constant_override("shadow_offset_x", 2)
	caption.add_theme_constant_override("shadow_offset_y", 2)
	over.add_child(caption)
	_start_guard()


func _start_guard() -> void:
	await get_tree().process_frame
	if not is_inside_tree():
		return
	me.en_garde()
	op.en_garde()


func _place() -> void:
	me.position = ME_HOME
	me.rotation = Vector3(0, -PI / 2, 0)
	me.home_yaw = -PI / 2
	op.position = OP_HOME
	op.rotation = Vector3(0, PI / 2, 0)
	op.home_yaw = PI / 2


func _mat(c: Color, unshaded := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


func _build_arena() -> void:
	var floor_mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 4.2
	cyl.bottom_radius = 4.2
	cyl.height = 0.1
	cyl.radial_segments = 20
	cyl.material = _mat(Color("#b89a66"))
	floor_mi.mesh = cyl
	floor_mi.position.y = -0.05
	vp.add_child(floor_mi)
	var ring := MeshInstance3D.new()
	var tor := CylinderMesh.new()
	tor.top_radius = 1.6
	tor.bottom_radius = 1.6
	tor.height = 0.02
	tor.radial_segments = 20
	tor.material = _mat(Color("#9c8152"))
	ring.mesh = tor
	vp.add_child(ring)
	for i in range(18):
		var a := TAU * i / 18.0
		var b := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(1.4, 0.9, 0.5)
		bm.material = _mat(Color("#6e675c") if i % 2 == 0 else Color("#5f584e"))
		b.mesh = bm
		b.position = Vector3(cos(a) * 4.4, 0.45, sin(a) * 4.4)
		b.rotation.y = -a + PI / 2
		vp.add_child(b)
	for x in [-2.6, 2.6]:
		var post := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 0.06
		pm.bottom_radius = 0.08
		pm.height = 2.2
		pm.material = _mat(Color("#4a3423"))
		post.mesh = pm
		post.position = Vector3(x, 1.1, -2.2)
		vp.add_child(post)
		var flame := MeshInstance3D.new()
		var fm := SphereMesh.new()
		fm.radius = 0.12
		fm.height = 0.3
		fm.material = _mat(Color("#ffb35c"), true)
		flame.mesh = fm
		flame.position = Vector3(x, 2.3, -2.2)
		vp.add_child(flame)
		var l := OmniLight3D.new()
		l.light_color = Color("#ffb35c")
		l.omni_range = 6.0
		l.light_energy = 1.6
		l.position = Vector3(x, 2.3, -2.0)
		vp.add_child(l)
		torches.append(l)
		var ban := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(0.7, 1.2)
		qm.material = _mat(Color("#8f2a26") if x < 0 else Color("#2b6e66"))
		ban.mesh = qm
		ban.position = Vector3(x * 0.55, 1.9, -3.9)
		vp.add_child(ban)


func _process(delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	for i in range(torches.size()):
		torches[i].light_energy = 1.5 + 0.2 * sin(t * 9.0 + i * 2.0) + 0.1 * sin(t * 23.0 + i)
	if cam:
		if shake > 0.0:
			cam.position = cam_base + Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * shake * 0.12
			shake = maxf(0.0, shake - delta * 2.5)
		else:
			cam.position = cam_base


func _say(text: String, color: Color = Color.WHITE) -> void:
	caption.text = text
	caption.add_theme_color_override("font_color", color)


func _sparks(at: Vector3, color: Color, n: int = 18) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = n
	p.lifetime = 0.45
	p.spread = 80.0
	p.direction = Vector3(0, 1, 0)
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 4.5
	p.gravity = Vector3(0, -7, 0)
	var bm := BoxMesh.new()
	bm.size = Vector3(0.04, 0.04, 0.04)
	bm.material = _mat(color, true)
	p.mesh = bm
	p.position = at
	vp.add_child(p)
	p.emitting = true
	var tw := p.create_tween()
	tw.tween_interval(0.8)
	tw.tween_callback(p.queue_free)


# a short wait that is safe if the duel screen was closed meanwhile
func _pause(sec: float) -> void:
	if is_inside_tree():
		await get_tree().create_timer(sec).timeout


func _play(s: String) -> void:
	if M:
		M.play(s)


# ------------------------------------------------------------------ outcomes
# The winner lunges across and strikes the loser down.
func strike(winner: String) -> void:
	var w = me if winner == "me" else op
	var l = op if winner == "me" else me
	await w.lunge(1.15, true)
	_sparks(l.position + Vector3(0, 1.3, 0), Color("#ffe0a0"), 22)
	_sparks(l.position + Vector3(0, 1.2, 0), Color("#c0304a"), 10)
	_play("clink")
	shake = 0.8
	if M:
		M.vibrate(60)
	# spin the loser so the fall goes back and away from the camera
	await l.knocked_down(-0.75 if l == me else 0.75)
	_play("thud")
	round_done.emit(winner)


# Both swing at the same instant: blades clash and both are thrown back.
func clash() -> void:
	me.lunge(0.65, true)
	await op.lunge(0.65, true)
	_sparks(Vector3(0, 1.4, 0), Color("#fff2c0"), 28)
	_play("anvil")
	shake = 0.5
	me.return_to(ME_HOME)
	await op.return_to(OP_HOME)
	round_done.emit("draw")


func _reset() -> void:
	# both fighters at once: start one, await the other (same length)
	if me.rotation.x > 0.2:
		me.get_up(ME_HOME)
	else:
		me.return_to(ME_HOME)
	if op.rotation.x > 0.2:
		await op.get_up(OP_HOME)
	else:
		await op.return_to(OP_HOME)
	await _pause(0.05)


# ------------------------------------------------------------------ live Quickdraw
func ready_round(n: int, total: int) -> void:
	gen += 1
	resolved = true
	await _reset()
	_say("Round %d of %d" % [n, total])


func go(opp_rt: int) -> void:
	op_rt = opp_rt
	go_ms = Time.get_ticks_msec()
	resolved = false
	gen += 1
	var my_gen := gen
	_say("STRIKE!", Color("#7fe36b"))
	if op_rt > 0:
		# a small grace period: a tap that came first but is still being read wins
		await _pause(op_rt / 1000.0 + 0.09)
		if my_gen == gen and not resolved and is_inside_tree():
			resolved = true
			_say("%s strikes first! (%d ms)" % [op_name, op_rt], Color("#ff8a6a"))
			await strike("op")


func player_tap(rt: int) -> void:
	if resolved:
		return
	resolved = true
	gen += 1
	if op_rt > 0 and absi(op_rt - rt) <= 8:
		_say("Dead even! %d ms vs %d ms" % [rt, op_rt], Color.WHITE)
		await clash()
	elif op_rt > 0 and op_rt < rt:
		_say("%s was faster (%d ms vs %d ms)" % [op_name, op_rt, rt], Color("#ff8a6a"))
		await strike("op")
	elif op_rt > 0:
		_say("You strike first! %d ms vs %d ms" % [rt, op_rt], Color("#ffd36b"))
		await strike("me")
	else:
		_say("%d ms! Parried - result when %s plays" % [rt, op_name], Color("#ffd36b"))
		await clash()


func early() -> void:
	resolved = true
	gen += 1
	_say("Too early! You lunged before the signal.", Color("#ff8a6a"))
	await me.false_start()
	await strike("op")


func too_slow() -> void:
	if resolved:
		return
	resolved = true
	gen += 1
	_say("Too slow!", Color("#ff8a6a"))
	await strike("op")


# ------------------------------------------------------------------ replays
func round_winner(a: int, b: int) -> String:
	if a <= 0 and b <= 0:
		return "none"
	if a <= 0:
		return "op"
	if b <= 0:
		return "me"
	if absi(a - b) <= 8:
		return "draw"
	return "me" if a < b else "op"


static func tally_winner(my_rts: Array, op_rts: Array) -> String:
	var a := 0
	var b := 0
	for i in range(mini(my_rts.size(), op_rts.size())):
		var x := int(my_rts[i])
		var y := int(op_rts[i])
		if x > 0 and (y <= 0 or x + 8 < y):
			a += 1
		elif y > 0 and (x <= 0 or y + 8 < x):
			b += 1
	return "me" if a > b else ("op" if b > a else "draw")


func replay(my_rts: Array, op_rts: Array, final_winner: String = "") -> void:
	var tally := {"me": 0, "op": 0}
	for i in range(mini(my_rts.size(), op_rts.size())):
		if not is_inside_tree():
			return
		await _reset()
		var a := int(my_rts[i])
		var b := int(op_rts[i])
		_say("Round %d" % (i + 1))
		await _pause(0.6)
		_say("STRIKE!", Color("#7fe36b"))
		await _pause(0.25)
		var w := round_winner(a, b)
		var fmt := func(x: int) -> String: return ("%d ms" % x) if x > 0 else "foul"
		match w:
			"me":
				tally["me"] += 1
				_say("%s %s  vs  %s %s" % [me_name, fmt.call(a), op_name, fmt.call(b)], Color("#ffd36b"))
				await strike("me")
			"op":
				tally["op"] += 1
				_say("%s %s  vs  %s %s" % [op_name, fmt.call(b), me_name, fmt.call(a)], Color("#ff8a6a"))
				await strike("op")
			"draw":
				_say("Dead even: %s vs %s" % [fmt.call(a), fmt.call(b)])
				await clash()
			_:
				_say("Both fouled!")
				await me.false_start()
		await _pause(0.7)
	if not is_inside_tree():
		return
	var champ := final_winner if final_winner != "" else ("me" if tally["me"] > tally["op"] else ("op" if tally["op"] > tally["me"] else "draw"))
	await finale(champ)


# The overall winner deals the final blow, then raises their sword.
func finale(champ: String) -> void:
	await _reset()
	if champ == "draw":
		_say("A draw! Both fighters stand.")
		return
	_say("FINAL BLOW!", Color("#ffd36b") if champ == "me" else Color("#ff8a6a"))
	await _pause(0.4)
	if not is_inside_tree():
		return
	await strike(champ)
	var w2 = me if champ == "me" else op
	await w2.return_to(ME_HOME if champ == "me" else OP_HOME)
	# turn three-quarters to the crowd for the victory pose
	var turn := create_tween()
	turn.tween_property(w2, "rotation:y", -2.4 if champ == "me" else 2.4, 0.25).set_trans(Tween.TRANS_SINE)
	await turn.finished
	await w2.victory()
	_say(("%s WINS THE DUEL!" % me_name) if champ == "me" else ("%s wins the duel." % op_name), Color("#ffd36b") if champ == "me" else Color("#ff8a6a"))
	_play("win" if champ == "me" else "lose")
