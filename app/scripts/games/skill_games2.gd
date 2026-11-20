extends RefCounted
# v5.4 skill games: Forge Tempo, Cart Run, Ore Sort, Crate Stack.
# Each one mirrors the server's maths exactly (server/d8_games.py), so what you see is
# what the server scores. Each play_* function runs inside SkillGame (sg) and returns the
# result dictionary the server expects.

const UI = preload("res://scripts/ui.gd")
const ORE_COL := [Color("#3a3634"), Color("#b0683e"), Color("#3fd0bd"), Color("#9a6ae0")]
const ORE_NAME := ["COAL", "IRON", "CRYSTAL", "VOID"]


# ================================================================== FORGE TEMPO
class TempoLane extends Control:
	var beats: Array = []
	var t0 := 0
	var hit_x := 0.18
	var px_per_ms := 0.32
	var flash := 0.0
	var flash_col := Color.WHITE
	var judged := {}     # beat index -> quality

	func _process(d: float) -> void:
		flash = maxf(0.0, flash - d * 3.0)
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0, 0, w, h), Color("#1a1512"))
		draw_rect(Rect2(0, h * 0.35, w, h * 0.3), Color("#2b2420"))
		var hx := w * hit_x
		# the anvil at the hit line
		draw_rect(Rect2(hx - 34, h * 0.62, 68, 22), Color("#55524c"))
		draw_rect(Rect2(hx - 18, h * 0.62 + 22, 36, 26), Color("#3f3c38"))
		draw_rect(Rect2(hx - 4, h * 0.2, 8, h * 0.6), Color("#ffd36b") if flash > 0 else Color("#7a6a50"))
		if flash > 0:
			draw_circle(Vector2(hx, h * 0.5), 46 * flash, Color(flash_col.r, flash_col.g, flash_col.b, flash * 0.5))
		var now := Time.get_ticks_msec() - t0
		for i in range(beats.size()):
			var dt := float(beats[i]) - now
			var x := hx + dt * px_per_ms
			if x < -30 or x > w + 30:
				continue
			var q: String = judged.get(i, "")
			var col: Color = Color("#ff9a40") if q == "" else ({"perfect": Color("#ffd36b"), "great": Color("#7fe3d3"), "good": Color("#2A9D8F"), "miss": Color("#5a3a30")}[q])
			# a glowing ingot on its way to the anvil
			draw_rect(Rect2(x - 20, h * 0.5 - 12, 40, 24), col)
			draw_rect(Rect2(x - 20, h * 0.5 - 12, 40, 6), col.lightened(0.35))


static func play_tempo(sg) -> Dictionary:
	var ch: Dictionary = sg.ch
	var beats: Array = ch["beats"]
	var wins: Array = ch["windows"]
	var lane := TempoLane.new()
	lane.beats = beats
	lane.custom_minimum_size = Vector2(0, 260)
	lane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lane.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sg.area.add_child(lane)
	var tally := UI.add_label(sg.area, "Hammer when an ingot reaches the anvil.", 22, UI.GOLD, true)
	var taps := []
	var used := {}
	var pts := [0, 0]     # points, combo
	var hammer := UI.add_button(sg.area, "HAMMER", "amber", 300, 44)
	hammer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lane.t0 = Time.get_ticks_msec()
	hammer.button_down.connect(func():
		var t := Time.get_ticks_msec() - lane.t0
		taps.append(t)
		sg.M.play("anvil", randf_range(0.95, 1.05))
		# judge against the nearest unjudged beat (same windows as the server)
		var best := -1
		var bd := 99999
		for i in range(beats.size()):
			if used.has(i):
				continue
			var dd := absi(int(beats[i]) - t)
			if dd < bd:
				bd = dd
				best = i
		if best >= 0 and bd <= int(wins[2]):
			used[best] = true
			var q := "perfect" if bd <= int(wins[0]) else ("great" if bd <= int(wins[1]) else "good")
			lane.judged[best] = q
			pts[1] += 1
			pts[0] += {"perfect": 100, "great": 60, "good": 30}[q] + mini(50, pts[1] * 2)
			lane.flash = 1.0
			lane.flash_col = {"perfect": UI.GOLD, "great": UI.TEAL_L, "good": UI.TEAL}[q]
			tally.text = "%s!  combo %d  -  %d pts" % [q.to_upper(), pts[1], pts[0]]
			sg.M.vibrate(25 if q == "perfect" else 12)
		else:
			pts[1] = 0
			pts[0] = maxi(0, pts[0] - 15)
			tally.text = "Off the beat!  -  %d pts" % pts[0]
	)
	# a soft tick on every beat helps you feel the rhythm
	var next_tick := 0
	var end_t := int(beats[beats.size() - 1]) + 900
	while Time.get_ticks_msec() - lane.t0 < end_t:
		await sg.get_tree().process_frame
		if sg.aborted:
			return {}
		var now := Time.get_ticks_msec() - lane.t0
		while next_tick < beats.size() and now >= int(beats[next_tick]):
			sg.M.play("click", 1.4)
			next_tick += 1
		for i in range(beats.size()):
			if not used.has(i) and not lane.judged.has(i) and now - int(beats[i]) > int(wins[2]):
				lane.judged[i] = "miss"
				pts[1] = 0
		sg.info.text = "Beat %d of %d" % [mini(next_tick + 1, beats.size()), beats.size()]
	hammer.disabled = true
	return {"taps": taps}


