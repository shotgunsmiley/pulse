extends SceneTree
# v5.3 extras tour: daily cart + chest, vein traits, mastery stars, journal, titles and taunts,
# gear names, friends (wave / gift), crew colours, Training Knight, merchant, rain, photo mode.
# godot --path . -s res://tools/extras_shots.gd   (server URL from user settings)
var M
var out := "/tmp/pulse_extras/"

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

func _run() -> void:
	await wait(3.0)
	var name := "ex%d" % (randi() % 100000)
	var r: Dictionary = await M.api.post("/auth/register", {"username": name, "password": "secret123"})
	M._on_logged_in(r["token"], r["profile"])
	await wait(3.0)
	if M.tutorial != null and is_instance_valid(M.tutorial):
		M.tutorial._finish()
	var w = M.world
	w.debug_hour = 12.5
	w._update_sky(true)
	# pretend it is a rainy weekend so the merchant and the rain show up
	M.daily["merchant"]["here"] = true
	M.daily["chest_ready"] = true
	w.set_merchant(true)
	w.set_rain(true)
	w.set_leaders(["GrinderGia", "DuelistDan", name])
	await wait(1.5)
	await snap("01_town_rain_merchant")
	M.go("mine")
	await wait(3.5)
	var mp = M.screens["mine"]
	for v in mp.veins:
		if int(v["id"]) == 1:
			v["trait"] = "rich"
			v["mastery"] = "bronze"
	mp._vein_title(mp._vein(1))
	mp.tier_btns[1].text = "COAL *"
	mp.chest_btn.visible = true
	w.hero.set_glow(true)
	w.lucky_fx(1)
	await wait(0.4)
	await snap("02_mine_daily_lucky")
	await mp._claim_cart()
	await wait(1.0)
	await snap("03_cart_claimed")
	M.open_panel("profile")
	await M.screens["profile"]._set_tab("look")
	await wait(0.8)
	await snap("04_look_title_taunt")
	await M.screens["profile"]._set_tab("badges")
	await wait(1.5)
	await snap("05_journal")
	await M.screens["profile"]._set_tab("stats")
	await wait(1.2)
	await snap("06_records")
	await M.screens["profile"]._set_tab("settings")
	await wait(0.6)
	await snap("07_settings")
	M.go("arena")
	await wait(7.0)
	await snap("08_arena_knight")
	M.go("market")
	await wait(6.0)
	await snap("09_market_merchant")
	M.go("tavern")
	await wait(6.0)
	await M.screens["tavern"]._set_tab("friends")
	await wait(1.0)
	await snap("10_tavern")
	M.close_panel()
	M.go("town")
	await wait(2.0)
	M.photo_mode()
	await wait(0.6)
	await snap("11_photo_mode")
	M.end_photo_mode()
	print("EXTRAS DONE")
	quit()
