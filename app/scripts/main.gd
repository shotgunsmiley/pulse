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
	"boss": preload("res://scripts/screens/boss_panel.gd"),
}
const TutorialScript = preload("res://scripts/tutorial.gd")
const MinimapScript = preload("res://scripts/minimap.gd")
const PixelFont = preload("res://scripts/pixel_font.gd")
const LOW_PANELS := ["mine", "expedition", "fishing", "cabin", "boss"]
const TIER_PITCH := {1: 0.85, 2: 1.0, 3: 1.25, 4: 0.7}
const BADGE_NAMES := {"founding": "Founding Miner", "first_vein": "First Crack", "veins_100": "Seasoned Miner",
	"veins_1000": "Mountain Mover", "streak_10": "On Fire", "streak_25": "Inferno", "node_1h": "Node Online",
	"node_10h": "Node Veteran", "node_100h": "Backbone", "gem_first": "Glitter", "duel_1": "First Blood",
	"duel_25": "Duelist", "angler": "Angler", "deep_8": "Deep Diver", "deep_15": "Abyss Walker",
	"slay_golem": "Golem Slayer", "slay_wyrm": "Wyrm Slayer", "slay_spider": "Spider Slayer", "slay_wraith": "Wraith Slayer",
	"slay_drake": "Drake Slayer", "monster_hunter": "Monster Hunter", "boss_mvp": "Champion of the Square", "final_blow": "Final Blow"}