# ================================================================== CART RUN
class CartTrack extends Control:
	var ch: Dictionary = {}
	var t0 := 0
	var lane := 1
	var crashed := false
	var got_gems := {}

	func vis_of(i: int) -> float:
		return maxf(float(ch["min_visible_ms"]), float(ch["visible_ms"]) - i * float(ch.get("vis_step", 8)))

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0, 0, w, h), Color("#1e1712"))
		var lw := w / 3.0
		var now := float(Time.get_ticks_msec() - t0)
		for l in range(3):
			var cx := lw * (l + 0.5)
			draw_rect(Rect2(cx - 22, 0, 6, h), Color("#5a4632"))
			draw_rect(Rect2(cx + 16, 0, 6, h), Color("#5a4632"))
			var off := fposmod(now * 0.25, 40.0)
			var y := -40.0 + off
			while y < h:
				draw_rect(Rect2(cx - 30, y, 60, 8), Color("#3f2e1f"))
				y += 40
		var cart_y := h - 70
		var obs: Array = ch["obstacles"]
		for i in range(obs.size()):
			var o: Dictionary = obs[i]
			var dt := float(o["t"]) - now
			var vis := vis_of(i)
			if dt > vis or dt < -300:
				continue
			var y := cart_y - dt / vis * (cart_y - 20)
			for l in o["lanes"]:
				var cx := lw * (int(l) + 0.5)
				draw_rect(Rect2(cx - 30, y - 26, 60, 48), Color("#6a6058"))
				draw_rect(Rect2(cx - 30, y - 26, 60, 12), Color("#8a8078"))
		var gems: Array = ch["gems"]
		for k in range(gems.size()):
			if got_gems.has(k):
				continue
			var g: Dictionary = gems[k]
			var dt2 := float(g["t"]) - now
			if dt2 > 1300 or dt2 < -300:
				continue
			var y2 := cart_y - dt2 / 1300.0 * (cart_y - 20)
			var cx2 := lw * (int(g["lane"]) + 0.5)
			draw_colored_polygon(PackedVector2Array([Vector2(cx2, y2 - 16), Vector2(cx2 + 14, y2), Vector2(cx2, y2 + 16), Vector2(cx2 - 14, y2)]), Color("#3fd0bd"))
		# the cart
		var ccx := lw * (lane + 0.5)
		draw_rect(Rect2(ccx - 34, cart_y - 18, 68, 40), Color("#c04a2a") if crashed else Color("#7a5236"))
		draw_rect(Rect2(ccx - 34, cart_y - 18, 68, 8), Color("#a8552a"))
		draw_circle(Vector2(ccx - 20, cart_y + 24), 9, Color("#2a2420"))
		draw_circle(Vector2(ccx + 20, cart_y + 24), 9, Color("#2a2420"))


