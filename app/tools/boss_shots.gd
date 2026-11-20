extends SceneTree
# v5.5 world boss tour: plays a whole monster event through the real app against a local
# server - the 3-minute-style countdown (shortened by the admin route), the banner on other
# screens, the Board notice, the fight with other players around the monster, the kill,
# the reward, and then a look at the other four monsters arriving.
# Needs: a local server with PULSE_ADMIN_TOKEN set, and boss_bots.py bringing the first monster.
# godot --path . -s res://tools/boss_shots.gd   (ADMIN env = the admin token)
var M
var out := "/tmp/pulse_boss/"
var notes := []

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

func find_btn(n: Node, text: String):
	for c in n.get_children():
		if c is Button and str(c.text).begins_with(text):
			return c
		var r = find_btn(c, text)
		if r:
			return r
	return null

func admin(path: String) -> void:
	var h := HTTPRequest.new()
	root.add_child(h)
	h.request(M.api.base_url + path, ["Authorization: Bearer " + OS.get_environment("ADMIN")])
	var res = await h.request_completed
	print("ADMIN ", path, " -> ", res[1])
	h.queue_free()

func ideal(ch: Dictionary, after: float = 230.0) -> float:
	var best := -1.0
	for target in [float(ch["zone_center"]), 2.0 - float(ch["zone_center"])]:
		var t := fposmod(target - float(ch["offset"]), 2.0) / float(ch["speed"]) * 1000.0
		while t < after:
			t += 2.0 / float(ch["speed"]) * 1000.0
		best = t if best < 0.0 else minf(best, t)
	return best

# A good human thumb: aims for the gold, usually lands within ~40 ms.
func swing_once(p, err_ms: float = 35.0) -> bool:
	var tries := 0
	while p.challenge_id == "" and tries < 60 and boss_state() == "live":
		await wait(0.1)
		tries += 1
	if p.challenge_id == "":
		return false
	var target := ideal(p.bar.ch) + randf_range(-err_ms, err_ms)
	while p.bar.elapsed() < int(target):
		await process_frame
	p.strike_btn.emit_signal("button_down")
	await wait(0.2)
	return true

func boss_state() -> String:
	return str(M.boss.get("state", ""))

func _run() -> void:
	await wait(3.0)
	var nm := "hero%d" % (randi() % 1000)
	var r: Dictionary = await M.api.post("/auth/register", {"username": nm, "password": "secret123"})
	M._on_logged_in(r["token"], r["profile"])
	M.world.debug_hour = 15.0
	await wait(3.0)
	if M.tutorial != null and is_instance_valid(M.tutorial):
		M.tutorial._finish()
	M._close_overlay()
	# 1. the countdown: banner + summoning circle in the square
	var t0 := Time.get_ticks_msec()
	while boss_state() != "countdown" and Time.get_ticks_msec() - t0 < 20000:
		await wait(0.5)
	notes.append("countdown seen: %s (%s)" % [boss_state(), str(M.boss.get("name", ""))])
	await wait(1.5)
	await snap("b01_countdown_town")
	M.world.walk_to({"p": [2.2, 0, 4.6], "look": [5.6, 0, 1.6]})
	await wait(3.0)
	await snap("b02_summoning_circle")
	M.go("board")
	await wait(4.0)
	await M.screens["board"]._set_tab("monsters")
	await wait(1.0)
	await snap("b03_board_monsters")
	M.go("mine")
	await wait(3.0)
	await snap("b04_banner_in_mine")
	# tap the banner: straight to the square
	M.boss_banner_btn.emit_signal("pressed")
	await wait(4.0)
	await snap("b05_panel_countdown")
	# 2. it arrives
	t0 = Time.get_ticks_msec()
	while boss_state() != "live" and Time.get_ticks_msec() - t0 < 90000:
		await wait(0.25)
	notes.append("live: %s" % boss_state())
	await wait(0.7)
	await snap("b06_arrival")
	await wait(1.6)
	await snap("b07_arrived")
	# 3. fight until it falls (the bots fight too)
	var p = M.screens["boss"]
	var n := 0
	var shot_hard := false
	t0 = Time.get_ticks_msec()
	while boss_state() == "live" and Time.get_ticks_msec() - t0 < 420000:
		var ok: bool = await swing_once(p, 30.0 if n % 5 else 70.0)
		if not ok:
			await wait(0.3)
			continue
		n += 1
		if n == 6:
			await snap("b08_fight")
		if n == 20:
			await snap("b09_fight_more")
		if not shot_hard and M.boss.get("tricks", {}).has("hardened"):
			shot_hard = true
			await wait(0.4)
			await snap("b10_golem_hardened")
		while p.busy:
			await process_frame
	notes.append("fight over after %d of my strikes: %s" % [n, boss_state()])
	await wait(1.0)
	await snap("b11_death")
	await wait(4.0)
	await snap("b12_reward")
	notes.append("overlay open: %s" % str(M.overlay != null))
	M._close_overlay()
	await wait(1.5)
	await snap("b13_after")
	# 4. the other monsters: bring each one, watch it arrive, land a few hits
	for mk in ["wyrm", "spider", "wraith", "drake"]:
		M._close_overlay()
		await admin("/admin/boss?spawn=%s&lead=6" % mk)
		M.poll_boss_soon()
		t0 = Time.get_ticks_msec()
		while (boss_state() != "live" or str(M.boss.get("monster", "")) != mk) and Time.get_ticks_msec() - t0 < 30000:
			await wait(0.25)
		if M.current != "boss":
			M.open_boss()
		await wait(1.0)
		await snap("b20_%s_arrive" % mk)
		for i in range(7):
			await swing_once(p)
			while p.busy:
				await process_frame
		await wait(0.3)
		await snap("b21_%s_fight" % mk)
		if mk == "wyrm":
			# wait for it to burrow (every 40 s, from 20 s in)
			t0 = Time.get_ticks_msec()
			while not M.boss.get("tricks", {}).has("burrowed") and Time.get_ticks_msec() - t0 < 45000:
				M.poll_boss_soon()
				await wait(1.0)
			await wait(1.2)
			await snap("b22_wyrm_burrowed")
		if mk == "drake":
			t0 = Time.get_ticks_msec()
			while not M.boss.get("tricks", {}).has("shield") and Time.get_ticks_msec() - t0 < 45000:
				M.poll_boss_soon()
				await wait(1.0)
			await wait(0.6)
			await snap("b23_drake_shield")
	# 5. force the next monster in: the drake is driven off and a new countdown starts
	await admin("/admin/boss?spawn=golem&lead=60")
	M.poll_boss_soon()
	await wait(2.5)
	await snap("b24_next_countdown")
	M._close_overlay()
	M.go("profile")
	await wait(2.0)
	M.screens["profile"]._set_tab("badges")
	await wait(3.0)
	await snap("b25_journal")
	for l in notes:
		print("NOTE ", l)
	quit()
