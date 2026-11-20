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
var broken_seen := {}     # gear slots already reported broken (so the warning shows once)
var daily_row: HBoxContainer
var cart_btn: Button
var chest_btn: Button
var crack_played := false
var sess := {}            # this visit to the mine, for the recap when you leave
const MASTERY_COL := {"bronze": Color("#d08a50"), "silver": Color("#d8dde4"), "gold": Color("#ffd36b")}
const TRAIT_TXT := {"stubborn": "STUBBORN - tougher, +1 ore a hit", "rich": "RICH - +50% ore"}


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
	# the daily cart and weekly chest share the streak row, so the panel never grows
	daily_row = sr
	cart_btn = UI.add_button(sr, "CART!", "teal", 40, 16)
	cart_btn.custom_minimum_size = Vector2(120, 40)
	cart_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	cart_btn.pressed.connect(_claim_cart)
	chest_btn = UI.add_button(sr, "CHEST!", "amber", 40, 16)
	chest_btn.custom_minimum_size = Vector2(120, 40)
	chest_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	chest_btn.pressed.connect(_claim_chest)
	cart_btn.visible = false
	chest_btn.visible = false
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
	sess = {"t0": Time.get_ticks_msec(), "strikes": 0, "hits": 0, "veins": 0, "xp": 0, "gems": 0, "lucky": 0}
	_apply_layout()
	tier = int(M.settings.get("last_tier", tier))
	await _load_veins()
	if not _vein(tier).get("unlocked", false):
		tier = 1
	select_tier(tier, false)


func on_close() -> void:
	active = false
	challenge_id = ""
	bar.setup({})
	M.world.hero.set_glow(false)
	# session recap
	if int(sess.get("strikes", 0)) >= 5:
		var mins := maxi(1, int((Time.get_ticks_msec() - int(sess["t0"])) / 60000))
		var line := "Session: %d min, %d strikes (%d%% hits), %d veins, +%d xp" % [mins, sess["strikes"],
			int(100.0 * float(sess["hits"]) / maxf(1.0, float(sess["strikes"]))), sess["veins"], sess["xp"]]
		if int(sess["gems"]) > 0:
			line += ", %d gem%s" % [sess["gems"], "" if int(sess["gems"]) == 1 else "s"]
		M.log_msg(line, UI.TEAL_L)
		M.toast(line, UI.TEAL_L)
	sess = {}


# One-thumb mode: the STRIKE button moves to the bottom of the panel, closest to the thumb.
func _apply_layout() -> void:
	var low: bool = M.settings.get("one_thumb", false)
	var want := get_child_count() - 1 if low else 3
	move_child(strike_btn, want)


func _claim_cart() -> void:
	cart_btn.disabled = true
	var r: Dictionary = await M.api.post("/cart/claim", {})
	cart_btn.visible = false
	if not r.get("ok", false):
		M.error_toast(r)
		return
	M.apply({"ore_inv": r["ore_inv"]})
	var parts := []
	for k in r["ore"].keys():
		parts.append("%d %s" % [int(r["ore"][k]), UI.ore_name(k).to_lower()])
	M.log_msg("The mine cart rattles in: %s." % ", ".join(PackedStringArray(parts)), UI.TEAL_L)
	M.play("coin")
	M.world.ore_fly(tier, 6)
	M.daily["cart_ready"] = false


func _claim_chest() -> void:
	chest_btn.disabled = true
	var r: Dictionary = await M.api.post("/chest/claim", {})
	chest_btn.visible = false
	if not r.get("ok", false):
		M.error_toast(r)
		return
	M.apply(r)
	var got: Dictionary = r["got"]
	var what := ("a %s dye" % str(got["dye"])) if got.has("dye") else ("a %s" % str(got.get("gem", "gem")))
	M.toast("WEEKLY CHEST: %s + 20 coal!" % what, UI.GOLD)
	M.log_msg("You open the weekly chest: %s and 20 coal." % what, UI.GOLD)
	M.play("rare")
	M.vibrate_pattern("gem")
	M.world.level_up_fx(int(M.profile.get("level", 1)))
	M.daily["chest_ready"] = false


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
		var m := str(v.get("mastery", ""))
		b.text = ("" if v["unlocked"] else "LOCKED ") + ["", "COAL", "IRON", "CRYSTAL", "VOID"][t] + {"bronze": " *", "silver": " **", "gold": " ***"}.get(m, "")
	info.text = "Veins today: %s" % UI.n(r.get("day_blocks", 0))
	cart_btn.visible = bool(r.get("cart_ready", false))
	cart_btn.disabled = false
	chest_btn.visible = bool(M.daily.get("chest_ready", false))
	chest_btn.disabled = false
	# Garrick's forecast, once a day
	var fc: Dictionary = r.get("forecast", {})
	var today := Time.get_date_string_from_system(true)
	if not fc.is_empty() and str(M.settings.get("forecast_day", "")) != today:
		M.settings["forecast_day"] = today
		M.save_settings()
		M.log_msg("Garrick: " + str(fc.get("say", "")), Color("#ffd36b"))
	if not fc.is_empty():
		event_label.text = "Today: +20%% %s" % str(fc.get("ore", "")) if event_label.text == "" else event_label.text


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
	M.settings["last_tier"] = t
	for k in tier_btns.keys():
		var vv := _vein(k)
		UI.style_button(tier_btns[k], "amber" if k == tier else ("stone" if vv.get("unlocked", false) else "dark"))
	_vein_title(v)
	crack_played = false
	hp_bar.value = float(v["hp_left"]) / maxf(1.0, float(v["hp"]))
	if walk and M.world.area == "mine":
		M.world.walk_to(M.world.spot_for_vein(t), "vein")
	elif M.world.area == "mine":
		M.world.walk_to(M.world.spot_for_vein(t), "vein")
	_new_challenge()