static func play_cartrun(sg) -> Dictionary:
	var ch: Dictionary = sg.ch
	# JSON numbers arrive as floats; lanes must be ints so "is my lane blocked" compares correctly
	for o in ch["obstacles"]:
		var ints := []
		for l in o["lanes"]:
			ints.append(int(l))
		o["lanes"] = ints
	var track := CartTrack.new()
	track.ch = ch
	track.lane = int(ch["start_lane"])
	track.custom_minimum_size = Vector2(0, 520)
	track.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	track.size_flags_vertical = Control.SIZE_EXPAND_FILL
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sg.area.add_child(track)
	var row := UI.add_row(sg.area, 8)
	var left := UI.add_button(row, "<  LEFT", "teal", 120, 30)
	var right := UI.add_button(row, "RIGHT  >", "teal", 120, 30)
	var moves := []
	var last := [-1000]
	track.t0 = Time.get_ticks_msec()
	var go := func(dir: int):
		if track.crashed:
			return
		var t := Time.get_ticks_msec() - track.t0
		var nl := clampi(track.lane + dir, 0, 2)
		if nl == track.lane or t - int(last[0]) < 95:
			return
		track.lane = nl
		moves.append([t, nl])
		last[0] = t
		sg.M.play("click", 1.2)
	left.button_down.connect(func(): go.call(-1))
	right.button_down.connect(func(): go.call(1))
	var obs: Array = ch["obstacles"]
	var gems: Array = ch["gems"]
	var next_o := 0
	var passed := 0
	var gem_n := 0
	while next_o < obs.size():
		await sg.get_tree().process_frame
		if sg.aborted:
			return {}
		var now := Time.get_ticks_msec() - track.t0
		for k in range(gems.size()):
			if not track.got_gems.has(k) and now >= int(gems[k]["t"]) and now - int(gems[k]["t"]) < 200:
				if int(gems[k]["lane"]) == track.lane:
					track.got_gems[k] = true
					gem_n += 1
					sg.M.play("coin", 1.3)
				else:
					track.got_gems[k] = true          # passed by
		while next_o < obs.size() and now >= int(obs[next_o]["t"]):
			if track.lane in obs[next_o]["lanes"]:
				track.crashed = true
				break
			passed += 1
			next_o += 1
		if track.crashed:
			break
		sg.info.text = "%d rocks dodged  -  %d gems" % [passed, gem_n]
	left.disabled = true
	right.disabled = true
	if track.crashed:
		sg.M.play("boom")
		sg.M.vibrate(150)
		sg.info.text = "CRASH! %d rocks dodged, %d gems" % [passed, gem_n]
	else:
		sg.M.play("win")
		sg.info.text = "THE WHOLE TRACK! %d gems" % gem_n
	await sg.get_tree().create_timer(1.2).timeout
	return {"moves": moves}


