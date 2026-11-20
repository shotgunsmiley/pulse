extends SceneTree
const WorldScript = preload("res://scripts/world.gd")
func _init() -> void:
	_run()
func _run() -> void:
	await process_frame
	var w = WorldScript.new()
	root.add_child(w)
	w.build_hero({}, "iron")
	var i := 0
	for cfg in [[5.0, 1.0, "town"], [2.0, 1.0, "town"], [2.0, 1.4, "town"], [14.0, 1.0, "town"], [2.0, 1.0, "mine"]]:
		w.debug_hour = cfg[0]
		w.brightness = cfg[1]
		w.show_area("cabin")
		w.show_area(cfg[2])
		w._update_sky(true)
		await create_timer(1.2).timeout
		root.get_viewport().get_texture().get_image().save_png("/tmp/night_%d.png" % i)
		i += 1
	quit()
