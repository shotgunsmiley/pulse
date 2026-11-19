extends VBoxContainer
# THE NOTICE BOARD - daily quests, leaderboards, and the PLS economy + your ledger.

const UI = preload("res://scripts/ui.gd")
const BOARDS := [["miners", "MINERS"], ["level", "LEVEL"], ["elo_quickdraw", "QUICKDRAW"], ["elo_sequence", "SEQUENCE"], ["elo_sniper", "SNIPER"]]

var M
var tabs := {}
var tab := "quests"
var body: VBoxContainer
var board := "miners"


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	UI.add_title(self, "THE NOTICE BOARD", "")
	tabs = UI.add_tabs(self, ["quests", "leaders", "land", "economy"], ["QUESTS", "LEADERS", "CREW LAND", "ECONOMY"], _set_tab)
	body = UI.add_scroll(self)


func on_open() -> void:
	_set_tab(tab)


func on_close() -> void:
	pass


func _set_tab(t: String) -> void:
	tab = t
	UI.set_tab(tabs, t)
	UI.clear(body)
	UI.add_label(body, "Loading...", 20, UI.MUTED)
	if t == "quests":
		await _quests()
	elif t == "leaders":
		await _leaders()
	elif t == "land":
		await _land()
	else:
		await _economy()


func _land() -> void:
	var r: Dictionary = await M.api.get_json("/crew/territory")
	if tab != "land":
		return
	UI.clear(body)
	if not r.get("ok", false):
		M.error_toast(r)
		return
	UI.add_label(body, "CREW WARS - week %s" % str(r["week"]), 22, UI.AMBER)
	UI.add_label(body, "The crew that clears the most veins on a seam this week holds it next week: %s." % str(r["bonus"]), 17, UI.MUTED)
	for v in r["veins"]:
		var c := UI.add_card(body, "gold" if v["holder"] != null else "dark")
		UI.add_label(c, str(v["vein"]).to_upper(), 22, UI.TEAL_L)
		UI.add_label(c, "Held by: %s" % ("[%s] %s" % [v["holder_tag"], v["holder"]] if v["holder"] != null else "nobody - up for grabs!"), 19, UI.GOLD)
		var race: Array = v["race"]
		if race.is_empty():
			UI.add_label(c, "No crew has cleared a vein here this week.", 16, UI.MUTED)
		for i in range(race.size()):
			UI.add_label(c, "#%d  [%s] %s  -  %s veins" % [i + 1, race[i]["tag"], race[i]["crew"], UI.n(race[i]["veins"])], 17)


func _quests() -> void:
	var r: Dictionary = await M.api.get_json("/quests")
	if tab != "quests":
		return
	UI.clear(body)
	if not r.get("ok", false):
		M.error_toast(r)
		return
	var left := int(r["resets_in"])
	UI.add_label(body, "New quests in %dh %02dm (midnight UTC)" % [left / 3600, (left % 3600) / 60], 20, UI.TEAL_L)
	for q in r["quests"]:
		var card := UI.add_card(body, "parch")
		var done: bool = float(q["progress"]) >= float(q["target"])
		UI.add_label(card, str(q["title"]) + ("   DONE" if done else ""), 24, Color("#1d6b37") if done else UI.INK)
		UI.add_label(card, "%s  (%s/%s)" % [q["desc"], UI.n(q["progress"]), UI.n(q["target"])], 18, Color("#5a4a30"))
		UI.add_bar(card, float(q["progress"]) / maxf(1.0, float(q["target"])), UI.AMBER, 12)
		var rw := "%s %s" % [UI.n(q["ore_amt"]), UI.ore_name(str(q["ore"]))]
		if int(q["pls"]) > 0:
			rw = "%s PLS + %s" % [UI.n(q["pls"]), rw]
		UI.add_label(card, "Reward: " + rw, 18, Color("#5a4a30"))
		if done and not q["claimed"]:
			var qid: String = q["id"]
			var b := UI.add_button(card, "CLAIM", "amber", 56, 22)
			b.pressed.connect(func(): _claim(qid))
		elif q["claimed"]:
			UI.add_label(card, "Claimed", 18, Color("#1d6b37"))