# ================================================================== ORE SORT
static func play_oresort(sg) -> Dictionary:
	var ch: Dictionary = sg.ch
	var items: Array = ch["items"]
	var lives := int(ch["lives"])
	var big := Label.new()
	big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	big.custom_minimum_size = Vector2(0, 200)
	big.add_theme_font_size_override("font_size", 64)
	big.add_theme_color_override("font_outline_color", Color.BLACK)
	big.add_theme_constant_override("outline_size", 12)
	var panel := PanelContainer.new()
	panel.add_child(big)
	sg.area.add_child(panel)
	var timer := UI.add_bar(sg.area, 1.0, UI.AMBER, 16)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	sg.area.add_child(grid)
	var btns := []
	var pick := [-2, 0]     # choice, time
	for k in range(4):
		var b := UI.add_button(grid, ORE_NAME[k] + " BIN", "stone", 120, 26)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.size_flags_vertical = Control.SIZE_EXPAND_FILL
		b.add_theme_stylebox_override("normal", UI.box(ORE_COL[k].darkened(0.2), UI.AMBER, 3))
		var kk := k
		b.button_down.connect(func():
			if pick[0] == -3:
				pick[0] = kk
				pick[1] = Time.get_ticks_msec())
		btns.append(b)
	var answers := []
	var pts := 0
	var streak := 0
	await sg.get_tree().create_timer(0.8).timeout
	for i in range(items.size()):
		if lives <= 0 or sg.aborted:
			break
		var it: Dictionary = items[i]
		var kinds := 2 if i < 10 else (3 if i < 20 else 4)
		for k in range(4):
			btns[k].disabled = k >= kinds
		big.text = ORE_NAME[int(it["ore"])]
		big.add_theme_color_override("font_color", ORE_COL[int(it["ore"])].lightened(0.35))
		var limit := int(it["limit"])
		var t0 := Time.get_ticks_msec()
		pick[0] = -3
		while pick[0] == -3 and Time.get_ticks_msec() - t0 < limit:
			timer.value = 1.0 - float(Time.get_ticks_msec() - t0) / float(limit)
			await sg.get_tree().process_frame
			if sg.aborted:
				return {}
		var choice := int(pick[0])
		var rt := int(pick[1]) - t0 if choice >= 0 else limit
		if choice >= 0 and rt < 200:
			rt = 200       # nobody sorts faster than they can see (the server agrees)
		if choice == -3:
			choice = -1
		answers.append([choice, rt])
		if choice == int(it["ore"]):
			streak += 1
			pts += 50 + int(50.0 * (limit - rt) / float(limit)) + mini(50, streak * 5)
			sg.M.play("clink", 1.0 + mini(streak, 10) * 0.04)
		else:
			streak = 0
			lives -= 1
			sg.M.play("buzz")
			sg.M.vibrate(60)
		sg.info.text = "%d pts  -  streak %d  -  lives %s" % [pts, streak, "*".repeat(lives)]
		big.text = ""
		await sg.get_tree().create_timer(0.26).timeout
	for b in btns:
		b.disabled = true
	return {"answers": answers}


# ================================================================== CRATE STACK
class StackView extends Control:
	var placed: Array = []      # [x, w] for each crate on the tower (fractions of the width)
	var cur_x := 0.0
	var cur_w := 0.5
	var swinging := true
	var drop_y := 0.0

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0, 0, w, h), Color("#1a2230"))
		var ch_h := 34.0
		var show := mini(placed.size(), int((h - 160) / ch_h))
		var base_y := h - 30
		draw_rect(Rect2(0, base_y, w, 30), Color("#4a3d30"))
		var first := placed.size() - show
		for i in range(first, placed.size()):
			var c: Array = placed[i]
			var y := base_y - (i - first + 1) * ch_h
			draw_rect(Rect2(float(c[0]) * w, y, float(c[1]) * w, ch_h - 2), Color("#8a5c34"))
			draw_rect(Rect2(float(c[0]) * w, y, float(c[1]) * w, 6), Color("#a8763e"))
		var top_y := base_y - (show + 1) * ch_h
		var cy := top_y - 60 + drop_y
		draw_line(Vector2(cur_x * w + cur_w * w / 2, 0), Vector2(cur_x * w + cur_w * w / 2, cy), Color("#7a6a50"), 2.0)
		draw_rect(Rect2(cur_x * w, cy, cur_w * w, ch_h - 2), Color("#c8963e"))
		draw_rect(Rect2(cur_x * w, cy, cur_w * w, 6), Color("#e8b860"))


static func tri(phase: float) -> float:
	var p := fposmod(phase, 2.0)
	return p if p <= 1.0 else 2.0 - p


