extends VBoxContainer
# THE DEEP VEINS - skill mining.
# A marker sweeps the strike bar. Tap STRIKE while it is inside the zone:
# gold = perfect, bright teal = great, dark teal = good, outside = miss.
# Each vein has health. Ore and XP come from every good hit; while you mine, your phone also
# works as a network node, and node time is what earns new PLS (paid every 10 minutes).

const UI = preload("res://scripts/ui.gd")

class StrikeBar extends Control:
	var ch := {}
	var t0 := 0
	var frozen := -1.0
	var result_q := ""

	func setup(c: Dictionary) -> void:
		ch = c
		t0 = Time.get_ticks_msec()
		frozen = -1.0
		result_q = ""

	func elapsed() -> int:
		return Time.get_ticks_msec() - t0

	func pos_at(t_ms: float) -> float:
		if ch.is_empty():
			return 0.0
		var phase := fposmod(t_ms / 1000.0 * float(ch["speed"]) + float(ch["offset"]), 2.0)
		return phase if phase <= 1.0 else 2.0 - phase

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0, 0, w, h), Color("#141518"))
		draw_rect(Rect2(4, 4, w - 8, h - 8), Color("#2b2724"))
		if ch.is_empty():
			return
		var c := float(ch["zone_center"])
		var z := float(ch["zone_width"])
		var bands := [[1.0, Color("#16655c")], [0.65, Color("#2A9D8F")], [0.3, Color("#FFC93C")]]
		for band in bands:
			var half: float = z / 2.0 * float(band[0])
			draw_rect(Rect2(4 + (c - half) * (w - 8), 6, half * 2.0 * (w - 8), h - 12), band[1])
		var p := frozen if frozen >= 0.0 else pos_at(float(elapsed()))
		var x := 4 + p * (w - 8)
		var mc := Color("#F5F5F2")
		if result_q == "miss":
			mc = Color("#E64C4C")
		elif result_q != "":
			mc = Color("#FFC93C")
		draw_rect(Rect2(x - 5, 0, 10, h), Color("#141518"))
		draw_rect(Rect2(x - 3, 2, 6, h - 4), mc)


var M
var bar: StrikeBar
var strike_btn: Button
var vein_label: Label
var hp_bar: ProgressBar
var info: Label
var result: Label
var node_label: Label
var streak_label: Label
var event_label: Label
var tier_btns := {}
var veins := []
var tier := 1
var challenge_id := ""
var active := false
var busy := false
var gen := 0


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 10)
	var top := UI.add_row(self)
	vein_label = UI.add_label(top, "Coal Seam", 26, UI.GOLD)
	info = UI.add_label(top, "", 18, UI.MUTED)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hp_bar = UI.add_bar(self, 1.0, UI.AMBER, 18)
	bar = StrikeBar.new()
	bar.custom_minimum_size = Vector2(0, 70)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)
	strike_btn = UI.add_button(self, "STRIKE", "amber", 92, 38)
	strike_btn.button_down.connect(_on_strike)
	result = UI.add_label(self, "Tap a vein or pick one below. Strike when the marker is in the gold.", 20, UI.WHITE, true)
	var sr := UI.add_row(self, 6)
	streak_label = UI.add_label(sr, "", 19, UI.AMBER)
	event_label = UI.add_label(sr, "", 17, UI.GOLD)
	event_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var row := UI.add_row(self, 6)
	for t in [1, 2, 3, 4]:
		var b := UI.add_button(row, ["", "COAL", "IRON", "CRYSTAL", "VOID"][t], "stone", 50, 17)
		b.pressed.connect(func(): select_tier(t))
		tier_btns[t] = b
	var more := UI.add_row(self, 6)
	var ex := UI.add_button(more, "EXPEDITION", "void", 46, 17)
	ex.pressed.connect(func(): M.open_expedition())
	var lk := UI.add_button(more, "UNDERGROUND LAKE", "teal", 46, 17)
	lk.pressed.connect(func(): M.open_lake())
	node_label = UI.add_label(self, "", 17, UI.MUTED, true)
	node_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	M.node.status_changed.connect(func(text: String, color: Color):
		node_label.text = text
		node_label.add_theme_color_override("font_color", color))


func on_open() -> void:
	active = true
	await _load_veins()
	select_tier(tier, false)


func on_close() -> void:
	active = false
	challenge_id = ""
	bar.setup({})


func _load_veins() -> void:
	var r: Dictionary = await M.api.get_json("/mine/veins")
	if not r.get("ok", false):
		M.error_toast(r)
		return
	veins = r["veins"]
	for v in veins:
		var t := int(v["id"])
		var b: Button = tier_btns[t]
		UI.style_button(b, "amber" if t == tier else ("stone" if v["unlocked"] else "dark"))
		b.text = ("" if v["unlocked"] else "LOCKED ") + ["", "COAL", "IRON", "CRYSTAL", "VOID"][t]
	info.text = "Veins today: %s" % UI.n(r.get("day_blocks", 0))


func _vein(t: int) -> Dictionary:
	for v in veins:
		if int(v["id"]) == t:
			return v
	return {}


