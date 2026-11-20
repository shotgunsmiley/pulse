extends SceneTree
# v5.5: frames the fight camera for each monster with a grey block where the fight panel sits.
const WorldScript = preload("res://scripts/world.gd")
var out := "/tmp/pulse_bosscam/"

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	_run()

func wait(sec: float) -> void:
	await create_timer(sec).timeout

func _run() -> void:
	await process_frame
	var w = WorldScript.new()
	root.add_child(w)
	w.debug_hour = 15.0
	w.show_area("town")
	w.build_hero({}, "iron")
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var panel := ColorRect.new()
	panel.color = Color(0.2, 0.2, 0.22, 0.9)
	panel.anchor_left = 0
	panel.anchor_right = 1
	panel.anchor_top = 0.55
	panel.anchor_bottom = 1
	layer.add_child(panel)
	for k in ["golem", "wyrm", "spider", "wraith", "drake"]:
		w.set_boss({"state": "live", "k": 100 + k.length(), "monster": k, "name": k.capitalize(), "hp": 800, "max_hp": 1000,
			"tricks": {}, "top": [{"username": "Mae", "dmg": 50, "look": {"skin": 2}}, {"username": "Osric", "dmg": 40, "look": {"skin": 4}},
			{"username": "Tilda", "dmg": 30, "look": {"skin": 1}}]}, "me")
		var sp: Dictionary = w.boss_spot()
		w.hero.position = Vector3(sp["p"][0], 0, sp["p"][2])
		w._face(w.BOSS_POS)
		w.boss_focus = true
		w.low_frame = true
		await wait(1.5)
		root.get_viewport().get_texture().get_image().save_png(out + k + ".png")
		print("SHOT ", k)
	quit()
