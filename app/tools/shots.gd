extends SceneTree
# Renders preview screenshots of every area: godot --path . -s res://tools/shots.gd
const WorldScript = preload("res://scripts/world.gd")
var world
var out := "/tmp/pulse_shots/"

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	world = WorldScript.new()
	root.add_child(world)
	_run()

func snap(name: String, frames: int = 20) -> void:
	for i in range(frames):
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(out + name + ".png")
	print("shot ", name)

func _run() -> void:
	await process_frame
	world.build_hero({"skin": 1, "hair_style": 1, "hair_color": 2, "shirt": 3, "pants": 1, "accent": 1, "face": 5}, "crystal")
	world.set_pet("golem")
	world.debug_hour = 12.5
	world.show_area("town")
	await snap("town", 40)
	world.cam_yaw = 2.4
	await snap("town_side", 40)
	world.cam_yaw = world.hero.rotation.y + PI
	world.cam_dist = 2.2
	world.cam_height = 0.6
	await snap("hero_face", 40)
	world.cam_dist = 7.4
	world.cam_height = 5.2
	world.debug_hour = 21.0
	world._update_sky(true)
	world.cam_yaw = 0.0
	await snap("town_night", 40)
	world.debug_hour = 12.5
	world.set_season("winter")
	await snap("town_winter", 40)
	world.set_season("fall")
	world.show_area("mine")
	world.hero.position = Vector3(-3.5, 0, -0.3)
	world._face(Vector3(-6, 0, -1.5))
	world.cam_yaw = world.hero.rotation.y
	world.low_frame = true
	await snap("mine_low", 30)
	world.vein_damage(1, 0.3)
	world.hit_fx(1, "perfect")
	world.ore_fly(1, 4)
	world.set_combo(3)
	world.set_hidden_vein(1)
	await snap("mine_hit", 4)
	world.low_frame = false
	world.show_area("lake")
	world._place_hero(world.spot("lake_fish"))
	world.cast_line()
	await snap("lake", 50)
	world.show_area("cabin")
	world.set_trophies([{"id": "badge:founding"}, {"id": "fish:Glowgill"}, {"id": "gem:sapphire"}, {"id": "pet:bat"}, null, {"id": "gem:garnet"}])
	world.set_pet("sprite")
	world._place_hero(world.spot("cabin_spawn"))
	await snap("cabin", 40)
	world.show_area("expedition", {"tier": 3, "floor": 7})
	world.set_pet("bat")
	await snap("expedition", 40)
	quit()
