extends VBoxContainer
# THE TAVERN - lobby chat, crew chat, friends + private messages, crews.

const UI = preload("res://scripts/ui.gd")

var M
var tabs := {}
var tab := "lobby"
var body: VBoxContainer
var chat_box: RichTextLabel
var msg_in: LineEdit
var channel := "lobby"
var channel_title := ""
var last_sig := ""
var poll := 0.0
var open := false


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	UI.add_title(self, "THE TAVERN", "")
	tabs = UI.add_tabs(self, ["lobby", "crew", "friends"], ["LOBBY", "CREW", "FRIENDS"], _set_tab)
	body = VBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(body)


func on_open() -> void:
	open = true
	_set_tab(tab)


func on_close() -> void:
	open = false


func _process(delta: float) -> void:
	if not open or chat_box == null or not is_instance_valid(chat_box):
		return
	poll += delta
	if poll > 3.5:
		poll = 0.0
		_load_chat()


func _set_tab(t: String) -> void:
	tab = t
	UI.set_tab(tabs, t)
	UI.clear(body)
	chat_box = null
	last_sig = ""
	if t == "lobby":
		_chat_view("lobby", "LOBBY - public, be kind. Never share private info.")
	elif t == "crew":
		await _crew_view()
	else:
		await _friends_view()


func _chat_view(ch: String, title: String) -> void:
	channel = ch
	channel_title = title
	UI.add_label(body, title, 18, UI.MUTED)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UI.box(Color("#3b2a1c"), UI.OUTLINE, 4))
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(panel)
	chat_box = RichTextLabel.new()
	chat_box.bbcode_enabled = true
	chat_box.scroll_following = true
	chat_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_box.add_theme_font_size_override("normal_font_size", 22)
	chat_box.add_theme_font_size_override("bold_font_size", 22)
	panel.add_child(chat_box)
	var row := UI.add_row(body)
	msg_in = UI.add_input(row, "Say something...")
	msg_in.max_length = 200
	msg_in.text_submitted.connect(func(_t): _send())
	var send := UI.add_button(row, "SEND", "amber", 62, 22)
	send.custom_minimum_size = Vector2(120, 62)
	send.size_flags_horizontal = Control.SIZE_SHRINK_END
	send.pressed.connect(_send)
	var er := UI.add_row(body, 4)
	for e in ["wave", "cheer", "dance", "flex", "laugh", "slump"]:
		var eb := UI.add_button(er, e.to_upper(), "stone", 44, 14)
		var ek: String = e
		eb.pressed.connect(func(): _emote(ek))
	_load_chat()


func _emote(e: String) -> void:
	M.world.hero.emote(e)
	var r: Dictionary = await M.api.post("/emote", {"emote": e})
	if not r.get("ok", false) and str(r.get("error", "")) != "slow_mode":
		M.error_toast(r)
	_load_chat()


func _load_chat() -> void:
	if chat_box == null:
		return
	var ch := channel
	var r: Dictionary = await M.api.get_json("/chat/history?channel=%s" % ch.uri_encode())
	if chat_box == null or not is_instance_valid(chat_box) or ch != channel:
		return
	if not r.get("ok", false):
		chat_box.text = "[color=#E64C4C]%s[/color]" % UI.bb_escape(r.get("message", "Chat unavailable."))
		return
	var msgs: Array = r["messages"]
	var sig := str(msgs.size()) + (str(msgs[-1]["id"]) if not msgs.is_empty() else "")
	if sig == last_sig:
		return
	last_sig = sig
	var me := str(M.profile.get("username", ""))
	var lines := PackedStringArray()
	for m in msgs:
		if m.get("system", false):
			lines.append("[color=#ffd36b][b]* %s *[/b][/color]" % UI.bb_escape(m["text"]))
			continue
		var col := "#FFC93C" if str(m["from"]) == me else "#7fe3d3"
		var crew := "[lb]%s] " % UI.bb_escape(m["crew"]) if str(m.get("crew", "")) != "" else ""
		if m.get("emote") != null:
			lines.append("[i][color=%s]%s %ss[/color][/i]" % [col, UI.bb_escape(m["from"]), UI.bb_escape(m["emote"])])
			continue
		lines.append("[b][color=%s]%s%s[/color][/b] [color=#c8b89a]Lv%s[/color]  %s" % [col, crew, UI.bb_escape(m["from"]), UI.n(m["level"]), UI.bb_escape(m["text"])])
	if lines.is_empty():
		lines.append("[color=#A6A69E]Nobody has spoken yet. Say hello![/color]")
	chat_box.text = "\n".join(lines)


