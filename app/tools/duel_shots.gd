extends SceneTree
# Records frames of the Quickdraw sword duel: godot --path . -s res://tools/duel_shots.gd
const DuelView = preload("res://scripts/duel_view.gd")
class Stub extends Node:
	var profile := {"username": "Shotgun"}
	func play(_s, _p = 1.0) -> void:
		pass
	func vibrate(_x) -> void:
		pass
var out := "/tmp/duel/"
var dv
func _init() -> void:
	_go()
func snap(name: String) -> void:
	await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	img.get_region(Rect2i(0, 0, img.get_width(), 400)).save_png(out + name + ".png")
func _go() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(out)
	var stub := Stub.new()
	root.add_child(stub)
	var holder := Control.new()
	holder.position = Vector2.ZERO
	holder.size = Vector2(720, 400)
	root.add_child(holder)
	dv = DuelView.new()
	holder.add_child(dv)
	dv.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dv.setup(stub, {"skin": 1, "hair_style": 0, "hair_color": 0, "shirt": 3, "pants": 1, "accent": 1, "face": 3}, "iron", "Training Knight",
		{"skin": 0, "hair_style": 0, "hair_color": 4, "shirt": 0, "pants": 3, "accent": 1, "face": 4})
	await create_timer(1.0).timeout
	await snap("01_guard")
	dv.go(-1)
	await create_timer(0.05).timeout
	dv.player_tap(240)
	# frames through the strike
	for i in range(6):
		await create_timer(0.07).timeout
		await snap("02_strike_%d" % i)
	await create_timer(0.6).timeout
	await snap("03_down")
	dv.ready_round(2, 5)
	await create_timer(1.2).timeout
	await snap("04_back_up")
	dv.go(230)
	await create_timer(0.45).timeout
	await snap("05_knight_hits")
	await create_timer(0.8).timeout
	await snap("06_you_down")
	await dv.finale("me")
	await snap("07_victory")
	quit()