func _vein_title(v: Dictionary) -> void:
	var tr := str(v.get("trait", ""))
	vein_label.text = str(v["name"]) + ("   [%s]" % tr.to_upper() if tr != "" else "")
	vein_label.add_theme_color_override("font_color", Color("#ff9a5a") if tr == "stubborn" else (Color("#7fe3d3") if tr == "rich" else UI.GOLD))


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
		if str(r.get("error", "")) == "vein_locked":
			# usually a pickaxe that just broke: go back to the best vein still open
			await _load_veins()
			var best := 1
			for v in veins:
				if v.get("unlocked", false):
					best = maxi(best, int(v["id"]))
			M.toast("%s  Back to a vein you can mine." % str(r.get("message", "That vein is locked.")), UI.AMBER)
			M.log_msg("That vein needs better gear - mining the %s instead." % str(_vein(best).get("name", "coal seam")), UI.AMBER)
			if best != tier:
				select_tier(best)
			return
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
	var xp_before := int(M.profile.get("xp", 0))
	M.apply(r)
	var xp_gain := maxi(0, int(M.profile.get("xp", 0)) - xp_before)
	var colors := {"perfect": UI.GOLD, "great": UI.TEAL_L, "good": UI.TEAL, "miss": UI.RED}
	var text := q.to_upper() + "!"
	var w = M.world
	if r.get("flagged", false) and not M.profile.get("flagged", false):
		M.profile["flagged"] = true
		M.toast("Your account is under review: your tapping looked automated. Node pay is paused until a person checks it.", UI.RED)
	if r.get("taper", 1.0) < 1.0 and info.text.find("tired") < 0:
		info.text = "Long day: ore x%s" % str(r["taper"])
	w.hit_fx(tier, q)
	if not sess.is_empty():
		sess["strikes"] += 1
		sess["hits"] += 0 if q == "miss" else 1
		sess["xp"] += xp_gain
		sess["veins"] += 1 if r.get("cleared", false) else 0
		sess["gems"] += 1 if r.get("gem") != null else 0
	if q != "miss":
		# a second ping that rises with the quality, so you can hear a perfect without looking
		M.play("clink", {"perfect": 1.38, "great": 1.18, "good": 1.0}.get(q, 1.0))
		w.swing_trail(tier, q)
	if r.get("lucky", false):
		M.toast("LUCKY STRIKE!  Double ore", UI.GOLD)
		M.log_msg("A lucky strike - double ore!", UI.GOLD)
		M.play("rare")
		M.vibrate_pattern("gem")
		w.lucky_fx(tier)
		M.garrick_once("lucky", "Ha! Some days the rock just gives.")
	if int(r.get("first_perfect", 0)) > 0:
		w.float_text(w.hero.position + Vector3(0, 2.3, 0), "+25 first perfect today!", UI.GOLD, 2, 0.5, 1.6)
		M.log_msg("First perfect of the day: +25 xp.", UI.GOLD)
	var rh := int(r.get("rhythm", 0))
	w.hero.set_glow(rh > 0)
	if int(r.get("rally", 0)) >= 3 and str(event_label.text).find("RALLY") < 0:
		event_label.text = "CREW RALLY +10%"
		M.log_msg("Your crew is mining together: +10% ore.", UI.TEAL_L)
	if int(r.get("comeback", 0)) > 0:
		info.text = "Welcome back: double xp %d min" % maxi(1, int(r["comeback"]) / 60)
	if r.get("dye") != null:
		M.toast("You found %s DYE! Try it in ME > LOOK." % str(r["dye"]).to_upper(), UI.GOLD)
		M.log_msg("You found a pot of %s dye." % str(r["dye"]).to_lower(), UI.GOLD)
		M.play("rare")
	if q == "miss":
		text = "MISS - the pick glanced off the rock."
		M.play("thud")
		M.vibrate(15)
		w.hero.stumble()
	else:
		var got := int(r["ore_gained"]) + int(r.get("bonus_ore", 0))
		text += "  +%s %s   (%s damage)" % [UI.n(got), UI.ore_name(str(r["ore"])), UI.n(r["damage"])]
		M.vibrate_pattern(q)
		w.ore_fly(tier, mini(got, 8))
		w.xp_drop(tier, xp_gain, got, UI.ore_name(str(r["ore"])).to_lower())
		M.log_msg("%s strike: +%d %s, +%d xp" % [q.capitalize(), got, UI.ore_name(str(r["ore"])).to_lower(), xp_gain], colors.get(q, UI.WHITE))
	w.vein_damage(tier, float(r["vein_hp"]) / maxf(1.0, float(r["vein_max"])))
	var streak := int(r.get("streak", 0))
	var combo := float(r.get("combo", 1.0))
	w.set_combo(int(round((combo - 1.0) / 0.25)))
	if streak >= 3:
		streak_label.text = "STREAK %d  -  x%s ore" % [streak, str(snappedf(combo, 0.01))] + ("   RHYTHM +1" if rh > 0 else "")
	else:
		streak_label.text = ""
	if q == "perfect" and streak in [10, 25, 50, 100]:
		M.toast("%d PERFECT IN A ROW!" % streak, UI.GOLD)
		M.log_msg("%d perfect strikes in a row!" % streak, UI.GOLD)
		M.play("levelup", 1.2)
		w.level_up_fx(streak)
	if r.get("gem") != null:
		M.toast("A %s glitters in the rubble!  +1 gem" % str(r["gem"]).to_upper(), UI.GOLD)
		M.log_msg("You found a %s!" % str(r["gem"]), UI.GOLD)
		M.vibrate_pattern("gem")
		M.garrick_once("gem", "A gem! Keep it, trade it, or put it on your cabin shelf.")
		M.play("rare")
		M.vibrate(90)
	for b in r.get("new_badges", []):
		M.badge_toast(str(b))
	result.text = text
	result.add_theme_color_override("font_color", colors.get(q, UI.WHITE))
	hp_bar.value = float(r["vein_hp"]) / maxf(1.0, float(r["vein_max"]))
	if hp_bar.value < 0.25 and not crack_played and not r.get("cleared", false):
		crack_played = true
		M.play("thud", 0.55)          # the rock creaks: one or two more hits
	for v in veins:
		if int(v["id"]) == tier:
			v["hp_left"] = r["vein_hp"]
			v["hp"] = r["vein_max"]
			if r.get("cleared", false):
				var was_trait := str(v.get("trait", ""))
				v["trait"] = str(r.get("trait", ""))
				v["clears"] = int(r.get("clears", 0))
				crack_played = false
				_vein_title(v)
				if v["trait"] != "" and v["trait"] != was_trait:
					M.log_msg("The next vein looks %s." % TRAIT_TXT.get(v["trait"], v["trait"]).to_lower(), Color("#ff9a5a") if v["trait"] == "stubborn" else UI.TEAL_L)
				var c := int(v["clears"])
				if c in [100, 500, 2000]:
					var medal: String = {100: "BRONZE", 500: "SILVER", 2000: "GOLD"}[c]
					M.toast("%s MASTERY: %s (%d cleared)" % [medal, str(v["name"]).to_upper(), c], UI.GOLD)
					M.log_msg("You earned %s mastery of the %s." % [medal.to_lower(), str(v["name"]).to_lower()], UI.GOLD)
					_load_veins()
	if r.get("cleared", false):
		M.toast("VEIN CLEARED!  +%s PLS" % UI.n(r["pls"]) if int(r["pls"]) > 0 else "VEIN CLEARED!", UI.GOLD)
		M.play("coin")
		M.vibrate(80)
		w.vein_cleared(tier)
		M.log_msg("The %s is cleared. It grows back in a moment." % str(_vein(tier).get("name", "vein")).to_lower(), UI.GOLD)
	if r.get("level_up", false):
		M.toast("LEVEL UP!  Lv %s %s" % [UI.n(r["level"]), str(r["title"])], UI.GOLD)
		M.play("levelup")
		M.vibrate(120)
		w.level_up_fx(int(r["level"]))
		M.vibrate_pattern("level")
		M.garrick_once("level", "Look at you! Every few levels a new vein opens up.")
		M.log_msg("Congratulations - you reached mining level %s!" % UI.n(r["level"]), UI.GOLD)
		_load_veins()
	var gear: Dictionary = r.get("gear", {})
	for slot in gear.keys():
		var broken: bool = gear[slot].get("broken", false)
		if broken and not broken_seen.get(slot, false):
			M.toast("Your %s broke! Repair it at the Forge." % str(gear[slot]["name"]), UI.RED)
			M.garrick_once("broken", "Snapped it, did you? The Forge mends gear for ore.")
			M.log_msg("Your %s broke. Repair it at the Forge (mostly ore)." % str(gear[slot]["name"]).to_lower(), UI.RED)
		broken_seen[slot] = broken


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
