extends Node
# Pulse Network v5 - app controller.
# Owns the server connection, the 3D world, the HUD (top bar + travel bar),
# and opens the location panels (Mine, Forge, Arena, Gambit Hall, Tavern, Board, Profile).
# PLS is an in-game balance that can only be mined in game. It cannot be bought or cashed out.

const UI = preload("res://scripts/ui.gd")
const ApiScript = preload("res://scripts/api.gd")
const WorldScript = preload("res://scripts/world.gd")
const NodeScript = preload("res://scripts/node_client.gd")
const LoginScript = preload("res://scripts/screens/login.gd")
const SCREENS := {
	"mine": preload("res://scripts/screens/mine_panel.gd"),
	"forge": preload("res://scripts/screens/forge.gd"),
	"arena": preload("res://scripts/screens/arena.gd"),
	"hall": preload("res://scripts/screens/hall.gd"),
	"tavern": preload("res://scripts/screens/tavern.gd"),
	"board": preload("res://scripts/screens/board.gd"),
	"profile": preload("res://scripts/screens/profile.gd"),
	"expedition": preload("res://scripts/screens/expedition.gd"),
	"fishing": preload("res://scripts/screens/fishing.gd"),
	"cabin": preload("res://scripts/screens/cabin.gd"),
	"market": preload("res://scripts/screens/market.gd"),
	"network": preload("res://scripts/screens/network.gd"),
}
const TutorialScript = preload("res://scripts/tutorial.gd")
const LOW_PANELS := ["mine", "expedition", "fishing", "cabin"]
const TIER_PITCH := {1: 0.85, 2: 1.0, 3: 1.25, 4: 0.7}
const BADGE_NAMES := {"founding": "Founding Miner", "first_vein": "First Crack", "veins_100": "Seasoned Miner",
	"veins_1000": "Mountain Mover", "streak_10": "On Fire", "streak_25": "Inferno", "node_1h": "Node Online",
	"node_10h": "Node Veteran", "node_100h": "Backbone", "gem_first": "Glitter", "duel_1": "First Blood",
	"duel_25": "Duelist", "angler": "Angler", "deep_8": "Deep Diver", "deep_15": "Abyss Walker"}
const SOUNDS := ["clink", "thud", "coin", "rare", "levelup", "rune0", "rune1", "rune2", "rune3", "buzz", "go",
	"anvil", "click", "flip", "roll", "boom", "win", "lose", "payday", "chime"]
const NAV := [["town", "house", "TOWN"], ["mine", "pickaxe", "MINE"], ["forge", "anvil", "FORGE"],
	["arena", "swords", "ARENA"], ["hall", "dice", "HALL"], ["tavern", "bubble", "TAVERN"], ["board", "scroll", "BOARD"]]
const SETTINGS_PATH := "user://pulse_settings.json"
const SESSION_PATH := "user://pulse_session.json"

var api
var world
var node    # node_client.gd: this phone as a network node
var ui_root: Control
var layout: VBoxContainer
var top_bar: PanelContainer
var content: Control
var nav_bar: PanelContainer
var toast_label: Label
var overlay: Control = null
var hud := {}
var nav_buttons := {}
var profile := {}
var screens := {}
var current := ""
var pending_place := ""
var settings := {"sound": true, "vibrate": true, "server": ""}
var players := {}
var beat := 0.0
var safe_top := 0.0
var hero_key := ""
var pending_challenge := ""
var pet_key := "-"
var tutorial = null
var last_payday_epoch := -1
var audio    # audio.gd: ambience and music


