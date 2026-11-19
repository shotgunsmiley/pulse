extends VBoxContainer
# YOUR CABIN - a home base. Put trophies on the shelves: badges, your biggest fish,
# gems and pets you have earned. Friends can come and look.

const UI = preload("res://scripts/ui.gd")

var M
var body: VBoxContainer
var visiting := ""
var pick_slot := -1


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var top := UI.add_row(self)
	UI.add_label(top, "HOME CABIN", 26, UI.GOLD)
	var back := UI.add_button(top, "TOWN", "stone", 50, 18)
	back.custom_minimum_size = Vector2(120, 50)
	back.size_flags_horizontal = Control.SIZE_SHRINK_END
	back.pressed.connect(func(): M.go("town"))
	body = UI.add_scroll(self)


func on_open() -> void:
	if M.world.area != "cabin":
		M.world.show_area("cabin")
	M.world.walk_to(M.world.spot("cabin_shelves"), "cabin")
	await _load()


func on_close() -> void:
	visiting = ""


func visit(username: String) -> void:
	visiting = username


func _load() -> void:
	var path := "/cabin" + ("?user=" + visiting.uri_encode() if visiting != "" else "")
	var r: Dictionary = await M.api.get_json(path)
	if not r.get("ok", false):
		M.error_toast(r)
		return
	M.world.set_trophies(r["shelves"])
	UI.clear(body)
	var mine: bool = visiting == ""
	UI.add_label(body, ("Your shelves" if mine else "%s's cabin" % str(r["owner"])), 22, UI.AMBER)
	var shelves: Array = r["shelves"]
	for i in range(shelves.size()):
		var t = shelves[i]
		var row := UI.add_row(body, 6)
		UI.add_label(row, "Shelf %d: %s" % [i + 1, str(t["name"]) if t != null else "(empty)"], 19, UI.WHITE if t != null else UI.MUTED)
		if mine:
			var slot := i
			var b := UI.add_button(row, "CHANGE", "stone", 46, 16)
			b.custom_minimum_size = Vector2(140, 46)
			b.size_flags_horizontal = Control.SIZE_SHRINK_END
			b.pressed.connect(func(): _choose(slot, r["available"]))
	if mine:
		var vc := UI.add_card(body, "dark")
		UI.add_label(vc, "VISIT A FRIEND", 19, UI.AMBER)
		var nm := UI.add_input(vc, "Their username")
		var go_b := UI.add_button(vc, "VISIT", "teal", 50, 18)
		go_b.pressed.connect(func():
			visiting = nm.text.strip_edges()
			_load())
	else:
		var home := UI.add_button(body, "BACK TO MY CABIN", "amber", 54, 20)
		home.pressed.connect(func():
			visiting = ""
			_load())


func _choose(slot: int, available: Array) -> void:
	UI.clear(body)
	UI.add_label(body, "Pick a trophy for shelf %d" % (slot + 1), 22, UI.AMBER)
	var none := UI.add_button(body, "LEAVE IT EMPTY", "stone", 50, 18)
	none.pressed.connect(func(): _place(slot, ""))
	if available.is_empty():
		UI.add_label(body, "No trophies yet. Earn badges, catch fish, find gems.", 18, UI.MUTED)
	for t in available:
		var id: String = t["id"]
		var b := UI.add_button(body, "%s  (%s)" % [t["name"], t["kind"]], "dark", 50, 18)
		b.pressed.connect(func(): _place(slot, id))


func _place(slot: int, id: String) -> void:
	var r: Dictionary = await M.api.post("/cabin/place", {"slot": slot, "item": id})
	if not r.get("ok", false):
		M.error_toast(r)
	else:
		M.play("anvil")
	await _load()
