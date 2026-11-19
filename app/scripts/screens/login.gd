extends VBoxContainer
# Sign in or create an account. Username + password; the server keeps the account.

signal logged_in(token: String, profile: Dictionary)

const UI = preload("res://scripts/ui.gd")
const ApiScript = preload("res://scripts/api.gd")

var M
var user_in: LineEdit
var pass_in: LineEdit
var invite_in: LineEdit
var status: Label
var busy := false


func init(m) -> void:
	M = m
	add_theme_constant_override("separation", 14)
	var card := UI.add_card(self, "deep")
	UI.add_title(card, "PULSE NETWORK", "Mine Pulse ore. Forge your gear. Prove your skill.")
	UI.add_space(card, 8)
	user_in = UI.add_input(card, "Username (3-16 letters, numbers, _)")
	pass_in = UI.add_input(card, "Password (6+ characters)", true)
	invite_in = UI.add_input(card, "Invite code (optional, new accounts)")
	pass_in.text_submitted.connect(func(_t): _go("/auth/login"))
	var row := UI.add_row(card)
	var login := UI.add_button(row, "LOG IN", "amber")
	login.pressed.connect(func(): _go("/auth/login"))
	var create := UI.add_button(row, "CREATE", "teal")
	create.pressed.connect(func(): _go("/auth/register"))
	status = UI.add_label(card, "New here? Pick a name and password, then tap CREATE.", 20, UI.MUTED, true)
	UI.add_label(card, "PLS is a test balance with no cash value. New PLS is only created by your phone acting as a network node while you mine.", 16, UI.MUTED, true)
	var adv := UI.add_button(card, "SERVER SETTINGS", "dark", 48, 18)
	adv.pressed.connect(_server_box)


func _go(path: String) -> void:
	if busy:
		return
	var uname := user_in.text.strip_edges()
	if uname.length() < 3 or pass_in.text.length() < 6:
		status.text = "Usernames need 3+ characters and passwords 6+."
		status.add_theme_color_override("font_color", UI.RED)
		return
	busy = true
	status.text = "Working..."
	status.add_theme_color_override("font_color", UI.MUTED)
	var r: Dictionary = await M.api.post(path, {"username": uname, "password": pass_in.text, "invite": invite_in.text.strip_edges()})
	busy = false
	if r.get("ok", false):
		M.play("coin")
		logged_in.emit(str(r["token"]), r["profile"])
	else:
		status.text = str(r.get("message", "Could not sign in."))
		status.add_theme_color_override("font_color", UI.RED)
		M.play("buzz")


func _server_box() -> void:
	var card := UI.add_card(self, "dark")
	UI.add_label(card, "Server address (leave empty for the default):", 18, UI.MUTED)
	var e := UI.add_input(card, ApiScript.DEFAULT_SERVER)
	e.text = str(M.settings.get("server", ""))
	var save := UI.add_button(card, "SAVE SERVER", "stone", 52, 20)
	save.pressed.connect(func():
		var v := e.text.strip_edges().trim_suffix("/")
		M.settings["server"] = v
		M.api.base_url = v if v != "" else ApiScript.DEFAULT_SERVER
		M.save_settings()
		status.text = "Server set to " + M.api.base_url
	)
