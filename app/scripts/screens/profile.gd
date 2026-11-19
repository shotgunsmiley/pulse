extends VBoxContainer
# PROFILE - your adventurer's look (option C: one hero, customisable), the
# cosmetics shop (a PLS sink), stats, settings and log out.

const UI = preload("res://scripts/ui.gd")
const MD = preload("res://scripts/model_data.gd")
const SLOTS := [["skin", "SKIN", 5], ["face", "FACE", 6], ["hair_style", "HAIR", 4], ["hair_color", "HAIR COLOUR", 6], ["shirt", "TUNIC", 6],
	["pants", "TROUSERS", 4], ["accent", "TRIM", 5]]
const FREE := {"skin": [0, 1, 2, 3, 4], "face": [0, 1, 2, 3], "hair_style": [0, 1], "hair_color": [0, 1, 2], "shirt": [0, 1], "pants": [0, 1], "accent": [0]}
const FACE_NAMES := ["Plain", "Freckles", "Moustache", "Short Beard", "Scarred Veteran", "Grand Beard"]

var M
var tabs := {}
var tab := "look"
var body: VBoxContainer
var draft := {}
var shop := []


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	UI.add_title(self, "YOUR PROFILE", "")
	tabs = UI.add_tabs(self, ["look", "shop", "badges", "stats", "settings"], ["LOOK", "SHOP", "BADGES", "STATS", "MORE"], _set_tab)
	body = UI.add_scroll(self)


func on_open() -> void:
	draft = M.profile.get("appearance", {}).duplicate()
	_set_tab(tab)


func on_close() -> void:
	# put the hero back to the saved look if a preview was not saved
	M.hero_key = ""
	M.update_hud()


func _set_tab(t: String) -> void:
	tab = t
	UI.set_tab(tabs, t)
	UI.clear(body)
	match t:
		"look":
			_look()
		"shop":
			await _shop()
		"stats":
			_stats()
		"badges":
			await _badges()
		"settings":
			_settings()


func _owned(slot: String, v: int) -> bool:
	return FREE[slot].has(v) or M.profile.get("cosmetics", []).has("%s_%d" % [slot, v])


func _look() -> void:
	UI.add_label(body, "Changes preview on your adventurer right away. Locked styles are in the SHOP.", 18, UI.MUTED)
	for s in SLOTS:
		var slot: String = s[0]
		var count: int = s[2]
		var card := UI.add_card(body, "dark")
		var row := UI.add_row(card)
		UI.add_label(row, s[1], 20, UI.AMBER)
		var prev := UI.add_button(row, "<", "stone", 52, 24)
		prev.custom_minimum_size = Vector2(70, 52)
		var v := int(draft.get(slot, 0))
		var lock := "" if _owned(slot, v) else "  (locked)"
		var shown := "%d / %d" % [v + 1, count]
		if slot == "face":
			shown = FACE_NAMES[clampi(v, 0, FACE_NAMES.size() - 1)]
		elif slot == "accent" and v == 4:
			shown = "Lantern Trim"
		var lab := UI.add_label(row, shown + lock, 20, UI.WHITE if lock == "" else UI.RED, true)
		var nxt := UI.add_button(row, ">", "stone", 52, 24)
		nxt.custom_minimum_size = Vector2(70, 52)
		prev.pressed.connect(func(): _step(slot, count, -1))
		nxt.pressed.connect(func(): _step(slot, count, 1))
	var save := UI.add_button(body, "SAVE LOOK", "amber", 64, 26)
	save.pressed.connect(_save_look)


func _step(slot: String, count: int, d: int) -> void:
	draft[slot] = posmod(int(draft.get(slot, 0)) + d, count)
	_preview()
	_set_tab("look")


func _preview() -> void:
	var gear: Dictionary = M.profile.get("gear", {})
	var pick := "starter"
	if gear.has("pickaxe") and not gear["pickaxe"].get("broken", false):
		pick = str(gear["pickaxe"]["tier"])
	M.world.build_hero(draft, pick)


