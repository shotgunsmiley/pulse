extends SceneTree
var only := ""
# v5.4 games tour: plays every new skill game through the real app (with a scripted thumb)
# and every new luck game in the Hall, taking screenshots along the way.
# godot --path . -s res://tools/games_shots.gd   (server URL from user settings)
var M
var out := "/tmp/pulse_games/"
var log_lines := []

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

func find_sg(n: Node):
	for c in n.get_children():
		if c.get_script() and str(c.get_script().resource_path).ends_with("skill_game.gd"):
			return c
	return null

# ---------------------------------------------------------------- scripted players
func thumb_tempo(sg) -> void:
	var beats: Array = sg.ch["beats"]
	var hammer = find_btn(sg, "HAMMER")
	var lane = null
	for c in sg.area.get_children():
		if c.get_class() == "Control" and c.get("beats") != null:
			lane = c
	var i := 0
	while i < beats.size() and is_instance_valid(sg) and not sg.aborted:
		await process_frame
		var now: int = Time.get_ticks_msec() - lane.t0
		if now >= int(beats[i]) + randi_range(-30, 30):
			hammer.emit_signal("button_down")
			i += 1
			if i == 12:
				await snap("g02_tempo")

func thumb_cart(sg) -> void:
	var ch: Dictionary = sg.ch
	var left = find_btn(sg, "<  LEFT")
	var right = find_btn(sg, "RIGHT  >")
	var track = null
	for c in sg.area.get_children():
		if c.get("crashed") != null:
			track = c
	var obs: Array = ch["obstacles"]
	var shot := false
	while is_instance_valid(track) and not track.crashed and not sg.aborted:
		await process_frame
		var now: int = Time.get_ticks_msec() - track.t0
		# find the next rock and get out of its way (stop after 25 rocks so the run ends)
		for o in obs:
			if int(o["t"]) > now and int(o["t"]) - now < 450:
				if obs.find(o) > 25:
					break
				if track.lane in o["lanes"]:
					var free := []
					for l in range(3):
						if not l in o["lanes"]:
							free.append(l)
					var target: int = free[0]
					for l in free:
						if absi(l - track.lane) < absi(target - track.lane):
							target = l
					if target < track.lane:
						left.emit_signal("button_down")
					else:
						right.emit_signal("button_down")
				break
		if not shot and now > 9000:
			shot = true
			await snap("g03_cartrun")
		if now > int(obs[obs.size() - 1]["t"]) + 500:
			break

func thumb_sort(sg) -> void:
	var items: Array = sg.ch["items"]
	var n := 0
	while n < items.size() and is_instance_valid(sg) and not sg.aborted:
		await wait(0.55)
		var big: Label = null
		for c in sg.area.get_children():
			if c is PanelContainer and c.get_child_count() > 0 and c.get_child(0) is Label:
				big = c.get_child(0)
		if big == null or big.text == "":
			continue
		var idx := ["COAL", "IRON", "CRYSTAL", "VOID"].find(big.text)
		var b = find_btn(sg, ["COAL", "IRON", "CRYSTAL", "VOID"][idx] + " BIN")
		if n == 5:
			await snap("g04_oresort")
		b.emit_signal("button_down")
		n += 1
		if n >= 14:
			# then make three mistakes to end the run
			for k in range(3):
				await wait(0.6)
				var other = find_btn(sg, "COAL BIN" if idx != 0 else "IRON BIN")
				other.emit_signal("button_down")
			return

func thumb_stack(sg) -> void:
	var drop = find_btn(sg, "DROP")
	var view = null
	for c in sg.area.get_children():
		if c.get("placed") != null:
			view = c
	var drops := 0
	while is_instance_valid(sg) and not sg.aborted and drops < 9 and not drop.disabled:
		await process_frame
		var top: Array = view.placed[view.placed.size() - 1]
		if absf(view.cur_x - float(top[0])) < 0.01 + drops * 0.004 and view.drop_y == 0.0:
			drop.emit_signal("button_down")
			drops += 1
			await wait(0.4)
			if drops == 6:
				await snap("g05_stack")
	# then a bad drop ends it
	await wait(0.3)
	while not drop.disabled and is_instance_valid(sg):
		await process_frame
		var top2: Array = view.placed[view.placed.size() - 1]
		if absf(view.cur_x - float(top2[0])) > 0.45 and view.drop_y == 0.0:
			drop.emit_signal("button_down")
			await wait(1.0)