func _ready() -> void:
	get_tree().quit_on_go_back = false
	_load_settings()
	api = ApiScript.new()
	add_child(api)
	if str(settings.get("server", "")) != "":
		api.base_url = str(settings["server"])
	api.session_expired.connect(_on_session_expired)
	node = NodeScript.new()
	node.setup(self)
	add_child(node)
	world = WorldScript.new()
	add_child(world)
	world.place_tapped.connect(go)
	world.vein_tapped.connect(_on_vein_tapped)
	node.pulsed.connect(func(_c): world.network_pulse())
	audio = preload("res://scripts/audio.gd").new()
	add_child(audio)
	audio.setup(self)
	for s in SOUNDS:
		var p := AudioStreamPlayer.new()
		p.stream = load("res://sounds/%s.wav" % s)
		p.max_polyphony = 4
		add_child(p)
		players[s] = p
	var layer := CanvasLayer.new()
	add_child(layer)
	ui_root = Control.new()
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.theme = UI.make_theme()
	layer.add_child(ui_root)
	_compute_safe_area()
	world.show_area("town")
	world.build_hero({}, "starter")
	world.input_enabled = false
	_start()


func _compute_safe_area() -> void:
	var safe := DisplayServer.get_display_safe_area()
	var win := DisplayServer.window_get_size()
	var vis := get_viewport().get_visible_rect().size
	if win.y > 0 and safe.position.y > 0:
		safe_top = float(safe.position.y) * vis.y / float(win.y)
	safe_top = clampf(safe_top, 0.0, 120.0)


# ---------------------------------------------------------------- start / login
func _start() -> void:
	var cover := _show_overlay()
	var box := UI.add_card(cover, "deep")
	UI.add_title(box, "PULSE NETWORK", "Mine. Forge. Compete.")
	var status := UI.add_label(box, "Connecting to Pulse...", 22, UI.MUTED, true)
	if not settings.get("intro_seen", false):
		_close_overlay()
		await world.play_intro()
		settings["intro_seen"] = true
		save_settings()
		cover = _show_overlay()
		box = UI.add_card(cover, "deep")
		UI.add_title(box, "PULSE NETWORK", "Swing the pick. Power the network.")
		status = UI.add_label(box, "Connecting to Pulse...", 22, UI.MUTED, true)
	var ok: bool = await api.wake(func(t): status.text = t)
	if not ok:
		status.text = "The Pulse server did not answer. Check your connection."
		var retry := UI.add_button(box, "TRY AGAIN", "teal")
		retry.pressed.connect(func(): _close_overlay(); _start())
		return
	var saved := _read_json(SESSION_PATH)
	if str(saved.get("token", "")) != "":
		api.token = str(saved["token"])
		status.text = "Signing in..."
		var r: Dictionary = await api.get_json("/me")
		if r.get("ok", false):
			_close_overlay()
			enter_game(r["profile"], r)
			return
	_close_overlay()
	_show_login()


func _show_login() -> void:
	var cover := _show_overlay()
	var login = LoginScript.new()
	login.init(self)
	login.logged_in.connect(_on_logged_in)
	cover.add_child(login)


func _on_logged_in(token: String, prof: Dictionary) -> void:
	api.token = token
	_write_json(SESSION_PATH, {"token": token})
	_close_overlay()
	enter_game(prof)


func _on_session_expired() -> void:
	if overlay != null:
		return
	_write_json(SESSION_PATH, {})
	api.token = ""
	node.stop()
	close_panel()
	_set_hud_visible(false)
	world.input_enabled = false
	_show_login()


func logout() -> void:
	await api.post("/auth/logout", {})
	_on_session_expired()


func _show_overlay() -> Control:
	_close_overlay()
	var shade := ColorRect.new()
	shade.color = Color(0.08, 0.09, 0.11, 0.86)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.add_child(shade)
	overlay = shade
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(620, 0)
	center.add_child(v)
	return v


func _close_overlay() -> void:
	if overlay != null:
		ui_root.remove_child(overlay)
		overlay.queue_free()
		overlay = null


# ---------------------------------------------------------------- HUD
func enter_game(prof: Dictionary, me: Dictionary = {}) -> void:
	profile = prof
	if layout == null:
		_build_hud()
	_set_hud_visible(true)
	update_hud()
	world.input_enabled = true
	go("town")
	api.post("/heartbeat", {})
	node.start_session(str(prof.get("uid", "")))
	var ev: Dictionary = me.get("events", {})
	if ev.has("season"):
		world.set_season(str(ev["season"]))
	for b in me.get("new_badges", []):
		badge_toast(str(b))
	if not prof.get("tutorial", true) and tutorial == null:
		tutorial = TutorialScript.new()
		tutorial.setup(self)
		tutorial.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		tutorial.offset_top = 150 + safe_top
		tutorial.offset_left = 16
		tutorial.offset_right = -16
		tutorial.finished.connect(func(): tutorial = null)
		ui_root.add_child(tutorial)


