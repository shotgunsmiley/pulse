extends VBoxContainer
# THE UNDERGROUND LAKE - a calm break from mining. Cast, wait for the bobber to
# dip, then reel in fast. The faster you react, the better your odds of a rare
# fish. Fish give XP, go on your cabin shelves and can be sold at the market.

const UI = preload("res://scripts/ui.gd")
const FISH_INFO := ["Cave Minnow", "Glowgill", "Rock Perch", "Crystal Carp", "Lantern Eel", "Void Leviathan"]

var M
var cast_btn: Button
var info: Label
var log_box: VBoxContainer
var state := "idle"      # idle | waiting | bite
var t0 := 0
var bite_ms := 0
var open := false
var gen := 0


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var top := UI.add_row(self)
	UI.add_label(top, "UNDERGROUND LAKE", 26, UI.TEAL_L)
	var back := UI.add_button(top, "BACK", "stone", 50, 18)
	back.custom_minimum_size = Vector2(120, 50)
	back.size_flags_horizontal = Control.SIZE_SHRINK_END
	back.pressed.connect(func(): M.go("mine"))
	info = UI.add_label(self, "Cast your line, wait for the bobber to dip, then REEL fast.", 20, UI.WHITE, true)
	cast_btn = UI.add_button(self, "CAST", "teal", 110, 38)
	cast_btn.button_down.connect(_press)
	UI.add_label(self, "Faster hands catch rarer fish.", 15, UI.MUTED, true)
	log_box = UI.add_scroll(self)


func on_open() -> void:
	open = true
	state = "idle"
	cast_btn.text = "CAST"
	if M.world.area != "lake":
		M.world.show_area("lake")
	M.world.walk_to(M.world.spot("lake_fish"), "fish")


func on_close() -> void:
	open = false
	gen += 1


func _press() -> void:
	match state:
		"idle":
			await _cast()
		"waiting":
			_reel(Time.get_ticks_msec() - t0)
		"bite":
			_reel(Time.get_ticks_msec() - t0)


func _cast() -> void:
	state = "casting"
	var r: Dictionary = await M.api.post("/fish/cast", {})
	if not r.get("ok", false):
		M.error_toast(r)
		state = "idle"
		return
	t0 = Time.get_ticks_msec()
	bite_ms = int(r["bite_ms"])
	state = "waiting"
	cast_btn.text = "REEL"
	UI.style_button(cast_btn, "stone")
	info.text = "Waiting for a bite..."
	M.world.cast_line()
	M.play("flip")
	gen += 1
	var my := gen
	await get_tree().create_timer(bite_ms / 1000.0).timeout
	if not open or my != gen or state != "waiting":
		return
	state = "bite"
	UI.style_button(cast_btn, "amber")
	info.text = "BITE! REEL IT IN!"
	M.world.bobber_bite()
	M.play("go")
	M.vibrate(60)


func _reel(tap_ms: int) -> void:
	if state != "waiting" and state != "bite":
		return
	state = "reeling"
	gen += 1
	var r: Dictionary = await M.api.post("/fish/reel", {"tap_ms": tap_ms})
	UI.style_button(cast_btn, "teal")
	cast_btn.text = "CAST"
	state = "idle"
	if not r.get("ok", false):
		M.error_toast(r)
		M.world.reel(false)
		return
	M.world.reel(bool(r["caught"]))
	if r["caught"]:
		var rar := int(r["rarity"])
		var line := "%s - %s cm%s  (%s ms)" % [r["fish"], UI.n(r["size_cm"]), "  NEW RECORD!" if r.get("record", false) else "", UI.n(r["reaction_ms"])]
		info.text = "Caught a %s!" % str(r["fish"])
		UI.add_label(log_box, line, 19, [UI.WHITE, UI.TEAL_L, UI.TEAL_L, UI.GOLD, UI.GOLD, UI.VOID][rar])
		M.play("rare" if rar >= 3 else "coin")
		M.vibrate(40 + rar * 30)
		M.apply({"xp": r["xp"]})
		if int(r.get("rain_xp", 0)) > 0:
			M.log_msg("The rain has the fish biting: +%d xp." % int(r["rain_xp"]), UI.TEAL_L)
		M.log_msg("You caught a %s (%s cm)%s." % [str(r["fish"]), UI.n(r["size_cm"]), " - a new record!" if r.get("record", false) else ""], UI.TEAL_L)
		M.refresh_profile()
	else:
		info.text = str(r.get("why", "It got away."))
		M.play("buzz")
