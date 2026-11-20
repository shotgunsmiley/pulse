extends SceneTree
# Character lineup for comparing styles: godot --path . -s res://tools/char_shots.gd -- <name>
const HeroScript = preload("res://scripts/hero.gd")
var out := "/tmp/chars/"
func _init() -> void:
	_setup()

func _setup() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(out)
	var tag: String = OS.get_cmdline_user_args()[0] if OS.get_cmdline_user_args().size() > 0 else "x"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("#6f8aa6")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("#c4c2b4")
	env.ambient_light_energy = 0.85
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 160, 0)
	sun.light_energy = 1.2
	root.add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color("#4f6b38")
	pm.material = gm
	ground.mesh = pm
	root.add_child(ground)
	var looks := [{"skin": 1, "hair_style": 0, "hair_color": 0, "shirt": 3, "pants": 1, "accent": 1, "face": 3},
		{"skin": 3, "hair_style": 1, "hair_color": 2, "shirt": 4, "pants": 0, "accent": 0, "face": 0},
		{"skin": 0, "hair_style": 2, "hair_color": 3, "shirt": 1, "pants": 2, "accent": 2, "face": 5}]
	var heroes := []
	for i in range(3):
		var h = HeroScript.new()
		root.add_child(h)
		h.build(looks[i], ["iron", "starter", "crystal"][i])
		h.position = Vector3((i - 1) * 1.1, 0, 0)
		h.rotation.y = -(i - 1) * 0.45
		heroes.append(h)
	var cam := Camera3D.new()
	cam.fov = 40
	root.add_child(cam)
	cam.current = true
	cam.position = Vector3(0, 1.25, -4.6)
	cam.look_at(Vector3(0, 0.95, 0), Vector3.UP)
	_go(cam, heroes, tag)

func _go(cam, heroes, tag) -> void:
	for i in range(20):
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out + tag + "_group.png")
	cam.position = Vector3(0.0, 1.62, -1.25)
	cam.look_at(Vector3(0, 1.55, 0), Vector3.UP)
	heroes[0].visible = false
	heroes[2].visible = false
	heroes[1].rotation.y = 0.25
	for i in range(10):
		await process_frame
	root.get_viewport().get_texture().get_image().save_png(out + tag + "_face.png")
	quit()
