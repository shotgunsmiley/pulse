extends SceneTree
const PF = preload("res://scripts/pixel_font.gd")
func _init() -> void:
	var l := Label.new()
	l.text = "Notice Board  ijl iIl 1|! Tavern  Hall of Chance\n+4 xp  +3 coal  LEVEL 12!  The quick brown fox"
	l.add_theme_font_override("font", PF.font())
	l.add_theme_font_size_override("font_size", 22)
	l.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	l.position = Vector2(10, 10)
	root.add_child(l)
	await process_frame
	await process_frame
	await process_frame
	root.get_viewport().get_texture().get_image().get_region(Rect2i(0, 0, 720, 90)).save_png("/tmp/ft/font.png")
	quit()
