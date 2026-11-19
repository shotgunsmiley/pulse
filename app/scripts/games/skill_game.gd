extends VBoxContainer
# Plays one server-made skill challenge and reports the raw result.
# QUICKDRAW - reaction: tap the pad the moment it turns green (5 rounds).
# RUNE SEQUENCE - memory: watch the runes light up, repeat them; one more each round.
# VEIN SNIPER - precision: tap the glowing vein on a 4x4 grid before it fades (12 targets).
# The server scores everything, so the same challenge is fair for both duel players.

signal finished(result: Dictionary)

const UI = preload("res://scripts/ui.gd")
const MinePanel = preload("res://scripts/screens/mine_panel.gd")
const RUNE_KINDS := ["amber", "teal", "red", "void"]
const RUNE_TEXT := ["I", "II", "III", "IV"]

var M
var ch := {}
var info: Label
var area: VBoxContainer
var tap_flag := false
var tap_time := 0
var tap_index := -1
var accept_input := false
var aborted := false
var cid := ""          # server challenge id; Rune Sequence asks the server for each new round
var seq_runes := []    # the runes revealed so far (Rune Sequence)


func run(m, challenge: Dictionary, heading: String) -> void:
	M = m
	ch = challenge
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var head := UI.add_row(self)
	UI.add_label(head, heading, 26, UI.GOLD)
	var quit := UI.add_button(head, "QUIT", "red", 50, 18)
	quit.custom_minimum_size = Vector2(110, 50)
	quit.size_flags_horizontal = Control.SIZE_SHRINK_END
	quit.pressed.connect(_quit)
	info = UI.add_label(self, "", 24, UI.WHITE, true)
	area = VBoxContainer.new()
	area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(area)
	match str(ch.get("game", "")):
		"quickdraw":
			await _quickdraw()
		"sequence":
			await _sequence()
		"sniper":
			await _sniper()
		"strikeoff":
			await _strikeoff()


func _quit() -> void:
	aborted = true
	finished.emit({})


func _done(result: Dictionary) -> void:
	if not aborted:
		finished.emit(result)


func _wait_frames_until(deadline_ms: int) -> bool:
	# true if the player tapped before the deadline
	while Time.get_ticks_msec() < deadline_ms:
		await get_tree().process_frame
		if aborted:
			return false
		if tap_flag:
			return true
	return false


# ------------------------------------------------------------------ QUICKDRAW
func _quickdraw() -> void:
	var pad := UI.add_button(area, "GET READY", "stone", 460, 44)
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pad.button_down.connect(func():
		tap_flag = true
		tap_time = Time.get_ticks_msec()
	)
	var rounds := int(ch["rounds"])
	var delays: Array = ch["delays"]
	var reactions := []
	await get_tree().create_timer(1.0).timeout
	for i in range(rounds):
		if aborted:
			return
		info.text = "Round %d of %d - wait for GREEN" % [i + 1, rounds]
		UI.style_button(pad, "red")
		pad.text = "WAIT..."
		tap_flag = false
		var early: bool = await _wait_frames_until(Time.get_ticks_msec() + int(delays[i]))
		if aborted:
			return
		if early:
			reactions.append(-1)
			UI.style_button(pad, "stone")
			pad.text = "TOO EARLY!"
			M.play("buzz")
			M.vibrate(40)
			await get_tree().create_timer(1.0).timeout
			continue
		UI.style_button(pad, "green")
		pad.text = "STRIKE!"
		M.play("go")
		var go_t := Time.get_ticks_msec()
		tap_flag = false
		var hit: bool = await _wait_frames_until(go_t + 2900)
		if aborted:
			return
		UI.style_button(pad, "stone")
		if hit:
			var rt := tap_time - go_t
			if rt < 100:
				reactions.append(-1)
				pad.text = "TOO EARLY!"
			else:
				reactions.append(rt)
				pad.text = "%d ms" % rt
				M.play("clink")
		else:
			reactions.append(-1)
			pad.text = "TOO SLOW"
			M.play("buzz")
		await get_tree().create_timer(0.9).timeout
	_done({"reactions": reactions})