func _save_look() -> void:
	for s in SLOTS:
		if not _owned(s[0], int(draft.get(s[0], 0))):
			M.toast("Buy the locked style in the SHOP first.", UI.AMBER)
			return
	var r: Dictionary = await M.api.post("/profile/appearance", {"appearance": draft})
	if r.get("ok", false):
		M.profile["appearance"] = r["appearance"]
		M.hero_key = ""
		M.update_hud()
		M.play("coin")
		M.toast("Look saved!", UI.GOLD)
	else:
		M.error_toast(r)


func _shop() -> void:
	if shop.is_empty():
		var r: Dictionary = await M.api.get_json("/shop")
		if not r.get("ok", false):
			M.error_toast(r)
			return
		shop = r["items"]
	if tab != "shop":
		return
	UI.add_label(body, "Cosmetics only - they never change how the game plays. PLS spent here is burned.", 18, UI.MUTED)
	var owned: Array = M.profile.get("cosmetics", [])
	for item in shop:
		var card := UI.add_card(body, "dark")
		var row := UI.add_row(card)
		UI.add_label(row, str(item["name"]), 22, UI.WHITE)
		var iid: String = item["id"]
		if owned.has(iid):
			UI.add_label(row, "OWNED", 18, UI.GREEN)
		else:
			var b := UI.add_button(row, "%s PLS" % UI.n(item["price"]), "amber", 52, 20)
			b.custom_minimum_size = Vector2(150, 52)
			b.size_flags_horizontal = Control.SIZE_SHRINK_END
			b.disabled = float(M.profile.get("balance", 0)) < float(item["price"])
			b.pressed.connect(func(): _buy(iid))


func _buy(iid: String) -> void:
	var r: Dictionary = await M.api.post("/shop/buy", {"item": iid})
	if r.get("ok", false):
		M.profile["cosmetics"] = r["cosmetics"]
		M.apply({"balance": r["balance"]})
		M.play("rare")
		M.toast("Unlocked! Equip it on the LOOK tab.", UI.GOLD)
	else:
		M.error_toast(r)
	_set_tab("shop")


func _stats() -> void:
	var vc := UI.add_card(body, "teal")
	var gems: Dictionary = M.profile.get("gems", {})
	UI.add_label(vc, "Best streak: %s perfect strikes   -   Deepest expedition: floor %s" % [UI.n(M.profile.get("best_streak", 0)), UI.n(M.profile.get("deepest", 0))], 18, UI.TEAL_L)
	UI.add_label(vc, "Gems: %s amber, %s garnet, %s sapphire, %s voidstone   -   Fish caught: %s" % [UI.n(gems.get("amber", 0)), UI.n(gems.get("garnet", 0)),
		UI.n(gems.get("sapphire", 0)), UI.n(gems.get("voidstone", 0)), UI.n(M.profile.get("fish_total", 0))], 17)
	var p: Dictionary = M.profile
	var c := UI.add_card(body, "deep")
	UI.add_label(c, str(p.get("username", "")), 30, UI.GOLD)
	UI.add_label(c, "Level %s %s  -  %s XP" % [UI.n(p.get("level", 1)), str(p.get("title", "")), UI.n(p.get("xp", 0))], 20)
	var crew = p.get("crew")
	if crew != null:
		UI.add_label(c, "Crew: [%s] %s" % [crew["tag"], crew["name"]], 20, UI.TEAL_L)
	UI.add_label(c, "Veins cleared: %s today, %s this week, %s total" % [UI.n(p.get("day_blocks", 0)), UI.n(p.get("week_blocks", 0)), UI.n(p.get("lifetime_blocks", 0))], 18)
	UI.add_label(c, "Duels: %s won, %s lost, %s drawn" % [UI.n(p.get("wins", 0)), UI.n(p.get("losses", 0)), UI.n(p.get("draws", 0))], 18)
	var ranks: Dictionary = p.get("ranks", {})
	var elo: Dictionary = p.get("elo", {})
	var best: Dictionary = p.get("best", {})
	for g in ["quickdraw", "sequence", "sniper"]:
		UI.add_label(c, "%s: %s (%s), best %s" % [UI.game_name(g), str(ranks.get(g, "Bronze")), UI.n(elo.get(g, 1200)), UI.n(best.get(g))], 18, UI.MUTED)
	var luck: Dictionary = p.get("luck", {})
	UI.add_label(c, "Gambit Hall: %s bets, %s PLS wagered, %s paid out" % [UI.n(luck.get("bets", 0)), UI.n(luck.get("wagered", 0)), UI.n(luck.get("paid", 0))], 18, UI.MUTED)
	if p.get("flagged", false):
		UI.add_label(c, "Your strikes are being capped at GOOD after an unusual run of perfect hits.", 18, UI.RED)
	await _node_card()


