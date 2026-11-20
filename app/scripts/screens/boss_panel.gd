extends VBoxContainer
# v5.5 WORLD BOSS - the fight panel (covers the bottom half; the monster stays in view above).
# Everyone in the game fights the same monster and shares its health. Use the strike bar
# like mining: gold = perfect, bright teal = great, dark teal = good. Each monster has a
# trick (shown here as it happens). Loot is ore, xp, gems and badges - never PLS.

const UI = preload("res://scripts/ui.gd")
const MinePanel = preload("res://scripts/screens/mine_panel.gd")

var M
var bar
var strike_btn: Button
var title: Label
var clock: Label
var hp_bar: ProgressBar
var hp_label: Label
var trick: Label
var result: Label
var me_label: Label
var top_label: Label
var leave_btn: Button
var active := false
var busy := false
var gen := 0
var challenge_id := ""
var hp_col := Color("#d84a3a")
var last_state := ""
var tick := 0.0
var hits := {"strikes": 0, "perfect": 0}


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	var top := UI.add_row(self)
	title = UI.add_label(top, "", 26, UI.GOLD)
	clock = UI.add_label(top, "", 20, UI.MUTED)
	clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hp_bar = UI.add_bar(self, 1.0, hp_col, 22)
	hp_label = UI.add_label(self, "", 17, UI.WHITE, true)
	trick = UI.add_label(self, "", 18, UI.AMBER, true)
	trick.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bar = MinePanel.StrikeBar.new()
	bar.custom_minimum_size = Vector2(0, 66)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)
	strike_btn = UI.add_button(self, "STRIKE", "red", 88, 36)
	strike_btn.button_down.connect(_on_strike)
	result = UI.add_label(self, "", 20, UI.WHITE, true)
	var r := UI.add_row(self, 6)
	me_label = UI.add_label(r, "", 18, UI.TEAL_L)
	leave_btn = UI.add_button(r, "TOWN", "stone", 44, 17)
	leave_btn.custom_minimum_size = Vector2(130, 44)
	leave_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	leave_btn.pressed.connect(func(): M.go("town"))
	top_label = UI.add_label(self, "", 17, UI.MUTED)
	top_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func on_open() -> void:
	active = true
	hits = {"strikes": 0, "perfect": 0}
	M.world.boss_focus = true
	M.audio.set_area("boss" if str(M.boss.get("state", "")) in ["countdown", "live"] else "town")
	result.text = ""
	bar.setup({})
	_render(M.boss)
	if M.world.area == "town" and str(M.boss.get("state", "")) in ["countdown", "live"]:
		M.world.walk_to(M.world.boss_spot(), "boss")
	if str(M.boss.get("state", "")) == "live":
		_new_challenge()
	M.poll_boss_soon()


func on_close() -> void:
	active = false
	challenge_id = ""
	gen += 1
	bar.setup({})
	M.world.boss_focus = false
	M.audio.set_area("town" if M.world.area == "town" else M.world.area)
	if int(hits["strikes"]) >= 5:
		M.log_msg("Fight: %d strikes, %d perfect." % [hits["strikes"], hits["perfect"]], UI.TEAL_L)


func _process(delta: float) -> void:
	if not active:
		return
	tick += delta
	if tick >= 0.25:
		tick = 0.0
		_clock()


# The countdown and the fight clock tick locally between server answers.
func _clock() -> void:
	var v: Dictionary = M.boss
	var age := (Time.get_ticks_msec() - int(M.boss_at_ms)) / 1000.0
	match str(v.get("state", "")):
		"countdown":
			var left := maxf(0.0, float(v.get("spawn_in", 0)) - age)
			clock.text = "arrives in %s" % _mmss(left)
		"live":
			var left2 := maxf(0.0, float(v.get("time_left", 0)) - age)
			clock.text = "%s left" % _mmss(left2)
			clock.add_theme_color_override("font_color", UI.RED if left2 < 60.0 else UI.MUTED)
		_:
			var nxt: Dictionary = v.get("next", {})
			clock.text = ("next in %s" % _mmss(maxf(0.0, float(nxt.get("in_s", 0)) - age))) if not nxt.is_empty() else ""


static func _mmss(s: float) -> String:
	var t := int(s)
	if t >= 3600:
		return "%d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60]
	return "%d:%02d" % [t / 60, t % 60]


