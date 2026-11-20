extends SceneTree
const WorldScript = preload("res://scripts/world.gd")
var world
var out := "/tmp/review/"
func _init() -> void:
	DirAccess.make_dir_recursive_absolute(out)
	world = WorldScript.new()
	root.add_child(world)
	_run()
func snap(name: String, frames: int = 30) -> void:
	for i in range(frames):
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out + name + ".png")
func cam(pos: Vector3, look: Vector3) -> void:
	world.cinematic = true
	world.camera.position = pos
	world.camera.look_at(look, Vector3.UP)
func _run() -> void:
	await process_frame
	world.debug_hour = 13.0
	world.set_season("summer")
	world.build_hero({"skin": 1, "hair_style": 0, "hair_color": 0, "shirt": 3, "pants": 1, "accent": 1, "face": 3}, "iron")
	world.show_area("town")
	await snap("t_default", 40)
	cam(Vector3(9, 4, 9), Vector3(10.5, 2, -1))
	await snap("t_forge_tavern")
	cam(Vector3(-6, 3.5, 2), Vector3(-11, 2, -4))
	await snap("t_arena_side")
	cam(Vector3(0, 14, 16), Vector3(0, 0, 0))
	await snap("t_high")
	cam(Vector3(0, 2.2, -6), Vector3(0, 2.5, -13))
	await snap("t_mine_entrance")
	world.cinematic = false
	world.show_area("mine")
	await snap("m_default", 40)
	world.cinematic = true
	cam(Vector3(-3.6, 2.2, 0.5), Vector3(-6, 0.8, -1.5))
	await snap("m_coal_close")
	cam(Vector3(3.5, 2.4, -3.5), Vector3(2.6, 1, -6.4))
	await snap("m_crystal_close")
	quit()