# ------------------------------------------------------------------ RUNE SEQUENCE
func _sequence() -> void:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	area.add_child(grid)
	var btns := []
	for i in range(4):
		var b := UI.add_button(grid, RUNE_TEXT[i], RUNE_KINDS[i], 200, 48)
		b.size_flags_vertical = Control.SIZE_EXPAND_FILL
		b.button_down.connect(func():
			if accept_input:
				tap_index = i
				tap_flag = true
		)
		btns.append(b)
	seq_runes = ch["runes"]
	var online: bool = cid != "" and ch.get("interactive", false)
	var show_s := float(ch["show_ms"]) / 1000.0
	var gap_s := float(ch["gap_ms"]) / 1000.0
	var n := int(ch["start_len"])
	var reached := 0
	await get_tree().create_timer(0.8).timeout
	while n <= seq_runes.size():
		if aborted:
			return
		accept_input = false
		info.text = "Watch %d runes..." % n
		await get_tree().create_timer(0.6).timeout
		for i in range(n):
			var r := int(seq_runes[i])
			btns[r].modulate = Color(1.9, 1.9, 1.9)
			M.play("rune%d" % r)
			await get_tree().create_timer(show_s).timeout
			btns[r].modulate = Color(1, 1, 1)
			await get_tree().create_timer(gap_s).timeout
		if aborted:
			return
		info.text = "Your turn - repeat all %d" % n
		accept_input = true
		var ok := true
		var entered := []
		for i in range(n):
			tap_flag = false
			tap_index = -1
			var tapped: bool = await _wait_frames_until(Time.get_ticks_msec() + 12000)
			if aborted:
				return
			if not tapped:
				ok = false
				break
			var pick := tap_index
			entered.append(pick)
			btns[pick].modulate = Color(1.6, 1.6, 1.6)
			M.play("rune%d" % pick)
			get_tree().create_timer(0.15).timeout.connect(func(): btns[pick].modulate = Color(1, 1, 1))
			if pick != int(seq_runes[i]):
				ok = false
				break
		accept_input = false
		if ok and online:
			# the server checks the answer and only then reveals the next, longer sequence
			info.text = "Checking..."
			var step: Dictionary = await M.api.post("/skill/step", {"id": cid, "entered": entered})
			if not step.get("ok", false) or not step.get("correct", false):
				ok = false
			elif step.get("done", false):
				reached = n
				break
			else:
				seq_runes = step["runes"]
		if not ok:
			info.text = "Wrong rune! You remembered %d." % reached
			M.play("buzz")
			M.vibrate(50)
			await get_tree().create_timer(1.0).timeout
			break
		reached = n
		M.play("coin")
		n += 1
	_done({"reached": reached})


# ------------------------------------------------------------------ VEIN SNIPER
func _sniper() -> void:
	var grid := GridContainer.new()
	grid.columns = 4
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	area.add_child(grid)
	var cells := []
	for i in range(16):
		var b := UI.add_button(grid, "", "stone", 120, 22)
		b.size_flags_vertical = Control.SIZE_EXPAND_FILL
		b.button_down.connect(func():
			if accept_input:
				tap_index = i
				tap_flag = true
				tap_time = Time.get_ticks_msec()
		)
		cells.append(b)
	var targets: Array = ch["targets"]
	var window := int(ch["window_ms"])
	var hits := []
	var score_hits := 0
	await get_tree().create_timer(0.8).timeout
	for i in range(targets.size()):
		if aborted:
			return
		info.text = "Target %d of %d - %d hits" % [i + 1, targets.size(), score_hits]
		accept_input = false
		await get_tree().create_timer(float(targets[i]["delay"]) / 1000.0).timeout
		if aborted:
			return
		var cell := int(targets[i]["cell"])
		UI.style_button(cells[cell], "teal")
		cells[cell].text = "VEIN"
		M.play("go")
		var t0 := Time.get_ticks_msec()
		tap_flag = false
		tap_index = -1
		accept_input = true
		var tapped: bool = await _wait_frames_until(t0 + window)
		accept_input = false
		if aborted:
			return
		UI.style_button(cells[cell], "stone")
		cells[cell].text = ""
		if tapped and tap_index == cell and tap_time - t0 >= 120:
			hits.append({"hit": true, "rt": tap_time - t0})
			score_hits += 1
			M.play("clink")
		else:
			hits.append({"hit": false, "rt": 0})
			if tapped:
				UI.style_button(cells[tap_index], "red")
				var miss_cell: Button = cells[tap_index]
				get_tree().create_timer(0.3).timeout.connect(func(): UI.style_button(miss_cell, "stone"))
			M.play("buzz")
	info.text = "%d of %d veins hit" % [score_hits, targets.size()]
	_done({"hits": hits})


