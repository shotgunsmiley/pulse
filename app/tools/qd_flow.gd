extends SceneTree
# Plays a real practice Quickdraw in the arena (the sword duel above the pad),
# then plays a finished-duel replay and skips it halfway.
# godot --path . -s res://tools/qd_flow.gd   (server URL from user settings)
var M
var out := "/tmp/pulse_qd/"

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	var scene: PackedScene = load("res://main.tscn")
	M = scene.instantiate()
	root.add_child(M)
	_run()

func wait(sec: float) -> void:
	await create_timer(sec).timeout

func snap(name: String) -> void:
	await process_frame
	await process_frame
	root.get_viewport().get_texture().get_image().save_png(out + name + ".png")
	print("SHOT ", name)

func _find_sg(n: Node):
	for c in n.get_children():
		if c.get_script() and str(c.get_script().resource_path).ends_with("skill_game.gd"):
			return c
	return null

func _find_pad(n: Node):
	for c in n.get_children():
		if c is Button and (c.text == "STRIKE!" or c.text == "WAIT..." or c.text == "GET READY" or c.text.ends_with("ms") or c.text.begins_with("TOO")):
			return c
		var r = _find_pad(c)
		if r:
			return r
	return null

func _find_text(n: Node, t: String):
	for c in n.get_children():
		if c is Button and c.text == t:
			return c
		var r = _find_text(c, t)
		if r:
			return r
	return null

func _run() -> void:
	await wait(3.0)
	var name := "qd%d" % (randi() % 100000)
	var r: Dictionary = await M.api.post("/auth/register", {"username": name, "password": "secret123"})
	print("REGISTER ", r.get("ok"))
	M._on_logged_in(r["token"], r["profile"])
	await wait(2.0)
	M.go("arena")
	await wait(4.0)
	var ar = M.screens["arena"]
	ar._play("practice", "quickdraw", "")
	await wait(1.0)
	var sg = _find_sg(ar)
	print("SKILL GAME ", sg != null)
	var taps := 0
	var shots := 0
	var t0 := Time.get_ticks_msec()
	while is_instance_valid(sg) and sg.get_parent() != null and Time.get_ticks_msec() - t0 < 60000:
		var pad = _find_pad(sg)
		if pad and pad.text == "STRIKE!":
			await wait(0.22 + 0.04 * taps)
			sg.tap_flag = true
			sg.tap_time = Time.get_ticks_msec()
			taps += 1
			await wait(0.35)
			if shots < 3:
				await snap("qd_round_%d" % taps)
				shots += 1
		elif sg.info and sg.info.text.begins_with("The duel is decided"):
			await wait(1.6)
			await snap("qd_finale")
			await wait(3.0)
			break
		await process_frame
	print("TAPS ", taps)
	await wait(3.0)
	await snap("qd_after")
	# replay of a settled pvp duel, skipped halfway
	var look: Dictionary = M.profile.get("appearance", {})
	var rep := {"stake": 100, "result": {"winner": name},
		"sides": [{"username": name, "me": true, "look": look, "replay": {"reactions": [240, 300, -1, 260, 250]}},
			{"username": "Rival", "me": false, "look": {"skin": 1, "hair": 2, "hair_color": 3, "shirt": 4, "pants": 1, "face": 3}, "replay": {"reactions": [280, 270, 290, 300, 310]}}]}
	ar._sword_fight(rep)
	await wait(5.0)
	await snap("qd_replay_mid")
	var sk = _find_text(ar, "SKIP")
	print("SKIP FOUND ", sk != null)
	if sk:
		sk.emit_signal("pressed")
	await wait(4.0)
	await snap("qd_replay_skipped")
	# full replay to the end
	ar._sword_fight(rep)
	await wait(26.0)
	await snap("qd_replay_end")
	print("QD FLOW DONE")
	quit()
