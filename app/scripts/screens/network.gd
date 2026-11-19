extends VBoxContainer
# THE PULSE NETWORK - opened by tapping the crystal in the town square.
# Plain-language network health, a live map of phones running the network around
# the world (by time zone), one-tap wallet linking and your PULSE on Solana.

const UI = preload("res://scripts/ui.gd")

class WorldStrip extends Control:
	# A simple world map: one column per UTC offset, glowing with how many phones run there.
	var bands := {}
	var t := 0.0

	func _process(d: float) -> void:
		t += d
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0, 0, w, h), Color("#0e1a1c"))
		# rough continents along the strip (UTC-10 .. UTC+12)
		var land := [[-9, -4, 0.35, 0.85], [-5, -3, 0.55, 0.95], [-1, 3, 0.2, 0.55], [0, 4, 0.5, 0.9], [3, 11, 0.15, 0.6], [7, 10, 0.65, 0.85]]
		for L in land:
			var x0 := (float(L[0]) + 12.0) / 26.0 * w
			var x1 := (float(L[1]) + 12.0) / 26.0 * w
			draw_rect(Rect2(x0, float(L[2]) * h, x1 - x0, (float(L[3]) - float(L[2])) * h), Color("#1d3a36"))
		var mx := 1
		for k in bands.keys():
			mx = maxi(mx, int(bands[k]))
		for k in bands.keys():
			var off := int(k)
			var n := int(bands[k])
			var x := (float(off) + 12.0) / 26.0 * w
			var r := 4.0 + 10.0 * float(n) / float(mx)
			var pulse := 0.6 + 0.4 * sin(t * 3.0 + off)
			draw_circle(Vector2(x, h * 0.5), r * 2.2, Color(0.25, 0.82, 0.74, 0.12 * pulse))
			draw_circle(Vector2(x, h * 0.5), r, Color(0.5, 0.95, 0.88, 0.85))
			draw_string(ThemeDB.fallback_font, Vector2(x - 6, h - 6), str(n), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#d9ccaa"))


var M
var body: VBoxContainer
var strip: WorldStrip
var link_code := ""
var polling := false


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	UI.add_title(self, "THE PULSE NETWORK", "Every phone mining right now helps run it.")
	body = UI.add_scroll(self)


func on_open() -> void:
	await _load()


func on_close() -> void:
	polling = false


func _load() -> void:
	var r: Dictionary = await M.api.get_json("/network/stats")
	var me: Dictionary = await M.api.get_json("/node/status")
	var sol: Dictionary = await M.api.get_json("/solana/mine")
	UI.clear(body)
	if not r.get("ok", false):
		M.error_toast(r)
		return
	var c := UI.add_card(body, "teal")
	UI.add_label(c, "%s phones are running the network right now" % UI.n(r["nodes_online"]), 24, UI.TEAL_L)
	UI.add_label(c, "%s miners swinging picks  -  %s players in total" % [UI.n(r["miners_now"]), UI.n(r["players"])], 18)
	UI.add_label(c, "Next payday in %s:%02d" % [UI.n(int(r["next_payday_in"]) / 60), int(r["next_payday_in"]) % 60], 22, UI.GOLD)
	strip = WorldStrip.new()
	strip.custom_minimum_size = Vector2(0, 150)
	strip.bands = r.get("by_utc_offset", {})
	body.add_child(strip)
	UI.add_label(body, "Phones online, by time zone (left = the Americas, right = Asia)", 15, UI.MUTED, true)
	var h := UI.add_card(body, "dark")
	UI.add_label(h, "NETWORK HEALTH", 20, UI.AMBER)
	UI.add_label(h, "Paid to phones in the last 24 hours: %s PLS" % UI.n(r["paid_last_24h"]), 18)
	UI.add_label(h, "Burned today: %s PLS   (burned forever: %s)" % [UI.n(r["burned_today"]), UI.n(r["burned_total"])], 18)
	UI.add_label(h, "Held by players: %s PLS  -  locked in games: %s" % [UI.n(r["held_by_players"]), UI.n(r["locked_in_games"])], 18)
	UI.add_label(h, "Books balanced: %s" % ("YES - every coin accounted for" if r["ledger_balanced"] else "CHECKING"), 18, UI.GREEN if r["ledger_balanced"] else UI.RED)
	var pd: Array = r.get("paydays", [])
	if not pd.is_empty():
		var pc := UI.add_card(body, "dark")
		UI.add_label(pc, "RECENT PAYDAYS", 20, UI.AMBER)
		for p in pd.slice(0, 6):
			var tt := Time.get_datetime_dict_from_unix_time(int(p["at"]))
			UI.add_label(pc, "%02d:%02d UTC  -  %s PLS to %s phones" % [tt["hour"], tt["minute"], UI.n(p["pls"]), UI.n(p["nodes"])], 17)
	if me.get("ok", false):
		var mc := UI.add_card(body, "stone")
		UI.add_label(mc, "YOUR PHONE", 20, UI.AMBER)
		UI.add_label(mc, "Check-ins today: %s of %s  -  earned so far: %s PLS" % [UI.n(me.get("units_today", 0)), UI.n(me.get("daily_cap", 0)), UI.n(me.get("total_earned", 0))], 18)
	_wallet_card(sol)


func _wallet_card(sol: Dictionary) -> void:
	var wc := UI.add_card(body, "void")
	UI.add_label(wc, "PULSE ON SOLANA (TEST NETWORK)", 20, UI.VOID)
	if not sol.get("ok", false) or not sol.get("enabled", false):
		UI.add_label(wc, "Test tokens are switched off on this server right now.", 17, UI.MUTED)
		return
	var wallet = sol.get("sol_wallet")
	if wallet == null or str(wallet) == "":
		UI.add_label(wc, "Link a wallet and every node reward is also sent to you as a real PULSE test token.", 18)
		var row := UI.add_row(wc, 6)
		var ph := UI.add_button(row, "LINK PHANTOM", "void", 54, 18)
		ph.pressed.connect(func(): _link("phantom"))
		var sf := UI.add_button(row, "LINK SOLFLARE", "void", 54, 18)
		sf.pressed.connect(func(): _link("solflare"))
		UI.add_label(wc, "Set your wallet to Devnet first. Linking only signs a message - it costs nothing and moves no funds.", 15, UI.MUTED)
		UI.add_label(wc, "Prefer typing the address? Use ME > STATS.", 15, UI.MUTED)
	else:
		UI.add_label(wc, "Linked: %s...%s" % [str(wallet).substr(0, 6), str(wallet).substr(str(wallet).length() - 4)], 18, UI.TEAL_L)
		if sol.get("wallet_explorer") != null:
			var ex := UI.add_button(wc, "SEE MY WALLET ON SOLANA", "teal", 50, 18)
			ex.pressed.connect(func(): OS.shell_open(str(sol["wallet_explorer"])))
	var rew: Array = sol.get("recent", [])
	if not rew.is_empty():
		UI.add_label(wc, "ON-CHAIN REWARDS", 18, UI.AMBER)
		for x in rew:
			var row2 := UI.add_row(wc, 6)
			UI.add_label(row2, "%s PULSE - %s" % [UI.n(x.get("pls", 0)), str(x.get("status", ""))], 17)
			var sig := str(x.get("sig", ""))
			if sig != "":
				var vb := UI.add_button(row2, "VIEW", "stone", 42, 16)
				vb.custom_minimum_size = Vector2(110, 42)
				vb.size_flags_horizontal = Control.SIZE_SHRINK_END
				vb.pressed.connect(func(): OS.shell_open("https://explorer.solana.com/tx/%s?cluster=devnet" % sig))


func _link(app: String) -> void:
	var r: Dictionary = await M.api.post("/wallet/link/start", {})
	if not r.get("ok", false):
		M.error_toast(r)
		return
	link_code = str(r["code"])
	OS.shell_open(str(r[app]))
	M.toast("Sign the message in %s, then come back." % app.capitalize(), UI.TEAL_L)
	polling = true
	for i in range(60):
		await get_tree().create_timer(3.0).timeout
		if not polling:
			return
		var c: Dictionary = await M.api.get_json("/wallet/link/check")
		if c.get("ok", false) and c.get("sol_wallet") != null and str(c["sol_wallet"]) != "":
			M.toast("Wallet linked! Node rewards will arrive as PULSE.", UI.GOLD)
			M.play("win")
			polling = false
			await _load()
			return
