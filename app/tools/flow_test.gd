extends SceneTree
# Drives the real app against a local server through every v5 screen.
# godot --path . -s res://tools/flow_test.gd   (server URL from user settings)
var M
var out := "/tmp/pulse_flow/"
var step_errors := 0

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
	var name := "flow%d" % (randi() % 100000)
	var r: Dictionary = await M.api.post("/auth/register", {"username": name, "password": "secret123"})
	print("REGISTER ", r.get("ok"))
	M._on_logged_in(r["token"], r["profile"])
	await wait(2.0)
	await snap("01_town_hud")
	# mine + strikes
	M.go("mine")
	await wait(2.5)
	var mp = M.screens["mine"]
	for i in range(6):
		await wait(0.9)
		mp._on_strike()
	await wait(1.0)
	await snap("02_mine")
	# expedition
	M.open_expedition()
	await wait(1.5)
	await snap("03_exped_start")
	var ex = M.screens["expedition"]
	await ex._start()
	await wait(1.5)
	for i in range(5):
		await wait(0.8)
		await ex._strike()
	await snap("04_exped")
	await ex._exit()
	await wait(1.0)
	# lake
	M.open_lake()
	await wait(2.0)
	var fi = M.screens["fishing"]
	await fi._press()
	await wait(7.0)
	fi._press()
	await wait(1.5)
	await snap("05_lake")
	# cabin
	M.go("cabin")
	await wait(2.5)
	await snap("06_cabin")
	# town places
	for place in ["market", "network", "board", "tavern", "forge", "hall"]:
		M.go(place)
		await wait(7.0)
		await snap("07_" + place)
	M.go("board")
	await wait(7.0)
	M.screens["board"]._set_tab("land")
	await wait(1.5)
	await snap("08_board_land")
	M.screens["tavern"]._emote("dance")
	await wait(1.0)
	# arena + more tabs
	M.go("arena")
	await wait(8.0)
	var ar = M.screens["arena"]
	for k in ["thrones", "ghosts", "bounties", "series", "watch"]:
		ar.more = k
		await ar._set_tab("more")
		await wait(1.0)
		await snap("09_arena_" + k)
	M.screens["market"]._set_tab("sell")
	# profile
	M.open_panel("profile")
	for t in ["look", "badges", "stats", "settings"]:
		await M.screens["profile"]._set_tab(t)
		await wait(1.0)
		await snap("10_profile_" + t)
	M._check_payday()
	M.world.coin_shower()
	M.badge_toast("founding")
	await wait(1.0)
	await snap("11_payday")
	print("FLOW DONE")
	quit()