func _set_hud_visible(v: bool) -> void:
	if layout != null:
		layout.visible = v


func _build_hud() -> void:
	layout = VBoxContainer.new()
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_theme_constant_override("separation", 0)
	ui_root.add_child(layout)
	UI.add_space(layout, int(safe_top))
	top_bar = PanelContainer.new()
	top_bar.add_theme_stylebox_override("panel", UI.box(Color("#2b2724"), UI.AMBER, 4, 4))
	layout.add_child(top_bar)
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 4)
	top_bar.add_child(tv)
	var r1 := UI.add_row(tv, 8)
	UI.add_icon(r1, "coin", 40)
	hud["pls"] = UI.add_label(r1, "0 PLS", 30, UI.GOLD)
	hud["level"] = UI.add_label(r1, "", 18, UI.TEAL_L)
	hud["level"].horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var me := UI.add_button(r1, "ME", "teal", 52, 20)
	me.custom_minimum_size = Vector2(92, 52)
	me.size_flags_horizontal = Control.SIZE_SHRINK_END
	me.pressed.connect(func(): open_panel("profile"))
	var r2 := UI.add_row(tv, 6)
	for k in ["coal", "iron", "crystal", "void"]:
		UI.add_icon(r2, UI.ORE_ICONS[k], 28)
		hud["ore_" + k] = UI.add_label(r2, "0", 22)
	hud["xp"] = UI.add_bar(tv, 0.0, UI.TEAL, 10)
	content = Control.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_child(content)
	toast_label = Label.new()
	toast_label.add_theme_font_size_override("font_size", 24)
	toast_label.add_theme_color_override("font_color", UI.WHITE)
	toast_label.add_theme_stylebox_override("normal", UI.box(Color(0.1, 0.1, 0.12, 0.9), UI.AMBER, 3))
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	toast_label.offset_left = 30
	toast_label.offset_right = -30
	toast_label.offset_top = 14
	toast_label.visible = false
	toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(toast_label)
	nav_bar = PanelContainer.new()
	nav_bar.add_theme_stylebox_override("panel", UI.box(Color("#1f2328"), UI.OUTLINE, 4))
	layout.add_child(nav_bar)
	var nr := HBoxContainer.new()
	nr.add_theme_constant_override("separation", 4)
	nav_bar.add_child(nr)
	for item in NAV:
		nav_buttons[item[0]] = _nav_item(nr, item[0], item[1], item[2])
	UI.add_space(layout, 6)


func _nav_item(parent: Node, key: String, icon_name: String, label: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.custom_minimum_size = Vector2(0, 92)
	p.add_theme_stylebox_override("panel", UI.box(UI.PANEL, UI.OUTLINE, 3))
	parent.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)
	var ic := UI.add_icon(v, icon_name, 40)
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UI.add_label(v, label, 15, UI.WHITE, true)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var b := Button.new()
	b.flat = true
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func(): play("click"); go(key))
	p.add_child(b)
	return p


func _mark_nav(active: String) -> void:
	for k in nav_buttons.keys():
		var p: PanelContainer = nav_buttons[k]
		p.add_theme_stylebox_override("panel", UI.box(Color("#5a4618") if k == active else UI.PANEL, UI.AMBER if k == active else UI.OUTLINE, 3))