# Called by main.gd with every fresh /boss answer (polls and strike replies).
func on_view(v: Dictionary) -> void:
	if not active:
		return
	var was := last_state
	_render(v)
	var st := str(v.get("state", ""))
	if st == "live" and was == "countdown":
		M.audio.set_area("boss")
		_new_challenge()
	elif st != "live":
		challenge_id = ""
		bar.setup({})


func _render(v: Dictionary) -> void:
	var st := str(v.get("state", "idle"))
	last_state = st
	var monsters: Dictionary = v.get("monsters", M.boss_book)
	var mname := str(v.get("name", ""))
	var hp := float(v.get("hp", 0))
	var mx := maxf(1.0, float(v.get("max_hp", 1)))
	title.add_theme_color_override("font_color", UI.GOLD)
	strike_btn.visible = st == "live"
	bar.visible = st == "live"
	hp_bar.visible = st in ["live", "won", "escaped"]
	hp_label.visible = hp_bar.visible
	match st:
		"countdown":
			title.text = mname.to_upper()
			trick.text = "Its trick: " + str(v.get("trick", ""))
			var loot: Dictionary = monsters.get(str(v.get("monster", "")), {}).get("loot", {})
			result.text = "Get ready! Loot: %s, xp and a chance of a gem." % _ore_list(loot)
			result.add_theme_color_override("font_color", UI.WHITE)
			me_label.text = _book_line(str(v.get("monster", "")))
		"live":
			title.text = mname.to_upper()
			hp_bar.value = hp / mx
			hp_label.text = "%s / %s health   -   %d fighting" % [UI.n(int(hp)), UI.n(int(mx)), int(v.get("fighting_now", 0))]
			trick.text = _trick_now(v)
			var me: Dictionary = v.get("me", {})
			var rank = me.get("rank")
			me_label.text = "Your damage: %s%s" % [UI.n(me.get("dmg", 0)), ("  (#%d)" % int(rank)) if rank != null else ""]
		"won", "escaped":
			title.text = mname.to_upper() + ("  DEFEATED!" if st == "won" else "  GOT AWAY")
			title.add_theme_color_override("font_color", UI.GOLD if st == "won" else UI.MUTED)
			hp_bar.value = hp / mx
			hp_label.text = "%d miners fought" % int(v.get("fighters", 0))
			trick.text = ""
			var me2: Dictionary = v.get("me", {})
			me_label.text = "Your damage: %s" % UI.n(me2.get("dmg", 0))
			result.text = "Well fought, everyone!" if st == "won" else "Time ran out. It will be back..."
			result.add_theme_color_override("font_color", UI.GOLD if st == "won" else UI.MUTED)
		_:
			var nxt: Dictionary = v.get("next", {})
			title.text = "THE TOWN SQUARE"
			title.add_theme_color_override("font_color", UI.GOLD)
			trick.text = ("Next monster: %s" % str(nxt.get("name", "?"))) if not nxt.is_empty() else ""
			result.text = "No monster right now. You'll get a 3-minute warning before one comes."
			result.add_theme_color_override("font_color", UI.MUTED)
			me_label.text = _book_line(str(nxt.get("monster", "")))
	var rows := []
	var i := 1
	for row in v.get("top", []):
		rows.append("%d. %s %s" % [i, str(row.get("username", "?")), UI.n(row.get("dmg", 0))])
		i += 1
	top_label.text = ("Top: " + "   ".join(PackedStringArray(rows))) if rows.size() > 0 else ""
	_clock()


func _trick_now(v: Dictionary) -> String:
	var tr: Dictionary = v.get("tricks", {})
	trick.add_theme_color_override("font_color", UI.AMBER)
	if tr.has("hardened"):
		trick.add_theme_color_override("font_color", Color("#d8e6f0"))
		return "STONE SKIN %ds - only PERFECT hits get through!" % int(ceil(float(tr["hardened"])))
	if tr.has("burrowed"):
		trick.add_theme_color_override("font_color", Color("#c89a5a"))
		return "UNDERGROUND %ds - wait for it to surface!" % int(ceil(float(tr["burrowed"])))
	var bits := []
	if tr.has("shield"):
		bits.append("FIRE SHIELD %ds - half damage" % int(ceil(float(tr["shield"]))))
	if tr.has("enraged"):
		bits.append("ENRAGED - it takes 50% more!")
	if bits.size() > 0:
		trick.add_theme_color_override("font_color", Color("#ff9a5a"))
		return "   ".join(PackedStringArray(bits))
	return str(v.get("trick", ""))