func _send() -> void:
	var text := msg_in.text.strip_edges()
	if text == "":
		return
	msg_in.editable = false
	var r: Dictionary = await M.api.post("/chat/send", {"channel": channel, "text": text})
	msg_in.editable = true
	if r.get("ok", false):
		msg_in.text = ""
		M.play("click")
		_load_chat()
	else:
		M.error_toast(r)


# ------------------------------------------------------------------ crews
func _crew_view() -> void:
	var r: Dictionary = await M.api.get_json("/crew")
	if tab != "crew":
		return
	if not r.get("ok", false):
		M.error_toast(r)
		return
	var crew = r["crew"]
	if crew == null:
		var list := UI.add_scroll(body)
		var c := UI.add_card(list, "dark")
		UI.add_label(c, "You're not in a crew yet.", 22, UI.GOLD)
		UI.add_label(c, "Crews share a private chat and compete on the weekly crew board.", 18, UI.MUTED)
		var jn := UI.add_input(c, "Crew name to join")
		var jb := UI.add_button(c, "JOIN CREW", "teal", 56, 22)
		jb.pressed.connect(func(): _crew_act("/crew/join", {"name": jn.text.strip_edges()}))
		var c2 := UI.add_card(list, "dark")
		UI.add_label(c2, "Start your own crew (%s PLS, burned)" % UI.n(r["cost"]), 20, UI.AMBER)
		var cn := UI.add_input(c2, "Crew name (3-20)")
		var ct := UI.add_input(c2, "Tag (2-4 letters)")
		var cb := UI.add_button(c2, "CREATE CREW", "amber", 56, 22)
		cb.pressed.connect(func(): _crew_act("/crew/create", {"name": cn.text.strip_edges(), "tag": ct.text.strip_edges()}))
		_crew_board(list, r["top"])
		return
	var head := UI.add_row(body)
	UI.add_label(head, "[%s] %s  -  %s veins this week" % [crew["tag"], crew["name"], UI.n(crew["week_blocks"])], 20, UI.GOLD)
	var more := UI.add_button(head, "MEMBERS", "stone", 50, 18)
	more.custom_minimum_size = Vector2(150, 50)
	more.size_flags_horizontal = Control.SIZE_SHRINK_END
	more.pressed.connect(func(): _crew_members(crew, r["top"]))
	_chat_view("crew", "CREW CHAT - only your crew can read this.")


func _crew_members(crew: Dictionary, top: Array) -> void:
	UI.clear(body)
	chat_box = null
	var list := UI.add_scroll(body)
	var c := UI.add_card(list, "dark")
	UI.add_label(c, "[%s] %s" % [crew["tag"], crew["name"]], 24, UI.GOLD)
	for m in crew["members"]:
		UI.add_label(c, "%s%s  Lv%s  -  %s veins%s" % ["(lead) " if m["owner"] else "", m["username"], UI.n(m["level"]), UI.n(m["week_blocks"]), "  ONLINE" if m["online"] else ""], 18, UI.GREEN if m["online"] else UI.WHITE)
	var back := UI.add_button(c, "BACK TO CREW CHAT", "teal", 54, 20)
	back.pressed.connect(func(): _set_tab("crew"))
	var leave := UI.add_button(c, "LEAVE CREW", "red", 54, 20)
	leave.pressed.connect(func(): _crew_act("/crew/leave", {}))
	_crew_board(list, top)