func update_hud() -> void:
	if hud.is_empty():
		return
	hud["pls"].text = "%s PLS" % UI.n(profile.get("balance", 0))
	var ore: Dictionary = profile.get("ore", {})
	for k in ["coal", "iron", "crystal", "void"]:
		hud["ore_" + k].text = UI.n(ore.get(k, 0))
	hud["level"].text = "Lv %s %s" % [UI.n(profile.get("level", 1)), str(profile.get("title", ""))]
	var xs := float(profile.get("xp_level_start", 0))
	var xn := float(profile.get("xp_next", 25))
	hud["xp"].value = clampf((float(profile.get("xp", 0)) - xs) / maxf(1.0, xn - xs), 0.0, 1.0)
	var gear: Dictionary = profile.get("gear", {})
	var pick := "starter"
	if gear.has("pickaxe") and not gear["pickaxe"].get("broken", false):
		pick = str(gear["pickaxe"]["tier"])
	var key := str(profile.get("appearance", {})) + pick
	if key != hero_key:
		hero_key = key
		world.build_hero(profile.get("appearance", {}), pick)
	var pk := str(profile.get("pet", ""))
	if pk != pet_key:
		pet_key = pk
		world.set_pet(pk)


# Merge a server reply into the cached profile.
func apply(r: Dictionary) -> void:
	if r.has("profile"):
		profile = r["profile"]
	if r.has("balance"):
		profile["balance"] = r["balance"]
	if r.has("ore_inv"):
		profile["ore"] = r["ore_inv"]
	if r.has("xp"):
		profile["xp"] = r["xp"]
	if r.has("level"):
		profile["level"] = r["level"]
	if r.has("title"):
		profile["title"] = r["title"]
	if r.has("gear"):
		profile["gear"] = r["gear"]
	update_hud()


func refresh_profile() -> void:
	var r: Dictionary = await api.get_json("/me")
	if r.get("ok", false):
		profile = r["profile"]
		update_hud()


# ---------------------------------------------------------------- travel + panels
func go(place: String) -> void:
	pending_place = place
	_mark_nav(place)
	if place == "town":
		close_panel()
		audio.set_area("town")
		if world.area != "town":
			world.show_area("town")
		else:
			world.walk_to(world.spot_for_place("town"), "town")
		return
	if place == "mine":
		if world.area != "mine":
			close_panel()
			world.show_area("mine")
		open_panel("mine")
		audio.set_area("mine")
		return
	if place == "cabin":
		close_panel()
		world.show_area("cabin")
		audio.set_area("cabin")
		open_panel("cabin")
		return
	audio.set_area({"arena": "arena", "tavern": "tavern"}.get(place, "town"))
	close_panel()
	if world.area != "town":
		world.show_area("town")
	await world.walk_to(world.spot_for_place(place), place)
	if pending_place == place:
		open_panel(place)


func _on_vein_tapped(tier: int) -> void:
	if current != "mine":
		open_panel("mine")
	screens["mine"].select_tier(tier)


func open_panel(pname: String) -> void:
	if not SCREENS.has(pname):
		return
	if current != "" and current != pname:
		close_panel()
	if not screens.has(pname):
		var s = SCREENS[pname].new()
		s.init(self)
		screens[pname] = s
	var screen = screens[pname]
	if screen.get_parent() == null:
		var holder := PanelContainer.new()
		holder.name = "Holder"
		holder.add_theme_stylebox_override("panel", UI.box(Color(0.11, 0.12, 0.14, 0.94), UI.AMBER, 4, 0))
		holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		holder.offset_left = 10
		holder.offset_right = -10
		holder.offset_top = 8
		holder.offset_bottom = -8
		holder.grow_vertical = Control.GROW_DIRECTION_END
		holder.clip_contents = true
		if pname in LOW_PANELS:
			holder.anchor_top = 0.52
		content.add_child(holder)
		holder.add_child(screen)
		content.move_child(toast_label, content.get_child_count() - 1)
	current = pname
	world.low_frame = pname in LOW_PANELS
	node.set_active(pname == "mine" or pname == "expedition")
	tutorial_event("open_" + pname)
	if pname != "profile":
		_mark_nav(pname)
	screen.on_open()


func close_panel() -> void:
	if current == "":
		return
	var screen = screens.get(current)
	current = ""
	world.low_frame = false
	node.set_active(false)
	if screen != null:
		screen.on_close()
		var holder = screen.get_parent()
		if holder != null:
			holder.remove_child(screen)
			content.remove_child(holder)
			holder.queue_free()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if overlay != null:
			return
		if current != "" and not current in LOW_PANELS:
			close_panel()
			_mark_nav(world.area)
		elif world.area in ["expedition", "lake"]:
			go("mine")
		elif world.area != "town":
			go("town")
		else:
			get_tree().quit()


