extends Control
# GUIDED FIRST FIVE MINUTES - Old Garrick, the mine foreman, walks a new player
# through mining, the network, the forge and the arena. Can be skipped any time.
#
# v5.2: Garrick talks in a parchment dialogue box only on the screens where his
# current step matters. Everywhere else (and after you tap GOT IT) he shrinks to a
# small "!" button under the top bar, so he never sits on top of the screen you are
# using. Tap the "!" to hear the step again.

const UI = preload("res://scripts/ui.gd")
const STEPS := [
	{"say": "Welcome to Pulse, miner! I'm Old Garrick, the foreman. Tap MINE at the bottom to head underground.", "short": "Tap MINE", "wait": "open_mine", "where": ["", "town"]},
	{"say": "Pick a vein, then hit STRIKE when the marker is in the gold. Land 3 good strikes.", "short": "Land 3 good strikes", "wait": "strike", "count": 3, "where": ["mine"]},
	{"say": "Nice swings! While you mine, your phone helps run the Pulse network - that is what pays you PLS every 10 minutes. Tap TOWN, then tap the big crystal to see the network.", "short": "TOWN, then the big crystal", "wait": "open_network", "where": ["mine", "", "town"]},
	{"say": "Every glowing dot is a phone like yours. Now visit the FORGE - your first pickaxe only costs a little ore and a few PLS.", "short": "Visit the FORGE", "wait": "open_forge", "where": ["network", "", "town"]},
	{"say": "Gear helps you mine, never in a duel. Last stop: the ARENA. Play one free practice game.", "short": "Practice in the ARENA", "wait": "practice", "where": ["forge", "arena"]},
	{"say": "You're ready. Mine deep, duel fair, and keep an eye out for glittering veins. Good luck down there!", "short": "You're ready!", "wait": "done", "where": []},
]

signal finished

var M
var step := 0
var count := 0
var box: PanelContainer
var text: Label
var progress: Label
var pip: Button
var screen := ""
var dismissed_step := -1     # GOT IT hides the box for this step until the "!" is tapped
var fold_gen := 0


func setup(m) -> void:
	M = m
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	box = PanelContainer.new()
	box.add_theme_stylebox_override("panel", UI.box(Color("#d9ccaa"), UI.AMBER, 4, 3))
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(box)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	box.add_child(h)
	# a little framed portrait of the foreman
	var face := PanelContainer.new()
	face.custom_minimum_size = Vector2(76, 76)
	face.add_theme_stylebox_override("panel", UI.box(Color("#6b3a1a"), Color("#3b210f"), 3, 0))
	var fl := Label.new()
	fl.text = "G"
	fl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	fl.add_theme_font_size_override("font_size", 44)
	fl.add_theme_color_override("font_color", Color("#ffd36b"))
	face.add_child(fl)
	face.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	h.add_child(face)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(v)
	var top := UI.add_row(v, 8)
	UI.add_label(top, "OLD GARRICK", 20, Color("#6b3a1a"))
	progress = UI.add_label(top, "", 16, Color("#6b5a3a"))
	progress.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text = UI.add_label(v, "", 21, UI.INK)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var buttons := UI.add_row(v, 8)
	var hide_b := UI.add_button(buttons, "GOT IT", "amber", 44, 16)
	hide_b.pressed.connect(func():
		dismissed_step = step
		_refresh())
	var skip := UI.add_button(buttons, "SKIP TUTORIAL", "stone", 44, 16)
	skip.pressed.connect(_finish)
	# the small "!" button that stands in for Garrick when he is not needed
	pip = Button.new()
	pip.text = "!  Garrick"
	pip.add_theme_font_size_override("font_size", 18)
	pip.add_theme_stylebox_override("normal", UI.box(Color("#d9ccaa"), UI.AMBER, 3, 2))
	pip.add_theme_stylebox_override("hover", UI.box(Color("#e8dcbb"), UI.AMBER, 3, 2))
	pip.add_theme_stylebox_override("pressed", UI.box(Color("#c9bc9a"), UI.AMBER, 3, 0))
	pip.add_theme_color_override("font_color", Color("#6b3a1a"))
	pip.position = Vector2(0, 0)
	pip.custom_minimum_size = Vector2(150, 44)
	pip.pressed.connect(func():
		dismissed_step = -1
		_refresh(true))
	add_child(pip)
	_show()


func on_screen(name: String) -> void:
	screen = name
	_refresh()


func _relevant() -> bool:
	if step >= STEPS.size():
		return false
	var where: Array = STEPS[step].get("where", [])
	var here := screen
	if here == "" and M and M.world:
		here = ""
	return where.has(here)


func _refresh(force := false) -> void:
	if step >= STEPS.size():
		return
	var s: Dictionary = STEPS[step]
	var open := force or (dismissed_step != step and _relevant())
	box.visible = open
	# on full-screen menus the "!" would sit on the menu's title, so it waits for the world view
	var full: bool = screen != "" and not (screen in M.LOW_PANELS)
	pip.visible = not open and not full
	pip.text = "!  " + str(s["short"])
	pip.size = Vector2.ZERO
	text.text = str(s["say"])
	progress.text = "%d / %d" % [step + 1, STEPS.size()]
	if int(s.get("count", 1)) > 1:
		progress.text += "   (%d of %d)" % [count, int(s["count"])]
	if open:
		# step text stays up for a while, then Garrick steps aside on his own
		fold_gen += 1
		var my := fold_gen
		var ft := create_tween()
		ft.tween_interval(12.0)
		ft.tween_callback(func():
			if my == fold_gen and box.visible and step < STEPS.size() and STEPS[step]["wait"] != "done":
				dismissed_step = step
				_refresh())


func _show() -> void:
	dismissed_step = -1
	_refresh(STEPS[step]["wait"] == "done")
	if STEPS[step]["wait"] == "done":
		var t := create_tween()
		t.tween_interval(6.0)
		t.tween_callback(_finish)


func event(name: String) -> void:
	if name.begins_with("open_"):
		on_screen(name.substr(5))
	if step >= STEPS.size():
		return
	var s: Dictionary = STEPS[step]
	if s["wait"] != name:
		return
	count += 1
	if count < int(s.get("count", 1)):
		_refresh()
		return
	count = 0
	step += 1
	M.play("levelup")
	_show()


func _finish() -> void:
	M.api.post("/me/flags", {"tutorial": true})
	finished.emit()
	queue_free()