const SOUNDS := ["clink", "thud", "coin", "rare", "levelup", "rune0", "rune1", "rune2", "rune3", "buzz", "go",
	"anvil", "click", "flip", "roll", "boom", "win", "lose", "payday", "chime", "horn", "roar", "mhit", "victory", "escape"]
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
var msg_log: VBoxContainer = null     # the game log: last few lines of what just happened
var daily := {}                       # today's forecast, cart, chest, knight target, merchant (from /me)
var forge_badge: Label = null         # the red "!" on FORGE when gear needs repair
var photo := false
const TIPS := [
	"Tip: a strike in the gold is perfect - three in a row make your pick glow.",
	"Tip: the mine cart comes once a day. Check the mine.",
	"Tip: play 5 days in a week to open the weekly chest.",
	"Tip: press and hold anything in the world to examine it.",
	"Tip: beat the Training Knight in a Quickdraw practice for a daily ore purse.",
	"Tip: repairs take ore, and better ore counts.",
	"Tip: rain in town means the fish bite - extra xp at the lake.",
	"Tip: name your pickaxe at the Forge. It deserves it.",
	"Tip: a crew that mines together gets +10% ore.",
	"Tip: the merchant visits at the weekend with a rare dye.",
]
var minimap = null
var last_payday_epoch := -1
var audio    # audio.gd: ambience and music
# v5.5 world bosses
var boss := {}                # the latest /boss answer
var boss_at_ms := 0           # when it arrived (the clocks tick locally from here)
var boss_book := {}           # monster -> name, trick, loot
var bestiary := {}            # monster -> kills, fights, best damage, escapes
var boss_log := []
var boss_poll := 2.0
var boss_banner: PanelContainer = null
var boss_banner_label: Label = null
var boss_banner_btn: Button = null
var boss_heard := {}          # "<k>:<what>" -> true, so each warning plays once
var boss_rewards_seen := {}
var boss_banner_t := 0.0


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
	world.examined.connect(func(t: String): log_msg(t, UI.TEAL_L))
	world.photo_tapped.connect(end_photo_mode)
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
	UI.add_label(box, TIPS[randi() % TIPS.size()], 18, UI.TEAL_L, true).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	if me.has("daily"):
		_handle_me(me)
	else:
		_fetch_me_extras()
	if not prof.get("tutorial", true) and tutorial == null:
		tutorial = TutorialScript.new()
		tutorial.setup(self)
		tutorial.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		tutorial.offset_top = 150 + safe_top
		tutorial.offset_left = 16
		tutorial.offset_right = -16
		tutorial.finished.connect(func(): tutorial = null)
		ui_root.add_child(tutorial)
		tutorial.on_screen(current)


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
	_build_boss_banner()
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
	_build_world_overlay()
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
	var shown := str(profile.get("shown_title", ""))
	hud["level"].text = "Lv %s %s" % [UI.n(profile.get("level", 1)), shown if shown != "" else str(profile.get("title", ""))]
	var xs := float(profile.get("xp_level_start", 0))
	var xn := float(profile.get("xp_next", 25))
	hud["xp"].value = clampf((float(profile.get("xp", 0)) - xs) / maxf(1.0, xn - xs), 0.0, 1.0)
	var gear: Dictionary = profile.get("gear", {})
	var pick := "starter"
	if gear.has("pickaxe") and not gear["pickaxe"].get("broken", false):
		pick = str(gear["pickaxe"]["tier"])
	var look: Dictionary = profile.get("appearance", {}).duplicate()
	look["crew_color"] = int(profile.get("crew_color", -1))
	var key := str(look) + pick
	if key != hero_key:
		hero_key = key
		world.build_hero(look, pick)
	world.pick_nick = str(gear.get("pickaxe", {}).get("nick", "")) if gear.has("pickaxe") else ""
	# repair reminder on the FORGE button
	var worn := false
	for slot in gear.keys():
		var g: Dictionary = gear[slot]
		if float(g.get("dur", 1)) < 0.2 * float(g.get("max_dur", 1)):
			worn = true
	if forge_badge == null and nav_buttons.has("forge"):
		forge_badge = Label.new()
		forge_badge.text = "!"
		forge_badge.add_theme_font_size_override("font_size", 30)
		forge_badge.add_theme_color_override("font_color", UI.RED)
		forge_badge.add_theme_color_override("font_outline_color", Color.BLACK)
		forge_badge.add_theme_constant_override("outline_size", 6)
		forge_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		forge_badge.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		forge_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		nav_buttons["forge"].add_child(forge_badge)
	if forge_badge:
		forge_badge.visible = worn
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
	if place == "boss":
		open_boss()
		return
	pending_place = place
	_mark_nav(place)
	if place == "town":
		close_panel()
		audio.set_area("boss" if str(boss.get("state", "")) == "live" else "town")
		_fetch_leaders()
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
	_place_world_overlay()
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
	if tutorial != null and is_instance_valid(tutorial):
		tutorial.on_screen("")
	_place_world_overlay()
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
		if current == "boss":
			go("town")
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


# ---------------------------------------------------------------- game log + minimap
func _build_world_overlay() -> void:
	msg_log = VBoxContainer.new()
	msg_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	msg_log.alignment = BoxContainer.ALIGNMENT_END
	msg_log.add_theme_constant_override("separation", 2)
	msg_log.grow_vertical = Control.GROW_DIRECTION_BEGIN
	content.add_child(msg_log)
	minimap = MinimapScript.new()
	minimap.setup(self)
	minimap.anchor_left = 1.0
	minimap.anchor_right = 1.0
	minimap.offset_left = -minimap.custom_minimum_size.x - 12
	minimap.offset_right = -12
	minimap.offset_top = 12
	minimap.offset_bottom = 12 + minimap.custom_minimum_size.y
	content.add_child(minimap)
	_place_world_overlay()


# The log sits just above whatever covers the bottom of the world view.
func _place_world_overlay() -> void:
	if msg_log == null:
		return
	var low := current in LOW_PANELS
	var full := current != "" and not low
	msg_log.visible = not full
	minimap.visible = not full and world.area != "cabin"
	var y := 0.52 if low else 1.0
	msg_log.anchor_left = 0.0
	msg_log.anchor_right = 0.78
	msg_log.anchor_top = y
	msg_log.anchor_bottom = y
	msg_log.offset_left = 14
	msg_log.offset_right = 0
	msg_log.offset_bottom = -2 if low else -10
	msg_log.offset_top = msg_log.offset_bottom - 4 * 30


