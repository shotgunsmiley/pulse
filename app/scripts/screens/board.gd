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
	tabs = UI.add_tabs(self, ["quests", "monsters", "leaders", "land", "economy"], ["QUESTS", "MONSTERS", "LEADERS", "CREW LAND", "ECONOMY"], _set_tab)
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
	elif t == "monsters":
		await _monsters()
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



# v5.5: the monster notice - what is coming, how it went last time, and every monster's trick.
func _monsters() -> void:
	var r: Dictionary = await M.api.get_json("/boss")
	if tab != "monsters":
		return
	UI.clear(body)
	if not r.get("ok", false):
		M.error_toast(r)
		return
	M.on_boss_view(r)
	var top := UI.add_card(body, "gold")
	var st := str(r.get("state", "idle"))
	match st:
		"countdown":
			UI.add_label(top, "%s ARRIVES IN %s!" % [str(r["name"]).to_upper(), _mmss(float(r.get("spawn_in", 0)))], 24, UI.RED)
		"live":
			UI.add_label(top, "THE %s IS IN THE SQUARE!" % str(r["name"]).to_upper(), 24, UI.RED)
			UI.add_label(top, "%d%% health left, %s to go." % [int(ceil(100.0 * float(r["hp"]) / maxf(1.0, float(r["max_hp"])))), _mmss(float(r.get("time_left", 0)))], 19)
		_:
			var nxt: Dictionary = r.get("next", {})
			if not nxt.is_empty():
				UI.add_label(top, "NEXT: %s in %s" % [str(nxt.get("name", "?")).to_upper(), _mmss(float(nxt.get("in_s", 0)))], 22, UI.GOLD)
	UI.add_label(top, "A monster comes to town every 90 minutes. A horn sounds 3 minutes before. Everyone fights the same monster - each new fighter makes it tougher, but fighting together hits harder. Loot is ore, xp, gems and badges.", 16, UI.MUTED)
	if st in ["countdown", "live"]:
		var go_b := UI.add_button(top, "TO THE SQUARE!", "red", 60, 22)
		go_b.pressed.connect(func(): M.open_boss())
	var fights: Array = r.get("log", [])
	if fights.size() > 0:
		UI.add_label(body, "RECENT FIGHTS", 20, UI.AMBER)
		for e in fights:
			var c := UI.add_card(body, "dark")
			var mk := str(e.get("monster", ""))
			var nm := str(r.get("monsters", {}).get(mk, {}).get("name", mk))
			UI.add_label(c, "%s - %s, %d fighters" % [nm, "defeated" if e.get("result") == "won" else "got away", int(e.get("fighters", 0))], 19, UI.GOLD if e.get("result") == "won" else UI.MUTED)
			var names := []
			for row in e.get("top", []):
				names.append("%s %s" % [str(row.get("username", "?")), UI.n(row.get("dmg", 0))])
			if names.size() > 0:
				UI.add_label(c, "Top: " + ", ".join(PackedStringArray(names)), 16, UI.MUTED)
	UI.add_label(body, "THE FIVE MONSTERS", 20, UI.AMBER)
	var book: Dictionary = r.get("bestiary", {})
	var mons: Dictionary = r.get("monsters", {})
	for mk in ["golem", "wyrm", "spider", "wraith", "drake"]:
		if not mons.has(mk):
			continue
		var m: Dictionary = mons[mk]
		var c2 := UI.add_card(body, "parch")
		UI.add_label(c2, str(m.get("name", mk)).to_upper(), 20, UI.INK)
		UI.add_label(c2, str(m.get("trick", "")), 16, UI.INK)
		var loot := []
		for k in m.get("loot", {}).keys():
			loot.append("%s %s" % [UI.n(m["loot"][k]), UI.ore_name(str(k)).to_lower()])
		UI.add_label(c2, "Loot: about %s (more for big hitters, a quarter if it gets away)" % ", ".join(PackedStringArray(loot)), 15, UI.INK)
		var b: Dictionary = book.get(mk, {})
		UI.add_label(c2, ("You: %d defeated, best fight %s damage" % [int(b.get("kills", 0)), UI.n(b.get("best_dmg", 0))]) if not b.is_empty() else "You have not fought one yet.", 15, UI.INK)


static func _mmss(s: float) -> String:
	var t := int(s)
	if t >= 3600:
		return "%d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60]
	return "%d:%02d" % [t / 60, t % 60]