func _crew_board(parent: Node, top: Array) -> void:
	var c := UI.add_card(parent, "deep")
	UI.add_label(c, "TOP CREWS THIS WEEK", 20, UI.AMBER)
	var i := 1
	for t in top:
		UI.add_label(c, "#%d [%s] %s - %s veins (%s members)" % [i, t["tag"], t["name"], UI.n(t["week_blocks"]), UI.n(t["members"])], 18)
		i += 1
	if top.is_empty():
		UI.add_label(c, "No crews yet - be the first.", 18, UI.MUTED)


func _crew_act(path: String, data: Dictionary) -> void:
	var r: Dictionary = await M.api.post(path, data)
	if r.get("ok", false):
		M.toast("Done!", UI.TEAL_L)
		M.refresh_profile()
	else:
		M.error_toast(r)
	_set_tab("crew")


# ------------------------------------------------------------------ friends
func _friends_view() -> void:
	var r: Dictionary = await M.api.get_json("/friends")
	if tab != "friends":
		return
	if not r.get("ok", false):
		M.error_toast(r)
		return
	var list := UI.add_scroll(body)
	var add := UI.add_card(list, "dark")
	var row := UI.add_row(add)
	var name_in := UI.add_input(row, "Add a friend by username")
	var ab := UI.add_button(row, "ADD", "teal", 62, 22)
	ab.custom_minimum_size = Vector2(110, 62)
	ab.size_flags_horizontal = Control.SIZE_SHRINK_END
	ab.pressed.connect(func(): _friend_act("/friend/request", {"username": name_in.text.strip_edges()}, "Request sent!"))
	for p in r["pending"]:
		var pc := UI.add_card(list, "gold")
		UI.add_label(pc, "%s wants to be friends" % p["from"], 20, UI.GOLD)
		var pr := UI.add_row(pc)
		var pid: String = p["id"]
		UI.add_button(pr, "ACCEPT", "green", 52, 20).pressed.connect(func(): _friend_act("/friend/respond", {"id": pid, "accept": true}, "Friend added!"))
		UI.add_button(pr, "DECLINE", "red", 52, 20).pressed.connect(func(): _friend_act("/friend/respond", {"id": pid, "accept": false}, "Declined."))
	for f in r["friends"]:
		var fc := UI.add_card(list, "dark")
		var doing := ""
		if f.get("mining", false):
			doing = "MINING NOW"
		elif f.get("doing") != null and f["online"]:
			doing = "in the %s" % str(f["doing"])
		UI.add_label(fc, "%s  Lv%s  %s" % [f["username"], UI.n(f["level"]), doing if doing != "" else ("ONLINE" if f["online"] else "offline")], 20, UI.GOLD if f.get("mining", false) else (UI.GREEN if f["online"] else UI.WHITE))
		var fr := UI.add_row(fc)
		var fname: String = f["username"]
		var dm_channel: String = f["channel"]
		UI.add_button(fr, "MESSAGE", "teal", 52, 20).pressed.connect(func():
			UI.clear(body)
			_chat_view(dm_channel, "PRIVATE CHAT WITH %s" % fname.to_upper())
		)
		UI.add_button(fr, "CHALLENGE", "amber", 52, 20).pressed.connect(func():
			M.pending_challenge = fname
			M.go("arena")
		)
		UI.add_button(fr, "VISIT", "stone", 52, 20).pressed.connect(func():
			M.go("cabin")
			if M.screens.has("cabin"):
				M.screens["cabin"].visit(fname)
				M.screens["cabin"].on_open()
		)
	if r["friends"].is_empty() and r["pending"].is_empty():
		UI.add_label(list, "No friends yet. Add someone by their username.", 18, UI.MUTED)


func _friend_act(path: String, data: Dictionary, ok_text: String) -> void:
	var r: Dictionary = await M.api.post(path, data)
	if r.get("ok", false):
		M.toast(ok_text, UI.TEAL_L)
	else:
		M.error_toast(r)
	_set_tab("friends")