func _ore_list(loot: Dictionary) -> String:
	var parts := []
	for k in loot.keys():
		parts.append(UI.ore_name(str(k)).to_lower())
	return ", ".join(PackedStringArray(parts)) if parts.size() > 0 else "ore"


func _book_line(mon: String) -> String:
	var b: Dictionary = M.bestiary.get(mon, {})
	if b.is_empty():
		return "Never fought one yet."
	return "Bestiary: %d killed, %d got away, best hit total %s" % [int(b.get("kills", 0)), int(b.get("escapes", 0)), UI.n(b.get("best_dmg", 0))]


# ------------------------------------------------------------------ fighting
func _new_challenge() -> void:
	if not active:
		return
	gen += 1
	var my_gen := gen
	challenge_id = ""
	var r: Dictionary = await M.api.post("/boss/start", {})
	if not active or my_gen != gen:
		return
	if not r.get("ok", false):
		if str(r.get("error", "")) != "no_boss":
			M.error_toast(r)
		M.poll_boss_soon()
		return
	challenge_id = str(r["id"])
	bar.setup(r["challenge"])
	strike_btn.disabled = false
	if r.has("boss"):
		M.on_boss_view(r["boss"])
	await get_tree().create_timer(8.0).timeout
	if active and my_gen == gen and challenge_id != "" and not busy:
		_new_challenge()


func _on_strike() -> void:
	if busy or not active or str(M.boss.get("state", "")) != "live":
		return
	if challenge_id == "":
		_new_challenge()
		return
	var tap: int = bar.elapsed()
	if tap < 160:
		return
	busy = true
	strike_btn.disabled = true
	bar.frozen = bar.pos_at(float(tap))
	var cid := challenge_id
	challenge_id = ""
	gen += 1
	M.world.hero.swing()
	M.play("clink", 0.8)
	var r: Dictionary = await M.api.post("/boss/strike", {"id": cid, "tap_ms": tap})
	busy = false
	if not active:
		return
	if not r.get("ok", false):
		if str(r.get("error", "")) not in ["too_fast", "no_boss"]:
			M.error_toast(r)
		M.poll_boss_soon()
		await get_tree().create_timer(0.5).timeout
		_new_challenge()
		return
	if r.has("boss"):
		M.on_boss_view(r["boss"])
	_show_result(r)
	if r.get("killed", false):
		return
	await get_tree().create_timer(0.55).timeout
	if str(M.boss.get("state", "")) == "live":
		_new_challenge()


func _show_result(r: Dictionary) -> void:
	var q := str(r.get("quality", "miss"))
	var dmg := int(r.get("damage", 0))
	var note := str(r.get("note", ""))
	bar.result_q = q
	hits["strikes"] = int(hits["strikes"]) + 1
	if q == "perfect":
		hits["perfect"] = int(hits["perfect"]) + 1
	M.apply({"xp": r.get("xp", M.profile.get("xp", 0))})
	M.world.boss_hit(q, dmg, note)
	if r.get("flagged", false) and not M.profile.get("flagged", false):
		M.profile["flagged"] = true
		M.toast("Your account is under review: your tapping looked automated.", UI.RED)
	var colors := {"perfect": UI.GOLD, "great": UI.TEAL_L, "good": UI.TEAL, "miss": UI.RED}
	if q == "miss":
		result.text = "MISS!" + ("  " + note if note != "" else "")
		M.play("thud")
		M.vibrate(15)
		M.world.hero.stumble()
	elif dmg <= 0:
		result.text = note if note != "" else "No damage!"
		M.play("anvil", 1.4)
		M.vibrate(10)
	else:
		result.text = "%s!  %d damage%s" % [q.to_upper(), dmg, ("   " + note) if note != "" else ""]
		M.play("mhit", {"perfect": 1.15, "great": 1.0, "good": 0.9}.get(q, 1.0))
		M.vibrate_pattern(q)
	result.add_theme_color_override("font_color", colors.get(q, UI.WHITE) if dmg > 0 or q == "miss" else Color("#d8e6f0"))
	if r.get("killed", false):
		result.text = "FINAL BLOW!  The %s falls!" % str(M.boss.get("name", "monster"))
		result.add_theme_color_override("font_color", UI.GOLD)
	if r.get("reward") != null and typeof(r["reward"]) == TYPE_DICTIONARY:
		M.show_boss_reward(r["reward"])
