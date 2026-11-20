extends Control
# MINIMAP - a small round map in the top corner of the world view.
# Shows the buildings (town) or the veins (mine), townsfolk, and you as an arrow.
# It turns with the camera, so "up" on the map is the way you are looking.

const UI = preload("res://scripts/ui.gd")
const PixelFont = preload("res://scripts/pixel_font.gd")
const R := 74.0                        # radius in pixels
const SHORT := {"mine": "M", "forge": "F", "arena": "A", "hall": "H", "tavern": "T", "board": "B", "market": "$", "network": "*"}
const ORE := {1: Color("#8a8580"), 2: Color("#c07a50"), 3: Color("#3fd0bd"), 4: Color("#a77cf0")}

var M
var t := 0.0


func setup(m) -> void:
	M = m
	custom_minimum_size = Vector2(R * 2 + 8, R * 2 + 8)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _process(delta: float) -> void:
	t += delta
	if visible:
		queue_redraw()


func _view_radius() -> float:
	var a: String = M.world.area
	return {"town": 17.0, "cabin": 5.0}.get(a, 11.0)


func _to_map(p: Vector3, hero_p: Vector3, yaw: float, scale_k: float) -> Vector2:
	var rel := Vector2(p.x - hero_p.x, p.z - hero_p.z)
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var right := Vector2(cos(yaw), -sin(yaw))
	return Vector2(R + 4, R + 4) + Vector2(rel.dot(right), -rel.dot(fwd)) * scale_k


func _draw() -> void:
	if M == null or M.world == null or M.world.hero == null:
		return
	var w = M.world
	var c := Vector2(R + 4, R + 4)
	var cave: bool = w.area in ["mine", "lake", "expedition"]
	# frame and ground
	draw_circle(c, R + 4, Color("#2b2724"))
	draw_circle(c, R, Color("#3a5a2e") if w.area == "town" else (Color("#4a3d30") if cave else Color("#5a4632")))
	var hp: Vector3 = w.hero.position
	var yaw: float = w.cam_yaw
	var k := R / _view_radius()
	if cave:
		# the cave wall ring and the lake
		var pts := PackedVector2Array()
		for i in range(33):
			var a := TAU * i / 32.0
			var q := _to_map(Vector3(cos(a) * 10.5, 0, sin(a) * 10.5 - 1.0), hp, yaw, k)
			pts.append(q)
		for i in range(32):
			var a0 := pts[i] - c
			var a1 := pts[i + 1] - c
			if a0.length() < R and a1.length() < R:
				draw_line(pts[i], pts[i + 1], Color("#24201b"), 4.0)
		if w.area == "lake":
			var lc := _to_map(Vector3(0, 0, -4.6), hp, yaw, k)
			if (lc - c).length() < R + 4.6 * k:
				draw_circle(lc, 4.6 * k, Color("#2a6f86"))
	elif w.area == "town":
		draw_circle(_to_map(Vector3.ZERO, hp, yaw, k), 3.0 * k, Color("#8a7a5c"))   # the square
	var f := PixelFont.font()
	for p in w.pickables:
		var q := _to_map(p["pos"], hp, yaw, k)
		if (q - c).length() > R - 6:
			continue
		if p["kind"] == "place":
			draw_rect(Rect2(q - Vector2(9, 9), Vector2(18, 18)), Color("#d9ccaa"))
			draw_rect(Rect2(q - Vector2(9, 9), Vector2(18, 18)), Color("#6b3a1a"), false, 2.0)
			var s: String = SHORT.get(str(p["id"]), "?")
			draw_string(f, q + Vector2(-5, 6), s, HORIZONTAL_ALIGNMENT_LEFT, -1, PixelFont.SIZE, Color("#6b3a1a"))
		else:
			draw_circle(q, 6.0, ORE.get(int(p["id"]), Color.WHITE))
			draw_arc(q, 6.0, 0, TAU, 12, Color("#1a1612"), 2.0)
	# townsfolk and pet
	for npc in w.npcs:
		if is_instance_valid(npc["n"]):
			var q := _to_map(npc["n"].position, hp, yaw, k)
			if (q - c).length() < R - 3:
				draw_circle(q, 3.0, Color("#f0e6a0"))
	# you: an arrow pointing the way you face
	var hy: float = w.hero.rotation.y
	var face := Vector2(-sin(hy - yaw), -cos(hy - yaw))
	var face_s := Vector2(face.x, face.y)
	var tip := c + face_s * 9.0
	var l := c + face_s.rotated(2.5) * 7.0
	var r := c + face_s.rotated(-2.5) * 7.0
	draw_colored_polygon(PackedVector2Array([tip, l, r]), Color.WHITE)
	draw_polyline(PackedVector2Array([tip, l, r, tip]), Color.BLACK, 1.5)
	# north-ish marker: the way the camera looks is always up
	draw_arc(c, R + 2, 0, TAU, 48, UI.AMBER, 3.0)