func _node_card() -> void:
	var c := UI.add_card(body, "dark")
	UI.add_label(c, "THIS PHONE AS A NODE", 24, UI.GOLD)
	var r: Dictionary = await M.api.get_json("/node/status")
	if not is_instance_valid(c) or tab != "stats":
		return
	if not r.get("ok", false):
		UI.add_label(c, str(r.get("message", "Node status unavailable.")), 18, UI.RED)
		return
	var when := "while you mine" if str(r["policy"]) == "while_mining" else ("whenever the app is open" if str(r["policy"]) == "always" else "(rewards paused)")
	UI.add_label(c, "Your phone signs a heartbeat every %ss and earns %s. %s units = 1 PLS, paid every %s minutes." % [UI.n(r["interval"]), when, UI.n(r["units_per_pls"]), UI.n(r.get("payout_minutes", 10))], 17, UI.MUTED)
	UI.add_label(c, "Today: %s / %s units    Total earned: %s PLS    Next payout in %s min" % [UI.n(r["units_today"]), UI.n(r["daily_cap"]), UI.n(r["total_earned"]), UI.n(int(r["next_settlement_in"]) / 60)], 18)
	for n in r["nodes"]:
		var here: bool = str(n["node_id"]) == M.node.node_id
		var line := "%s%s  -  %s  -  %s units" % [str(n["label"]), "  (this phone)" if here else "", "ONLINE" if n["online"] else str(n["status"]).to_upper(), UI.n(n["units_total"])]
		UI.add_label(c, line, 17, UI.TEAL_L if n["online"] else UI.MUTED)
		UI.add_label(c, "Node id " + str(n["node_id"]).left(16) + "...", 14, UI.MUTED)
		if str(n["status"]) == "active":
			var nid := str(n["node_id"])
			var rm := UI.add_button(c, "REMOVE THIS NODE", "stone", 48, 16)
			rm.pressed.connect(func():
				var x: Dictionary = await M.api.post("/node/remove", {"node_id": nid})
				if x.get("ok", false):
					if nid == M.node.node_id:
						M.node.stop()
					M.toast("Node removed.")
				_set_tab("stats"))
	if M.node.ready_state == "removed" or M.node.node_id == "":
		var add := UI.add_button(c, "ADD THIS PHONE AS A NODE", "teal", 54, 18)
		add.pressed.connect(func():
			M.node.re_add()
			M.toast("Setting up this phone as a node...")
			await get_tree().create_timer(2.0).timeout
			_set_tab("stats"))
	var rw: Array = r["rewards"]
	if not rw.is_empty():
		UI.add_label(c, "Recent node rewards", 18, UI.GOLD)
		for x in rw.slice(0, 6):
			UI.add_label(c, "+%s PLS for %s units" % [UI.n(x["pls"]), UI.n(x["units"])], 16, UI.MUTED)
	await _devnet_card()