func select_tier(t: int, walk: bool = true) -> void:
	var v := _vein(t)
	if v.is_empty():
		return
	if not v["unlocked"]:
		M.toast("%s is locked: %s" % [v["name"], v["locked_reason"]], UI.AMBER)
		M.play("buzz")
		return
	tier = t
	for k in tier_btns.keys():
		var vv := _vein(k)
		UI.style_button(tier_btns[k], "amber" if k == tier else ("stone" if vv.get("unlocked", false) else "dark"))
	vein_label.text = str(v["name"])
	hp_bar.value = float(v["hp_left"]) / maxf(1.0, float(v["hp"]))
	if walk and M.world.area == "mine":
		M.world.walk_to(M.world.spot_for_vein(t), "vein")
	elif M.world.area == "mine":
		M.world.walk_to(M.world.spot_for_vein(t), "vein")
	_new_challenge()


func _new_challenge() -> void:
	if not active:
		return
	gen += 1
	var my_gen := gen
	challenge_id = ""
	var r: Dictionary = await M.api.post("/mine/start", {"tier": tier})
	if not active or my_gen != gen:
		return
	if not r.get("ok", false):
		M.error_toast(r)
		return
	challenge_id = str(r["id"])
	bar.setup(r["challenge"])
	_show_events(r.get("events", {}))
	strike_btn.disabled = false
	# A strike window lasts about 9 seconds; refresh it before it expires.
	await get_tree().create_timer(8.0).timeout
	if active and my_gen == gen and challenge_id != "" and not busy:
		_new_challenge()


func _on_strike() -> void:
	if busy or not active:
		return
	if challenge_id == "":
		_new_challenge()
		return
	var tap := bar.elapsed()
	if tap < 160:
		return
	busy = true
	strike_btn.disabled = true
	bar.frozen = bar.pos_at(float(tap))
	var cid := challenge_id
	challenge_id = ""
	gen += 1
	M.world.hero.swing()
	M.play_tier("clink", tier)
	var r: Dictionary = await M.api.post("/mine/strike", {"id": cid, "tap_ms": tap})
	busy = false
	if r.get("ok", false):
		M.node.note_strike()
		if str(r.get("quality", "miss")) != "miss":
			M.tutorial_event("strike")
	if not r.get("ok", false):
		if str(r.get("error", "")) != "too_fast":
			M.error_toast(r)
		await get_tree().create_timer(0.5).timeout
		_new_challenge()
		return
	_show_result(r)
	await get_tree().create_timer(0.55).timeout
	_new_challenge()


func _show_result(r: Dictionary) -> void:
	var q := str(r["quality"])
	bar.result_q = q
	M.apply(r)
	var colors := {"perfect": UI.GOLD, "great": UI.TEAL_L, "good": UI.TEAL, "miss": UI.RED}
	var text := q.to_upper() + "!"
	var w = M.world
	w.hit_fx(tier, q)
	if q == "miss":
		text = "MISS - the pick glanced off the rock."
		M.play("thud")
		M.vibrate(15)
		w.hero.stumble()
	else:
		var got := int(r["ore_gained"]) + int(r.get("bonus_ore", 0))
		text += "  +%s %s   (%s damage)" % [UI.n(got), UI.ore_name(str(r["ore"])), UI.n(r["damage"])]
		M.vibrate(30 if q == "perfect" else 18)
		w.ore_fly(tier, mini(got, 8))
	w.vein_damage(tier, float(r["vein_hp"]) / maxf(1.0, float(r["vein_max"])))
	var streak := int(r.get("streak", 0))
	var combo := float(r.get("combo", 1.0))
	w.set_combo(int(round((combo - 1.0) / 0.25)))
	if streak >= 3:
		streak_label.text = "STREAK %d  -  x%s ore" % [streak, str(snappedf(combo, 0.01))]
	else:
		streak_label.text = ""
	if r.get("gem") != null:
		M.toast("A %s glitters in the rubble!  +1 gem" % str(r["gem"]).to_upper(), UI.GOLD)
		M.play("rare")
		M.vibrate(90)
	for b in r.get("new_badges", []):
		M.badge_toast(str(b))
	result.text = text
	result.add_theme_color_override("font_color", colors.get(q, UI.WHITE))
	hp_bar.value = float(r["vein_hp"]) / maxf(1.0, float(r["vein_max"]))
	for v in veins:
		if int(v["id"]) == tier:
			v["hp_left"] = r["vein_hp"]
	if r.get("cleared", false):
		M.toast("VEIN CLEARED!  +%s PLS" % UI.n(r["pls"]) if int(r["pls"]) > 0 else "VEIN CLEARED!", UI.GOLD)
		M.play("coin")
		M.vibrate(80)
		w.vein_cleared(tier)
	if r.get("level_up", false):
		M.toast("LEVEL UP!  Lv %s %s" % [UI.n(r["level"]), str(r["title"])], UI.GOLD)
		M.play("levelup")
		M.vibrate(120)
		_load_veins()
	var gear: Dictionary = r.get("gear", {})
	for slot in gear.keys():
		if gear[slot].get("broken", false):
			M.toast("Your %s broke! Repair it at the Forge." % str(gear[slot]["name"]), UI.RED)


func _show_events(ev: Dictionary) -> void:
	var h = ev.get("hidden_vein")
	var parts := []
	if ev.get("deep_dive", false):
		parts.append("WEEKEND DEEP DIVE x1.5")
	if h != null and typeof(h) == TYPE_DICTIONARY:
		parts.append("%s %s: %ss" % ["FROST GEODE" if h.get("kind") == "frost" else "GLITTER VEIN", ["", "COAL", "IRON", "CRYSTAL", "VOID"][int(h["tier"])], UI.n(h["ends_in"])])
		if M.world.area == "mine":
			M.world.set_hidden_vein(int(h["tier"]))
	elif M.world.area == "mine":
		M.world.set_hidden_vein(0)
	event_label.text = "  ".join(parts)