func log_msg(text: String, color: Color = UI.WHITE) -> void:
	if msg_log == null:
		return
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", PixelFont.font())
	l.add_theme_font_size_override("font_size", PixelFont.SIZE * 2)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	l.add_theme_constant_override("outline_size", 6)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	msg_log.add_child(l)
	while msg_log.get_child_count() > 4:
		var old := msg_log.get_child(0)
		msg_log.remove_child(old)
		old.queue_free()
	var tw := l.create_tween()
	tw.tween_interval(7.0)
	tw.tween_property(l, "modulate:a", 0.0, 1.2)
	tw.tween_callback(l.queue_free)


func _fetch_leaders() -> void:
	var r: Dictionary = await api.get_json("/leaderboard")
	if r.get("ok", false):
		var names := []
		for row in r.get("top", []):
			if typeof(row) == TYPE_DICTIONARY:
				names.append(str(row.get("username", row.get("name", "?"))))
		world.set_leaders(names)


# ---------------------------------------------------------------- daily info, inbox, "while you were away"
func _fetch_me_extras() -> void:
	var r: Dictionary = await api.get_json("/me")
	if r.get("ok", false):
		profile = r["profile"]
		update_hud()
		_handle_me(r)


func _handle_me(r: Dictionary) -> void:
	if r.has("daily"):
		daily = r["daily"]
		world.set_rain(bool(daily.get("forecast", {}).get("rain", false)))
		world.set_merchant(bool(daily.get("merchant", {}).get("here", false)))
	var away = r.get("away")
	if away != null and typeof(away) == TYPE_DICTIONARY:
		var parts := ["Welcome back! You were away %d hours." % int(away["hours"])]
		if int(away.get("node_pls", 0)) > 0:
			parts.append("Your phone node earned %d PLS." % int(away["node_pls"]))
		if int(away.get("duels_won", 0)) + int(away.get("duels_lost", 0)) > 0:
			parts.append("Duels settled: %d won, %d lost." % [int(away["duels_won"]), int(away["duels_lost"])])
		if away.get("comeback", false):
			parts.append("Comeback bonus: double xp for 30 minutes!")
		for line in parts:
			log_msg(line, UI.GOLD)
		toast(parts[0] + ("  Double xp for 30 min!" if away.get("comeback", false) else ""), UI.GOLD)
	for it in r.get("inbox", []):
		match str(it.get("kind", "")):
			"wave":
				log_msg("%s waves at you." % str(it.get("from", "")), UI.TEAL_L)
			"gift":
				log_msg("%s sent you %d %s." % [str(it.get("from", "")), int(it.get("qty", 0)), str(it.get("ore", ""))], UI.GOLD)
			"like":
				log_msg("%s liked your cabin." % str(it.get("from", "")), UI.TEAL_L)
			"news":
				log_msg(str(it.get("text", "")), UI.TEAL_L)
	if bool(daily.get("chest_ready", false)):
		garrick_once("chest", "You've been down here five days this week. There's a chest in the mine with your name on it.")


# Different buzz patterns so you can feel what happened without looking.
func vibrate_pattern(kind: String) -> void:
	if not settings.get("vibrate", true):
		return
	var pat: Array = {"perfect": [35], "great": [22], "good": [14], "gem": [40, 70, 40], "level": [60, 60, 60, 60, 120]}.get(kind, [20])
	for i in range(pat.size()):
		if i % 2 == 0:
			Input.vibrate_handheld(int(pat[i]))
		if i < pat.size() - 1:
			await get_tree().create_timer(float(pat[i]) / 1000.0 + 0.03).timeout


# Garrick says something the first time a thing happens - once only, ever.
func garrick_once(key: String, text: String) -> void:
	var seen: Array = settings.get("quips", [])
	if key in seen:
		return
	seen.append(key)
	settings["quips"] = seen
	save_settings()
	log_msg("Garrick: " + text, Color("#ffd36b"))