# PULSE on Solana devnet: a test token minted only by node rewards, sent to your own wallet.
func _devnet_card() -> void:
	var r: Dictionary = await M.api.get_json("/solana/mine")
	if tab != "stats" or not r.get("ok", false) or not r.get("enabled", false):
		return
	var c := UI.add_card(body, "dark")
	UI.add_label(c, "PULSE ON SOLANA DEVNET", 24, UI.GOLD)
	UI.add_label(c, "A test token with no cash value. Each node reward is also minted as devnet PULSE to your own Solana wallet (Phantom or Solflare set to devnet). Your game PLS stays separate.", 16, UI.MUTED)
	UI.add_label(c, "On chain: %s PULSE    Waiting: %s PULSE" % [UI.n(r["confirmed_pulse"]), UI.n(r["pending_pulse"])], 18)
	var cur = r.get("sol_wallet")
	var input := UI.add_input(c, "Paste your devnet wallet address")
	input.text = "" if cur == null else str(cur)
	var row := UI.add_row(c, 8)
	var save_btn := UI.add_button(row, "SAVE WALLET", "teal", 54, 18)
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(func():
		var x: Dictionary = await M.api.post("/solana/wallet", {"address": input.text.strip_edges()})
		if x.get("ok", false):
			M.toast("Wallet saved. Waiting rewards will be minted within a minute or two.", UI.TEAL_L)
			_set_tab("stats")
		else:
			M.error_toast(x))
	if cur != null and r.get("wallet_explorer") != null:
		var view := UI.add_button(row, "VIEW ON EXPLORER", "stone", 54, 18)
		view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var url := str(r["wallet_explorer"])
		view.pressed.connect(func(): OS.shell_open(url))
	UI.add_label(c, "PULSE mint: %s" % str(r["mint"]), 14, UI.MUTED)


func _settings() -> void:
	var c := UI.add_card(body, "dark")
	var snd := UI.add_button(c, "SOUND: %s" % ("ON" if M.settings.get("sound", true) else "OFF"), "teal" if M.settings.get("sound", true) else "stone", 60, 22)
	snd.pressed.connect(func():
		M.settings["sound"] = not M.settings.get("sound", true)
		M.save_settings()
		M.play("coin")
		_set_tab("settings")
	)
	var vib := UI.add_button(c, "VIBRATION: %s" % ("ON" if M.settings.get("vibrate", true) else "OFF"), "teal" if M.settings.get("vibrate", true) else "stone", 60, 22)
	vib.pressed.connect(func():
		M.settings["vibrate"] = not M.settings.get("vibrate", true)
		M.save_settings()
		M.vibrate(60)
		_set_tab("settings")
	)
	UI.add_label(c, "Server: %s" % M.api.base_url, 16, UI.MUTED)
	var mus := UI.add_button(c, "MUSIC: %s" % ("ON" if M.settings.get("music", true) else "OFF"), "teal" if M.settings.get("music", true) else "stone", 60, 22)
	mus.pressed.connect(func():
		M.settings["music"] = not M.settings.get("music", true)
		M.save_settings()
		M.audio.refresh()
		_set_tab("settings"))
	var amb := UI.add_button(c, "AMBIENT SOUND: %s" % ("ON" if M.settings.get("ambience", true) else "OFF"), "teal" if M.settings.get("ambience", true) else "stone", 60, 22)
	amb.pressed.connect(func():
		M.settings["ambience"] = not M.settings.get("ambience", true)
		M.save_settings()
		M.audio.refresh()
		_set_tab("settings"))
	var intro := UI.add_button(c, "REPLAY THE INTRO", "stone", 54, 20)
	intro.pressed.connect(func():
		M.close_panel()
		M.go("town")
		await M.world.play_intro())
	var ic := UI.add_card(body, "teal")
	UI.add_label(ic, "INVITE A FRIEND", 20, UI.TEAL_L)
	UI.add_label(ic, "Your invite code: %s" % str(M.profile.get("invite_code", "")), 22, UI.GOLD)
	UI.add_label(ic, "When a friend signs up with your code and reaches level 5, you both get the Lantern Trim.", 16, UI.MUTED)
	var cp := UI.add_button(ic, "COPY CODE", "teal", 50, 18)
	cp.pressed.connect(func():
		DisplayServer.clipboard_set(str(M.profile.get("invite_code", "")))
		M.toast("Invite code copied!", UI.TEAL_L))
	if int(M.profile.get("level", 1)) < 5:
		var mc := UI.add_card(body, "dark")
		UI.add_label(mc, "FIND A MENTOR", 20, UI.AMBER)
		UI.add_label(mc, "Name a level 15+ player as your mentor. When you reach level 10 they earn the Mentor badge.", 16, UI.MUTED)
		var mn := UI.add_input(mc, "Mentor's username")
		var mb := UI.add_button(mc, "SET MENTOR", "amber", 50, 18)
		mb.pressed.connect(func():
			var rr: Dictionary = await M.api.post("/mentor", {"username": mn.text.strip_edges()})
			if rr.get("ok", false):
				M.toast("%s is now your mentor!" % str(rr["mentor"]), UI.GOLD)
			else:
				M.error_toast(rr))
	var c2 := UI.add_card(body, "dark")
	UI.add_label(c2, "Pulse Network v5.0. PLS is an in-game balance earned by mining and by your phone acting as a node while you mine. It cannot be bought, sold or cashed out.", 16, UI.MUTED)
	var tut := UI.add_button(c2, "SHOW THE TUTORIAL AGAIN", "stone", 50, 18)
	tut.pressed.connect(func():
		await M.api.post("/me/flags", {"tutorial": false})
		M.profile["tutorial"] = false
		M.close_panel()
		M.enter_game(M.profile))
	var out := UI.add_button(c2, "LOG OUT", "red", 60, 22)
	out.pressed.connect(func(): M.close_panel(); M.logout())