# ---------------------------------------------------------------- feedback
func toast(text: String, color: Color = UI.WHITE) -> void:
	if toast_label == null:
		return
	toast_label.text = text
	toast_label.add_theme_color_override("font_color", color)
	toast_label.visible = true
	toast_label.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_interval(2.4)
	tw.tween_property(toast_label, "modulate:a", 0.0, 0.5)
	tw.tween_callback(func(): toast_label.visible = false)


func error_toast(r: Dictionary) -> void:
	toast(str(r.get("message", r.get("error", "Something went wrong."))), UI.RED)
	play("buzz")


func play(sound: String, pitch: float = 1.0) -> void:
	if settings.get("sound", true) and players.has(sound):
		players[sound].pitch_scale = pitch
		players[sound].play()


# Pickaxe sounds change with the vein: deep thunk on coal, ringing on crystal, eerie on void.
func play_tier(sound: String, tier: int) -> void:
	play(sound, float(TIER_PITCH.get(tier, 1.0)) * randf_range(0.96, 1.04))


func badge_toast(id: String) -> void:
	if id.begins_with("pet:"):
		toast("NEW PET UNLOCKED: %s! Equip it in ME." % id.substr(4).capitalize(), UI.GOLD)
	elif id == "invite_reward":
		toast("Your friend reached level 5 - you both got Lantern Trim!", UI.GOLD)
	else:
		toast("BADGE EARNED: %s" % BADGE_NAMES.get(id, id), UI.GOLD)
	play("rare")
	vibrate(100)


func tutorial_event(name: String) -> void:
	if tutorial != null and is_instance_valid(tutorial):
		tutorial.event(name)


func share_card(body: Dictionary) -> void:
	var r: Dictionary = await api.post("/share/create", body)
	if not r.get("ok", false):
		error_toast(r)
		return
	var url: String = api.base_url + str(r["path"])
	DisplayServer.clipboard_set(url)
	toast("Share link copied! Paste it anywhere.", UI.TEAL_L)
	OS.shell_open(url)


func open_expedition() -> void:
	close_panel()
	_mark_nav("mine")
	world.show_area("expedition", {"tier": 1, "floor": 0})
	audio.set_area("mine")
	open_panel("expedition")


func open_lake() -> void:
	close_panel()
	_mark_nav("mine")
	world.show_area("lake")
	audio.set_area("lake")
	open_panel("fishing")


func vibrate(ms: int) -> void:
	if settings.get("vibrate", true):
		Input.vibrate_handheld(ms)


func _process(delta: float) -> void:
	if api == null or api.token == "" or layout == null or not layout.visible:
		return
	beat += delta
	if beat > 45.0:
		beat = 0.0
		api.post("/heartbeat", {})
	# payday: right after each 10-minute settlement, check whether this phone was paid
	var now_s := int(Time.get_unix_time_from_system())
	var ep := int((now_s - 20) / 600)
	if last_payday_epoch < 0:
		last_payday_epoch = ep
	elif ep != last_payday_epoch:
		last_payday_epoch = ep
		_check_payday()


func _check_payday() -> void:
	var before := int(profile.get("balance", 0))
	var r: Dictionary = await api.get_json("/me")
	if not r.get("ok", false):
		return
	profile = r["profile"]
	update_hud()
	var gained := int(profile.get("balance", 0)) - before
	if gained > 0 and node.ready_state == "ready":
		toast("PAYDAY!  +%d PLS from the network" % gained, UI.GOLD)
		play("payday")
		vibrate(150)
		world.coin_shower()


# ---------------------------------------------------------------- settings
func _load_settings() -> void:
	var s := _read_json(SETTINGS_PATH)
	for k in s.keys():
		settings[k] = s[k]


func save_settings() -> void:
	_write_json(SETTINGS_PATH, settings)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	return data if typeof(data) == TYPE_DICTIONARY else {}


func _write_json(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))
		f.close()