# Photo mode: hide every menu until you tap the screen.
func photo_mode() -> void:
	close_panel()
	_mark_nav(world.area)
	photo = true
	layout.visible = false
	if tutorial != null and is_instance_valid(tutorial):
		tutorial.visible = false
	world.photo_mode = true
	var hint := Label.new()
	hint.text = "PHOTO MODE - drag to turn, tap to return"
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_outline_color", Color.BLACK)
	hint.add_theme_constant_override("outline_size", 6)
	hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	hint.offset_top = 40 + safe_top
	ui_root.add_child(hint)
	var tw := hint.create_tween()
	tw.tween_interval(2.5)
	tw.tween_property(hint, "modulate:a", 0.0, 0.6)
	tw.tween_callback(hint.queue_free)


func end_photo_mode() -> void:
	if not photo:
		return
	photo = false
	layout.visible = true
	world.photo_mode = false
	if tutorial != null and is_instance_valid(tutorial):
		tutorial.visible = true


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
	_boss_tick(delta)
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
	_handle_me(r)
	var gained := int(profile.get("balance", 0)) - before
	if gained > 0 and node.ready_state == "ready":
		toast("PAYDAY!  +%d PLS from the network" % gained, UI.GOLD)
		log_msg("Payday: the network paid you %d PLS." % gained, UI.GOLD)
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



# ===================================================================== v5.5 WORLD BOSSES
# One shared monster for everybody. We ask the server what it is doing every few seconds
# (slower when nothing is happening), show a banner on every screen during the 3-minute
# countdown and the fight, sound the horn, and show what you won afterwards.

func _build_boss_banner() -> void:
	boss_banner = PanelContainer.new()
	boss_banner.add_theme_stylebox_override("panel", UI.box(Color("#3a1712"), Color("#ff9a5a"), 3, 0))
	boss_banner.visible = false
	layout.add_child(boss_banner)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	boss_banner.add_child(row)
	boss_banner_label = Label.new()
	boss_banner_label.add_theme_font_size_override("font_size", 21)
	boss_banner_label.add_theme_color_override("font_color", Color("#ffd36b"))
	boss_banner_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	boss_banner_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	boss_banner_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(boss_banner_label)
	boss_banner_btn = UI.add_button(row, "GO", "red", 52, 20)
	boss_banner_btn.custom_minimum_size = Vector2(124, 52)
	boss_banner_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	boss_banner_btn.pressed.connect(open_boss)


func poll_boss_soon() -> void:
	boss_poll = minf(boss_poll, 0.4)


func _boss_tick(delta: float) -> void:
	boss_poll -= delta
	if boss_poll <= 0.0:
		boss_poll = 30.0
		_poll_boss()
	boss_banner_t -= delta
	if boss_banner_t <= 0.0:
		boss_banner_t = 0.25
		_update_boss_banner()


func _boss_age() -> float:
	return (Time.get_ticks_msec() - boss_at_ms) / 1000.0


func _poll_boss() -> void:
	var r: Dictionary = await api.get_json("/boss")
	if not r.get("ok", false):
		boss_poll = 20.0
		return
	if r.has("monsters"):
		boss_book = r["monsters"]
	if r.has("bestiary"):
		bestiary = r["bestiary"]
	if r.has("log"):
		boss_log = r["log"]
	on_boss_view(r)
	if r.get("reward") != null and typeof(r["reward"]) == TYPE_DICTIONARY:
		show_boss_reward(r["reward"])