func _badges() -> void:
	var r: Dictionary = await M.api.get_json("/badges")
	if not r.get("ok", false) or tab != "badges":
		return
	UI.clear(body)
	var row := UI.add_row(body, 6)
	var home := UI.add_button(row, "MY CABIN", "amber", 56, 20)
	home.pressed.connect(func(): M.go("cabin"))
	var share := UI.add_button(row, "SHARE MY PROFILE", "teal", 56, 20)
	share.pressed.connect(func(): M.share_card({"kind": "profile"}))
	UI.add_label(body, "PETS - earned, never bought", 20, UI.AMBER)
	var info: Dictionary = r["pet_info"]
	var pets: Array = r["pets"]
	for k in info.keys():
		var c := UI.add_card(body, "gold" if r["pet"] == k else "dark")
		var have: bool = pets.has(k)
		UI.add_label(c, "%s  -  %s" % [info[k]["name"], "EQUIPPED" if r["pet"] == k else ("earned" if have else "locked")], 20, UI.TEAL_L if have else UI.MUTED)
		UI.add_label(c, "How: " + str(info[k]["how"]), 16, UI.MUTED)
		if have:
			var pk: String = k if r["pet"] != k else ""
			var b := UI.add_button(c, "PUT AWAY" if r["pet"] == k else "TAKE ALONG", "amber", 46, 18)
			b.pressed.connect(func():
				var rr: Dictionary = await M.api.post("/pet", {"pet": pk})
				if rr.get("ok", false):
					M.profile["pet"] = rr["pet"]
					M.update_hud()
				_set_tab("badges"))
	var earned := {}
	for b in r["badges"]:
		earned[b["id"]] = b
	UI.add_label(body, "BADGES  (%d of %d)" % [earned.size(), r["all"].size()], 20, UI.AMBER)
	for b in r["all"]:
		var got: bool = earned.has(b["id"])
		var row2 := UI.add_row(body, 8)
		UI.add_icon(row2, "trophy" if got else "star", 34)
		UI.add_label(row2, "%s  -  %s" % [b["name"], b["desc"]], 18, UI.GOLD if got else UI.MUTED)
