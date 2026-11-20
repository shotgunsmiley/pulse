extends SceneTree
# v5.2 polish check: signs, minimap, game log, XP drops, depleting vein, level-up fireworks,
# tap marker, brighter caves and the cave camera at the exit ladder.
# godot --path . -s res://tools/polish_shots.gd   (server URL from user settings)
var M
var out := "/tmp/pulse_polish/"

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	var scene: PackedScene = load("res://main.tscn")
	M = scene.instantiate()
	root.add_child(M)
	_run()

func wait(sec: float) -> void:
	await create_timer(sec).timeout

func mark(t: String) -> void:
	var f := FileAccess.open(out + "progress.txt", FileAccess.READ_WRITE if FileAccess.file_exists(out + "progress.txt") else FileAccess.WRITE)
	f.seek_end()
	f.store_line(t)
	f.close()

func snap(name: String) -> void:
	await process_frame
	await process_frame
	root.get_viewport().get_texture().get_image().save_png(out + name + ".png")
	print("SHOT ", name)

func _run() -> void:
	await wait(3.0)
	var name := "pol%d" % (randi() % 100000)
	var r: Dictionary = await M.api.post("/auth/register", {"username": name, "password": "secret123"})
	M._on_logged_in(r["token"], r["profile"])
	await wait(2.0)
	var w = M.world
	w.debug_hour = 12.5
	w._update_sky(true)
	await wait(1.0)
	await snap("01_town_garrick")
	mark("before M.tutorial.dismissed_step")
	if M.tutorial != null and is_instance_valid(M.tutorial):
		M.tutorial.dismissed_step = M.tutorial.step
		M.tutorial._refresh()
	mark("before M.log_msg(Welcome")
	M.log_msg("Welcome to Pulse.", Color("#ffd36b"))
	mark("before w._examine(")
	w._examine(Vector2(360, 700))
	mark("before w.tap_marker(")
	w.tap_marker(w.hero.position + Vector3(1.5, 0, -1.5))
	mark("before await wait(0.2)")
	await wait(0.2)
	await snap("02_town_signs_minimap")
	w.cam_yaw = 2.4
	await wait(1.5)
	await snap("03_town_other_side")
	M.go("mine")
	await wait(3.0)
	await snap("04_mine_spawn")
	M.screens["mine"].select_tier(1)
	await wait(3.5)
	if M.tutorial != null and is_instance_valid(M.tutorial):
		M.tutorial.box.visible = false
	w.xp_drop(1, 4, 3, "coal")
	M.log_msg("Perfect strike: +3 coal, +4 xp", Color("#ffc93c"))
	await wait(0.35)
	await snap("05_xp_drop")
	w.vein_cleared(1)
	M.log_msg("The coal seam is cleared. It grows back in a moment.", Color("#ffc93c"))
	await wait(0.5)
	await snap("06_vein_depleted")
	w.level_up_fx(5)
	M.log_msg("Congratulations - you reached mining level 5!", Color("#ffc93c"))
	await wait(0.95)
	await snap("07_level_up")
	await wait(2.0)
	await snap("08_after")
	# walk back to the ladder and look at it (the old camera bug)
	M.close_panel()
	await w.walk_to(w.spot("mine_spawn"))
	w.cam_yaw = 0.0
	await wait(2.0)
	await snap("09_mine_ladder_cam")
	w.cam_yaw = PI
	await wait(2.0)
	await snap("10_mine_ladder_cam_back")
	M.open_lake()
	await wait(3.0)
	await snap("11_lake")
	print("POLISH DONE")
	quit()