func on_boss_view(v: Dictionary) -> void:
	var prev := str(boss.get("state", "idle"))
	var prev_k := int(boss.get("k", -1))
	boss = v
	boss_at_ms = Time.get_ticks_msec()
	var st := str(v.get("state", "idle"))
	var k := int(v.get("k", -1))
	var nm := str(v.get("name", "monster"))
	world.set_boss(v, str(profile.get("username", "")))
	# when to ask again
	match st:
		"countdown":
			boss_poll = clampf(float(v.get("spawn_in", 5)) + 0.5, 0.5, 6.0)
		"live":
			boss_poll = 2.0 if current == "boss" else 4.0
		"won", "escaped":
			boss_poll = 12.0
		_:
			var nxt: Dictionary = v.get("next", {})
			boss_poll = clampf(float(nxt.get("in_s", 30)) + 0.5, 1.0, 30.0)
	# warnings: once per event
	if st == "countdown" and not boss_heard.has("%d:c" % k):
		boss_heard["%d:c" % k] = true
		play("horn")
		vibrate_pattern("level")
		toast("A %s IS COMING!  Meet in the town square." % nm.to_upper(), Color("#ffd36b"))
		log_msg("Garrick: %s Trick: %s" % [nm + " incoming!", str(v.get("trick", ""))], Color("#ffd36b"))
	if st == "live" and not boss_heard.has("%d:l" % k):
		boss_heard["%d:l" % k] = true
		play("roar")
		vibrate(200)
		if world.area == "town":
			world.shake = maxf(world.shake, 0.5)
		toast("THE %s IS HERE!  Tap FIGHT to join." % nm.to_upper(), UI.RED)
		if current == "boss" or (world.area == "town" and current == ""):
			audio.set_area("boss")
	if st in ["won", "escaped"] and prev == "live" and prev_k == k and not boss_heard.has("%d:e" % k):
		boss_heard["%d:e" % k] = true
		play("victory" if st == "won" else "escape")
		if st == "won":
			log_msg("The %s is defeated! %d miners fought it." % [nm, int(v.get("fighters", 0))], UI.GOLD)
		else:
			log_msg("The %s got away... it will be back." % nm, UI.MUTED)
		if world.area == "town":
			audio.set_area("town")
	if current == "boss" and screens.has("boss"):
		screens["boss"].on_view(v)
	_update_boss_banner()


func _update_boss_banner() -> void:
	if boss_banner == null:
		return
	var st := str(boss.get("state", "idle"))
	var age := _boss_age()
	var nm := str(boss.get("name", "")).to_upper()
	var show := false
	match st:
		"countdown":
			var left := maxf(0.0, float(boss.get("spawn_in", 0)) - age)
			boss_banner_label.text = "%s arrives in %d:%02d" % [nm, int(left) / 60, int(left) % 60]
			boss_banner_btn.text = "GO"
			show = true
			var k := int(boss.get("k", -1))
			if left <= 60.0 and left > 50.0 and not boss_heard.has("%d:60" % k):
				boss_heard["%d:60" % k] = true
				play("chime")
				log_msg("One minute until the %s arrives!" % str(boss.get("name", "monster")), Color("#ffd36b"))
			if left <= 10.0 and left > 0.5 and not boss_heard.has("%d:10" % k):
				boss_heard["%d:10" % k] = true
				play("horn", 1.25)
			# the banner glows faster as it gets close
			var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 1000.0 * (2.0 + 8.0 * (1.0 - minf(1.0, left / 60.0))))
			boss_banner.modulate = Color(1, 1, 1).lerp(Color(1.25, 1.1, 1.0), pulse)
		"live":
			var hp := float(boss.get("hp", 0))
			var mx := maxf(1.0, float(boss.get("max_hp", 1)))
			var left2 := maxf(0.0, float(boss.get("time_left", 0)) - age)
			boss_banner_label.text = "%s  %d%%  -  %d fighting  -  %d:%02d" % [nm, int(ceil(100.0 * hp / mx)), int(boss.get("fighting_now", 0)), int(left2) / 60, int(left2) % 60]
			boss_banner_btn.text = "FIGHT"
			boss_banner.modulate = Color.WHITE
			show = true
		"won", "escaped":
			show = age < 25.0
			boss_banner_label.text = ("%s DEFEATED!" % nm) if st == "won" else ("%s GOT AWAY" % nm)
			boss_banner_btn.text = "SEE"
			boss_banner.modulate = Color.WHITE
	boss_banner.visible = show and layout != null and layout.visible
	boss_banner_btn.visible = current != "boss"


