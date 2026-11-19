extends VBoxContainer
# CAVE EXPEDITION - dig down floor by floor. Each floor has one vein; clear it, then
# go deeper or climb out with your haul. Every swing burns lamp oil. If the oil runs
# out the cave collapses and you escape with only half. Deeper floors pay better.
# Costs 6 coal (lamp oil). Pays ore, gems and XP - never PLS.

const UI = preload("res://scripts/ui.gd")
const MinePanel = preload("res://scripts/screens/mine_panel.gd")

var M
var bar
var oil_bar: ProgressBar
var hp_bar: ProgressBar
var title: Label
var haul_label: Label
var result: Label
var strike_btn: Button
var deeper_btn: Button
var exit_btn: Button
var start_box: VBoxContainer
var play_box: VBoxContainer
var trip := {}
var busy := false
var open := false


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	start_box = VBoxContainer.new()
	add_child(start_box)
	play_box = VBoxContainer.new()
	play_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(play_box)
	var top := UI.add_row(play_box)
	title = UI.add_label(top, "FLOOR 1", 26, UI.VOID)
	var back := UI.add_button(top, "CLIMB OUT", "green", 50, 18)
	back.custom_minimum_size = Vector2(170, 50)
	back.size_flags_horizontal = Control.SIZE_SHRINK_END
	back.pressed.connect(_exit)
	exit_btn = back
	UI.add_label(play_box, "LAMP OIL", 15, UI.AMBER)
	oil_bar = UI.add_bar(play_box, 1.0, UI.AMBER, 14)
	hp_bar = UI.add_bar(play_box, 1.0, UI.VOID, 14)
	bar = MinePanel.StrikeBar.new()
	bar.custom_minimum_size = Vector2(0, 72)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	play_box.add_child(bar)
	var row := UI.add_row(play_box, 6)
	strike_btn = UI.add_button(row, "STRIKE", "amber", 96, 34)
	strike_btn.button_down.connect(_strike)
	deeper_btn = UI.add_button(row, "GO DEEPER", "void", 96, 26)
	deeper_btn.pressed.connect(_deeper)
	result = UI.add_label(play_box, "", 19, UI.WHITE, true)
	haul_label = UI.add_label(play_box, "", 17, UI.TEAL_L, true)


func on_open() -> void:
	open = true
	await _load()


func on_close() -> void:
	open = false


func _load() -> void:
	var r: Dictionary = await M.api.get_json("/expedition")
	if not r.get("ok", false):
		M.error_toast(r)
		return
	_render(r.get("expedition"), r)


func _render(e, r: Dictionary = {}) -> void:
	if e == null or typeof(e) != TYPE_DICTIONARY:
		trip = {}
		play_box.visible = false
		start_box.visible = true
		UI.clear(start_box)
		UI.add_title(start_box, "CAVE EXPEDITION", "Dig down floor by floor. Deeper pays better.")
		var c := UI.add_card(start_box, "void")
		UI.add_label(c, "Every swing burns lamp oil. Clear a floor's vein, then GO DEEPER or CLIMB OUT with your haul.", 19)
		UI.add_label(c, "If the oil runs out, the cave collapses and you escape with only half.", 19, UI.AMBER)
		UI.add_label(c, "Deepest floor so far: %s" % UI.n(r.get("deepest", M.profile.get("deepest", 0))), 19, UI.GOLD)
		var go_b := UI.add_button(start_box, "LIGHT THE LAMP (6 coal)", "amber", 70, 24)
		go_b.pressed.connect(_start)
		var back := UI.add_button(start_box, "BACK TO THE MINE", "stone", 56, 20)
		back.pressed.connect(func(): M.go("mine"))
		return
	trip = e
	start_box.visible = false
	play_box.visible = true
	var floor_n := int(e["floor"])
	var ch: Dictionary = e["challenge"]
	if M.world.area != "expedition" or int(M.world.area_opts.get("floor", 0)) != floor_n:
		M.world.show_area("expedition", {"tier": int(ch["tier"]), "floor": floor_n})
		M.world.walk_to(M.world.spot("exped_vein"), "vein")
	title.text = "FLOOR %d  -  %s" % [floor_n, UI.ore_name(str(ch["ore"])).to_upper()]
	oil_bar.value = float(e["oil"]) / 100.0
	M.world.set_lantern(float(e["oil"]) / 100.0)
	hp_bar.value = float(e["hp"]) / maxf(1.0, float(e["hp_max"]))
	bar.setup(ch)
	strike_btn.disabled = bool(e["cleared"])
	deeper_btn.disabled = not bool(e["cleared"])
	var h: Dictionary = e["haul"]
	var parts := []
	for k in h["ore"].keys():
		parts.append("%s %s" % [UI.n(h["ore"][k]), UI.ore_name(k)])
	for g in h["gems"].keys():
		parts.append("%s %s" % [UI.n(h["gems"][g]), str(g)])
	haul_label.text = "Haul: " + (", ".join(parts) if not parts.is_empty() else "nothing yet") + "   +%s XP" % UI.n(h["xp"])


