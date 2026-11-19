extends PanelContainer
# GUIDED FIRST FIVE MINUTES - Old Garrick, the mine foreman, walks a new player
# through mining, the network, the forge and the arena. Can be skipped any time.

const UI = preload("res://scripts/ui.gd")
const STEPS := [
	{"say": "Welcome to Pulse, miner! I'm Old Garrick, the foreman. Tap MINE at the bottom to head underground.", "short": "Tap MINE", "wait": "open_mine"},
	{"say": "Pick a vein, then hit STRIKE when the marker is in the gold. Land 3 good strikes.", "short": "Land 3 good strikes", "wait": "strike", "count": 3},
	{"say": "Nice swings! While you mine, your phone helps run the Pulse network - that is what pays you PLS every 10 minutes. Tap TOWN, then tap the big crystal to see the network.", "short": "Tap TOWN, then the big crystal", "wait": "open_network"},
	{"say": "Every glowing dot is a phone like yours. Now visit the FORGE to see what your ore can make.", "short": "Visit the FORGE", "wait": "open_forge"},
	{"say": "Gear helps you mine, never in a duel. Last stop: the ARENA. Play one free practice game.", "short": "Play a practice game in the ARENA", "wait": "practice"},
	{"say": "You're ready. Mine deep, duel fair, and keep an eye out for glittering veins. Good luck down there!", "short": "You're ready!", "wait": "done"},
]

signal finished

var M
var step := 0
var count := 0
var text: Label
var progress: Label
var buttons: HBoxContainer
var folded := false
var fold_gen := 0


func setup(m) -> void:
	M = m
	add_theme_stylebox_override("panel", UI.box(Color("#d9ccaa"), UI.AMBER, 4, 3))
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := VBoxContainer.new()
	add_child(v)
	var top := UI.add_row(v, 8)
	UI.add_label(top, "OLD GARRICK", 20, Color("#6b3a1a"))
	progress = UI.add_label(top, "", 16, Color("#6b5a3a"))
	progress.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	text = UI.add_label(v, "", 21, UI.INK)
	buttons = UI.add_row(v, 8)
	var hide_b := UI.add_button(buttons, "GOT IT", "amber", 44, 16)
	hide_b.pressed.connect(func(): _fold(true))
	var skip := UI.add_button(buttons, "SKIP TUTORIAL", "stone", 44, 16)
	skip.pressed.connect(_finish)
	gui_input.connect(func(e):
		if folded and e is InputEventMouseButton and e.pressed:
			_fold(false))
	_show()


# Folded, Garrick shrinks to one line so he never hides the screen you are using.
func _fold(on: bool) -> void:
	folded = on
	buttons.visible = not on
	var s: Dictionary = STEPS[mini(step, STEPS.size() - 1)]
	text.text = ("Garrick: " + str(s["short"]) + "  (tap for more)") if on else str(s["say"])
	text.add_theme_font_size_override("font_size", 17 if on else 21)


func _show() -> void:
	var s: Dictionary = STEPS[step]
	_fold(false)
	progress.text = "%d / %d" % [step + 1, STEPS.size()]
	fold_gen += 1
	var my := fold_gen
	var ft := create_tween()
	ft.tween_interval(8.0)
	ft.tween_callback(func():
		if my == fold_gen and not folded:
			_fold(true))
	if s["wait"] == "done":
		var t := create_tween()
		t.tween_interval(6.0)
		t.tween_callback(_finish)


func event(name: String) -> void:
	if step >= STEPS.size():
		return
	var s: Dictionary = STEPS[step]
	if s["wait"] != name:
		return
	count += 1
	if count < int(s.get("count", 1)):
		progress.text = "%d / %d   (%d of %d)" % [step + 1, STEPS.size(), count, int(s["count"])]
		return
	count = 0
	step += 1
	M.play("levelup")
	_show()


func _finish() -> void:
	M.api.post("/me/flags", {"tutorial": true})
	finished.emit()
	queue_free()