func open_boss() -> void:
	close_panel()
	_mark_nav("town")
	pending_place = "boss"
	if world.area != "town":
		world.show_area("town")
	open_panel("boss")


func show_boss_reward(rw: Dictionary) -> void:
	var key := "%s:%s" % [str(rw.get("k", "")), str(rw.get("monster", ""))]
	if boss_rewards_seen.has(key):
		return
	boss_rewards_seen[key] = true
	# let the monster fall (or flee) before the loot screen covers it
	var m = world.monster
	if world.area == "town" and m != null and is_instance_valid(m) and m.dead:
		await get_tree().create_timer(3.6).timeout
	refresh_profile()
	_poll_boss_book()
	var won: bool = not rw.get("escaped", false)
	if not won:
		# it got away: a small consolation, told quietly (no screen in the way)
		var bits := []
		var ore0: Dictionary = rw.get("ore", {})
		for k in ore0.keys():
			bits.append("%s %s" % [UI.n(ore0[k]), UI.ore_name(str(k)).to_lower()])
		var line := "The %s got away. You keep %s and %d xp." % [str(rw.get("name", "monster")), ", ".join(PackedStringArray(bits)), int(rw.get("xp", 0))]
		toast(line, UI.MUTED)
		log_msg(line, UI.MUTED)
		return
	var v := _show_overlay()
	var card := UI.add_card(v, "dark")
	UI.add_label(card, ("VICTORY!" if won else "IT GOT AWAY..."), 40, UI.GOLD if won else UI.MUTED, true)
	UI.add_label(card, ("The %s is defeated." if won else "The %s escaped. You keep a little loot.") % str(rw.get("name", "monster")), 22, UI.WHITE, true)
	UI.add_space(card, 6)
	UI.add_label(card, "Your damage: %s  (%d%% of the fight)" % [UI.n(rw.get("damage", 0)), int(round(float(rw.get("share", 0)) * 100.0))], 22, UI.TEAL_L, true)
	if rw.get("mvp", false):
		UI.add_label(card, "CHAMPION OF THE SQUARE - most damage!", 22, UI.GOLD, true)
	if rw.get("final_blow", false):
		UI.add_label(card, "You landed the FINAL BLOW!", 22, UI.GOLD, true)
	var row := UI.add_row(card, 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var ore: Dictionary = rw.get("ore", {})
	for k in ore.keys():
		UI.add_icon(row, UI.ORE_ICONS.get(str(k), "coal"), 34)
		UI.add_label(row, "+%s" % UI.n(ore[k]), 24, UI.WHITE)
	UI.add_label(card, "+%s xp" % UI.n(rw.get("xp", 0)), 24, Color("#9be8ff"), true)
	if rw.get("gem") != null:
		UI.add_label(card, "+1 %s!" % str(rw["gem"]).to_upper(), 24, UI.GOLD, true)
	for b in rw.get("badges", []):
		UI.add_label(card, "BADGE: %s" % BADGE_NAMES.get(str(b), str(b)), 22, UI.GOLD, true)
	UI.add_space(card, 8)
	var ok := UI.add_button(card, "HOORAY!" if won else "NEXT TIME", "amber" if won else "stone", 70, 26)
	ok.pressed.connect(_close_overlay)
	if won:
		play("rare")
		vibrate_pattern("level")
		if world.area == "town":
			world.level_up_fx(int(profile.get("level", 1)))


func _poll_boss_book() -> void:
	var r: Dictionary = await api.get_json("/boss")
	if r.get("ok", false):
		bestiary = r.get("bestiary", bestiary)
		boss_log = r.get("log", boss_log)