func _claim(qid: String) -> void:
	var r: Dictionary = await M.api.post("/quests/claim", {"quest_id": qid})
	if r.get("ok", false):
		M.apply(r)
		M.play("rare")
		M.vibrate(80)
		var got := "+%s %s" % [UI.n(r["ore_amt"]), UI.ore_name(str(r["ore"]))]
		if int(r["pls"]) > 0:
			got = "+%s PLS  %s" % [UI.n(r["pls"]), got]
		M.toast("Quest complete! " + got, UI.GOLD)
		M.refresh_profile()
	else:
		M.error_toast(r)
	_set_tab("quests")


func _leaders() -> void:
	var r: Dictionary = await M.api.get_json("/leaderboard?board=%s" % board)
	if tab != "leaders":
		return
	UI.clear(body)
	var row := UI.add_row(body, 4)
	for b in BOARDS:
		var key: String = b[0]
		var btn := UI.add_button(row, b[1], "amber" if key == board else "stone", 48, 15)
		btn.pressed.connect(func():
			board = key
			_set_tab("leaders")
		)
	if not r.get("ok", false):
		M.error_toast(r)
		return
	UI.add_label(body, "Ranked by %s." % str(r["value_name"]), 18, UI.MUTED)
	var card := UI.add_card(body, "dark")
	var me := str(M.profile.get("username", ""))
	for t in r["top"]:
		var mine: bool = str(t["username"]) == me
		var crew := "[%s] " % t["crew"] if str(t["crew"]) != "" else ""
		UI.add_label(card, "#%s  %s%s  Lv%s  -  %s" % [UI.n(t["rank"]), crew, t["username"], UI.n(t["level"]), UI.n(t["value"])], 20, UI.GOLD if mine else UI.WHITE)
	if r["top"].is_empty():
		UI.add_label(card, "Nobody on this board yet.", 18, UI.MUTED)
	if r.get("me") != null:
		UI.add_label(body, "You: #%s (%s)" % [UI.n(r["me"]["rank"]), UI.n(r["me"]["value"])], 22, UI.TEAL_L)


func _economy() -> void:
	var e: Dictionary = await M.api.get_json("/economy")
	var l: Dictionary = await M.api.get_json("/ledger?limit=40")
	if tab != "economy":
		return
	UI.clear(body)
	if e.get("ok", false):
		var c := UI.add_card(body, "deep")
		UI.add_label(c, "PLS ECONOMY", 24, UI.GOLD)
		UI.add_label(c, "New PLS is only created by phones acting as network nodes while their players mine (plus a one-time starter grant per player). It leaves through the Forge, repairs, upgrades, the shop, crews, duel and tournament fees. Every movement is recorded.", 16, UI.MUTED)
		UI.add_label(c, "Mined into existence: %s" % UI.n(e["minted"]), 20)
		UI.add_label(c, "Burned (gone forever): %s" % UI.n(e["burned"]), 20)
		UI.add_label(c, "Held by %s players: %s" % [UI.n(e["players"]), UI.n(e["circulating"])], 20)
		UI.add_label(c, "Locked in duels: %s   In cup pots: %s" % [UI.n(e["in_escrow"]), UI.n(e["in_tournament_pots"])], 18, UI.MUTED)
		UI.add_label(c, "Ledger balanced: %s" % ("YES" if e["ledger_check"] else "NO"), 18, UI.GREEN if e["ledger_check"] else UI.RED)
	if l.get("ok", false):
		var c2 := UI.add_card(body, "dark")
		UI.add_label(c2, "YOUR RECENT PLS", 22, UI.AMBER)
		for x in l["entries"]:
			var amt := int(x["amount"])
			var when := Time.get_datetime_string_from_unix_time(int(x["t"])).replace("T", " ").substr(5, 11)
			UI.add_label(c2, "%s   %s%d   %s" % [when, "+" if amt > 0 else "", amt, str(x["why"]).replace("_", " ")], 18, UI.GREEN if amt > 0 else UI.RED)
		if l["entries"].is_empty():
			UI.add_label(c2, "No PLS movements yet.", 18, UI.MUTED)
