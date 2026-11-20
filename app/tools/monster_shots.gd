extends SceneTree
# v5.5: a quick look at the five monsters standing in the town square (no server needed).
# godot --path . -s res://tools/monster_shots.gd
const WorldScript = preload("res://scripts/world.gd")
const MonsterScript = preload("res://scripts/monster.gd")
var out := "/tmp/pulse_monsters/"

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	_run()

func wait(sec: float) -> void:
	await create_timer(sec).timeout

func snap(name: String) -> void:
	await process_frame
	await process_frame
	root.get_viewport().get_texture().get_image().save_png(out + name + ".png")
	print("SHOT ", name)

func _run() -> void:
	await process_frame
	var w = WorldScript.new()
	root.add_child(w)
	w.debug_hour = 14.0
	w.show_area("town")
	w.build_hero({}, "iron")
	await wait(0.5)
	w.cinematic = true
	var pos := Vector3(5.6, 0, 1.6)
	var hero_at := Vector3(3.2, 0, 2.7)
	w.hero.position = hero_at
	w.hero.look_at(Vector3(pos.x, 0, pos.z), Vector3.UP)
	w.hero.rotate_y(PI)
	for k in ["golem", "wyrm", "spider", "wraith", "drake"]:
		var m = MonsterScript.new()
		w.area_root.add_child(m)
		m.build(k)
		m.position = pos
		var d: Vector3 = hero_at - pos
		m.rotation.y = atan2(d.x, d.z)
		await wait(0.6)
		w.camera.position = hero_at + Vector3(-3.6, 2.6, 3.4)
		w.camera.look_at(pos + Vector3(0, 1.6, 0), Vector3.UP)
		await snap("m_%s_a" % k)
		m.roar()
		await wait(0.55)
		w.camera.position = pos + Vector3(-1.0, 3.4, 6.8)
		w.camera.look_at(pos + Vector3(0, 1.5, 0), Vector3.UP)
		await snap("m_%s_b" % k)
		var tr: Dictionary = {"golem": {"hardened": 8.0}, "wyrm": {"burrowed": 5.0}, "drake": {"shield": 5.0, "enraged": true}}.get(k, {})
		if not tr.is_empty():
			m.set_tricks(tr, 0.15)
			await wait(1.2)
			await snap("m_%s_c" % k)
		m.queue_free()
		await wait(0.2)
	quit()