# ------------------------------------------------------------------ STRIKE-OFF (mining race)
func _strikeoff() -> void:
	var strikes: Array = ch["strikes"]
	var limit := int(ch.get("limit_ms", 6000))
	var bar = MinePanel.StrikeBar.new()
	bar.custom_minimum_size = Vector2(0, 110)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(bar)
	var big := UI.add_button(area, "STRIKE", "amber", 300, 46)
	big.size_flags_vertical = Control.SIZE_EXPAND_FILL
	big.button_down.connect(func():
		tap_flag = true
		tap_time = Time.get_ticks_msec())
	var tally := UI.add_label(area, "", 22, UI.GOLD, true)
	var taps := []
	var points := 0
	await get_tree().create_timer(0.8).timeout
	for i in range(strikes.size()):
		if aborted:
			return
		info.text = "Strike %d of %d" % [i + 1, strikes.size()]
		bar.setup(strikes[i])
		var t0 := Time.get_ticks_msec()
		tap_flag = false
		var hit: bool = await _wait_frames_until(t0 + limit)
		if aborted:
			return
		var tap := clampi((tap_time - t0) if hit else limit, 150, limit)
		while hit and tap_time - t0 < 150:
			tap_flag = false
			hit = await _wait_frames_until(t0 + limit)
			tap = clampi((tap_time - t0) if hit else limit, 150, limit)
		taps.append(tap)
		var q := quality_of(strikes[i], tap)
		bar.frozen = bar.pos_at(float(tap))
		bar.result_q = q
		points += {"perfect": 100, "great": 70, "good": 40}.get(q, 0)
		tally.text = "%s!   %d pts" % [q.to_upper(), points]
		M.play("clink" if q != "miss" else "thud")
		M.vibrate(25 if q == "perfect" else 12)
		await get_tree().create_timer(0.45).timeout
	_done({"taps": taps})


static func marker(s: Dictionary, t_ms: float) -> float:
	var phase := fposmod(t_ms / 1000.0 * float(s["speed"]) + float(s["offset"]), 2.0)
	return phase if phase <= 1.0 else 2.0 - phase


static func quality_of(s: Dictionary, tap: int) -> String:
	var d := absf(marker(s, float(tap)) - float(s["zone_center"]))
	var half := float(s["zone_width"]) / 2.0
	if d <= half * 0.3:
		return "perfect"
	if d <= half * 0.65:
		return "great"
	if d <= half:
		return "good"
	return "miss"


# Offline practice: build a challenge on the phone (same shapes as the server's).
static func local_challenge(game: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	match game:
		"quickdraw":
			var d := []
			for i in range(5):
				d.append(rng.randi_range(1200, 3600))
			return {"game": game, "rounds": 5, "delays": d}
		"sequence":
			var runes := []
			for i in range(20):
				runes.append(rng.randi_range(0, 3))
			return {"game": game, "runes": runes, "start_len": 3, "show_ms": 450, "gap_ms": 150}
		"sniper":
			var t := []
			for i in range(12):
				t.append({"cell": rng.randi_range(0, 15), "delay": rng.randi_range(400, 1400)})
			return {"game": game, "grid": 4, "targets": t, "window_ms": 1200}
		_:
			var st := []
			for i in range(10):
				var zone := 0.22 - i * 0.01
				st.append({"speed": 0.6 + i * 0.07, "offset": rng.randf(), "zone_center": rng.randf_range(zone / 2 + 0.05, 1 - zone / 2 - 0.05), "zone_width": zone})
			return {"game": "strikeoff", "strikes": st, "limit_ms": 6000}


static func local_score(c: Dictionary, result: Dictionary) -> int:
	match str(c.get("game", "")):
		"quickdraw":
			var total := 0
			for rt in result.get("reactions", []):
				if int(rt) > 0:
					total += maxi(0, 500 - int(rt))
			return total
		"sequence":
			return int(result.get("reached", 0)) * 100
		"sniper":
			var total2 := 0
			for h in result.get("hits", []):
				if h.get("hit", false):
					total2 += maxi(0, 100 - maxi(0, int(h.get("rt", 0)) - 220) / 7)
			return total2
		_:
			var pts := 0
			var used := 0
			var strikes: Array = c["strikes"]
			var taps: Array = result.get("taps", [])
			for i in range(mini(strikes.size(), taps.size())):
				pts += {"perfect": 100, "great": 70, "good": 40}.get(quality_of(strikes[i], int(taps[i])), 0)
				used += int(taps[i])
			return pts * 10 + maxi(0, 99 - used / 1000)