func _play_skill(game: String) -> void:
	var ar = M.screens["arena"]
	ar._play("practice", game, "")
	await wait(1.2)
	var sg = find_sg(ar)
	if sg == null:
		print("NO GAME FOR ", game)
		return
	var t0 := Time.get_ticks_msec()
	match game:
		"tempo":
			await thumb_tempo(sg)
		"cartrun":
			await thumb_cart(sg)
		"oresort":
			await thumb_sort(sg)
		"stack":
			await thumb_stack(sg)
	# wait for the score
	while is_instance_valid(sg) and sg.get_parent() != null and Time.get_ticks_msec() - t0 < 120000:
		await wait(0.3)
	await wait(2.5)
	log_lines.append("%s best: %s" % [game, str(M.profile.get("best", {}).get(game))])
	await snap("g_after_" + game)

func _run() -> void:
	await wait(3.0)
	var name := "gm%d" % (randi() % 100000)
	var r: Dictionary = await M.api.post("/auth/register", {"username": name, "password": "secret123"})
	M._on_logged_in(r["token"], r["profile"])
	await wait(3.0)
	if M.tutorial != null and is_instance_valid(M.tutorial):
		M.tutorial._finish()
	M.go("arena")
	await wait(7.0)
	await snap("g01_arena_gotd")
	for g in ["tempo", "cartrun", "oresort", "stack"]:
		if OS.get_environment("ONLY_GAME") != "" and g != OS.get_environment("ONLY_GAME"):
			continue
		await _play_skill(g)
	if OS.get_environment("ONLY_GAME") != "":
		for l in log_lines:
			print("RESULT ", l)
		quit()
		return
	M.go("hall")
	await wait(7.0)
	var hall = M.screens["hall"]
	hall.bet = 2
	# High-Low
	await hall._set_tab("highlow")
	await wait(0.5)
	find_btn(hall, "DEAL THE FIRST CARD").emit_signal("pressed")
	await wait(1.5)
	await snap("g06_highlow")
	if not hall.hl.is_empty():
		await hall._hl_guess("higher" if int(hall.hl["card"]) <= 7 else "lower")
		await wait(0.8)
		await snap("g07_highlow_2")
		if not hall.hl.is_empty() and int(hall.hl["steps"]) > 0:
			find_btn(hall, "CASH OUT").emit_signal("pressed")
			await wait(1.0)
	# Cart Drop
	await hall._set_tab("drop")
	await wait(0.5)
	find_btn(hall, "DROP THE ORE").emit_signal("pressed")
	await wait(1.6)
	await snap("g08_cartdrop_falling")
	await wait(2.0)
	await snap("g09_cartdrop")
	# Chests
	await hall._set_tab("chests")
	await wait(0.5)
	find_btn(hall, "CHEST 2").emit_signal("pressed")
	await wait(0.8)
	await snap("g10_chests")
	await wait(1.5)
	if not hall.chest.is_empty():
		await snap("g11_chests_double")
		find_btn(hall, "TAKE IT").emit_signal("pressed")
		await wait(1.0)
	# Wheel + free spin
	await hall._set_tab("wheel")
	await wait(0.5)
	find_btn(hall, "SPIN FOR FREE").emit_signal("pressed")
	await wait(1.5)
	await snap("g12_wheel_free_spinning")
	await wait(3.5)
	find_btn(hall, "SPIN").emit_signal("pressed")
	await wait(4.2)
	await snap("g13_wheel")
	# play for ore
	hall.cur = "ore"
	hall.ore_kind = "coal"
	await hall._set_tab("flip")
	await wait(0.5)
	await snap("g14_flip_for_ore")
	for l in log_lines:
		print("RESULT ", l)
	print("GAMES DONE")
	quit()