static func play_stack(sg) -> Dictionary:
	var ch: Dictionary = sg.ch
	var levels: Array = ch["levels"]
	var view := StackView.new()
	view.custom_minimum_size = Vector2(0, 520)
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sg.area.add_child(view)
	var drop := UI.add_button(sg.area, "DROP", "amber", 120, 40)
	var tapped := [false, 0]
	drop.button_down.connect(func():
		tapped[0] = true
		tapped[1] = Time.get_ticks_msec())
	var w := float(ch["width"])
	var prev_x := (1.0 - w) / 2.0
	var prev_w := w
	view.placed.append([prev_x, prev_w])
	var taps := []
	var height := 0
	var perfects := 0
	await sg.get_tree().create_timer(0.6).timeout
	for i in range(levels.size()):
		if sg.aborted:
			return {}
		var lv: Dictionary = levels[i]
		var t0 := Time.get_ticks_msec()
		tapped[0] = false
		view.cur_w = w
		view.drop_y = 0.0
		while not tapped[0] and Time.get_ticks_msec() - t0 < 9000:
			view.cur_x = tri((Time.get_ticks_msec() - t0) / 1000.0 * float(lv["speed"]) + float(lv["offset"])) * (1.0 - w)
			await sg.get_tree().process_frame
			if sg.aborted:
				return {}
		var tap := clampi((int(tapped[1]) - t0) if tapped[0] else 9000, 150, 9000)
		taps.append(tap)
		var x := tri(tap / 1000.0 * float(lv["speed"]) + float(lv["offset"])) * (1.0 - w)
		view.cur_x = x
		# the same rule as the server: close enough is a perfect drop, otherwise only the overlap stays
		var new_w := w
		var perfect := absf(x - prev_x) <= float(ch["perfect"])
		if perfect:
			x = prev_x
			perfects += 1
		else:
			var left := maxf(x, prev_x)
			var right := minf(x + w, prev_x + prev_w)
			new_w = right - left
			x = left
		var tw := view.create_tween()
		tw.tween_property(view, "drop_y", 60.0, 0.18)
		await tw.finished
		if new_w <= 0.004:
			sg.M.play("thud")
			sg.M.vibrate(120)
			sg.info.text = "It fell! %d crates high, %d perfect" % [height, perfects]
			break
		height += 1
		view.placed.append([x, new_w])
		prev_x = x
		prev_w = new_w
		w = new_w
		sg.M.play("clink" if not perfect else "coin", 1.0 + mini(height, 20) * 0.02)
		sg.info.text = "%s  %d high  -  %d perfect" % ["PERFECT!" if perfect else "", height, perfects]
		await sg.get_tree().create_timer(0.12).timeout
	drop.disabled = true
	await sg.get_tree().create_timer(0.8).timeout
	return {"taps": taps}


# ================================================================== offline practice
static func local_challenge(game: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	match game:
		"tempo":
			var t := 1600.0
			var beats := []
			for i in range(28):
				var step := 60000.0 / (84.0 + 66.0 * i / 27.0)
				if i > 6 and rng.randf() < 0.15:
					step *= 2
				t += step
				beats.append(int(t))
			return {"game": game, "beats": beats, "windows": [45, 90, 150]}
		"cartrun":
			var t2 := 1800.0
			var obs := []
			var gems := []
			for i in range(60):
				var gap := maxf(520.0, 1300.0 - i * 14.0)
				t2 += gap
				var lanes := [rng.randi_range(0, 2)]
				if i >= 15 and rng.randf() < 0.25:
					lanes.append((int(lanes[0]) + rng.randi_range(1, 2)) % 3)
				lanes.sort()
				obs.append({"t": int(t2), "lanes": lanes})
				if rng.randf() < 0.4:
					gems.append({"t": int(t2 + gap / 2), "lane": rng.randi_range(0, 2)})
			return {"game": game, "lanes": 3, "start_lane": 1, "obstacles": obs, "gems": gems, "visible_ms": 1400, "min_visible_ms": 700, "vis_step": 12}
		"oresort":
			var items := []
			for i in range(32):
				var kinds := 2 if i < 10 else (3 if i < 20 else 4)
				items.append({"ore": rng.randi_range(0, kinds - 1), "limit": int(maxf(900, 2600 - i * 55))})
			return {"game": game, "items": items, "bins": ["coal", "iron", "crystal", "void"], "lives": 3}
		_:
			var levels := []
			for i in range(40):
				levels.append({"speed": 0.45 + i * 0.03, "offset": rng.randf() * 2.0})
			return {"game": "stack", "levels": levels, "width": 0.5, "perfect": 0.012}