func _start() -> void:
	var r: Dictionary = await M.api.post("/expedition/start", {})
	if not r.get("ok", false):
		M.error_toast(r)
		return
	M.play("go")
	M.refresh_profile()
	_render(r["expedition"])


func _strike() -> void:
	if busy or trip.is_empty() or bool(trip.get("cleared", false)):
		return
	var tap: int = bar.elapsed()
	if tap < 160:
		return
	busy = true
	bar.frozen = bar.pos_at(float(tap))
	M.world.hero.swing()
	var tier := int(trip["challenge"]["tier"])
	M.play_tier("clink", tier)
	var r: Dictionary = await M.api.post("/expedition/strike", {"tap_ms": tap})
	busy = false
	if not r.get("ok", false):
		if str(r.get("error", "")) != "too_fast":
			M.error_toast(r)
		bar.setup(trip["challenge"])
		return
	var q := str(r["quality"])
	bar.result_q = q
	M.world.hit_fx(tier, q)
	if q == "miss":
		M.world.hero.stumble()
		M.play("thud")
	result.text = q.to_upper() + "!"
	result.add_theme_color_override("font_color", {"perfect": UI.GOLD, "great": UI.TEAL_L, "good": UI.TEAL}.get(q, UI.RED))
	if r.get("collapsed", false):
		M.world.shake = 0.6
		M.play("boom")
		M.vibrate(300)
		M.toast("THE CAVE COLLAPSED! You escaped from floor %s with half your haul." % UI.n(r.get("floor_reached", 0)), UI.RED)
		M.refresh_profile()
		await get_tree().create_timer(1.2).timeout
		M.go("mine")
		return
	var e: Dictionary = r["expedition"]
	if e["cleared"] and not trip.get("cleared", false):
		M.world.vein_cleared(tier)
		M.play("coin")
		M.toast("Floor %s cleared! Go deeper or climb out." % UI.n(e["floor"]), UI.GOLD)
		if r.get("gem") != null:
			M.toast("Found a %s!" % str(r["gem"]).to_upper(), UI.GOLD)
			M.play("rare")
	else:
		M.world.vein_damage(tier, float(e["hp"]) / maxf(1.0, float(e["hp_max"])))
	await get_tree().create_timer(0.35).timeout
	_render(e)


func _deeper() -> void:
	var r: Dictionary = await M.api.post("/expedition/descend", {})
	if not r.get("ok", false):
		M.error_toast(r)
		return
	M.play("thud")
	M.world.shake = 0.3
	_render(r["expedition"])


func _exit() -> void:
	if trip.is_empty():
		M.go("mine")
		return
	var r: Dictionary = await M.api.post("/expedition/exit", {})
	if not r.get("ok", false):
		M.error_toast(r)
		return
	var got: Dictionary = r["banked"]
	var parts := []
	for k in got["ore"].keys():
		parts.append("%s %s" % [UI.n(got["ore"][k]), UI.ore_name(k)])
	for g in got["gems"].keys():
		parts.append("%s %s" % [UI.n(got["gems"][g]), str(g)])
	M.toast("Climbed out of floor %s with %s and %s XP!" % [UI.n(r["floor_reached"]), ", ".join(parts) if not parts.is_empty() else "nothing", UI.n(got["xp"])], UI.GOLD)
	M.play("win")
	M.refresh_profile()
	trip = {}
	M.go("mine")
