extends VBoxContainer
# THE ARENA - skill wagering. Three pure-skill games (no gear bonuses):
# Quickdraw (reaction), Rune Sequence (memory), Vein Sniper (precision).
#  PRACTICE     free, sets your personal best
#  DUELS        stake PLS 1v1. Both players get the same challenge; higher score
#               takes the pot. 5% of every pot is burned. Rated by ELO.
#  TOURNAMENTS  weekly. 50 PLS entry for 5 attempts; best score counts;
#               the pot pays the top 3 (50/30/20) when the week ends.

const UI = preload("res://scripts/ui.gd")
const SkillGame = preload("res://scripts/games/skill_game.gd")
const GAMES := ["quickdraw", "sequence", "sniper", "strikeoff"]
const ABOUT := {"quickdraw": "Reaction. Tap the moment the pad turns green. 5 rounds.",
	"sequence": "Memory. Repeat the runes; one more every round.",
	"sniper": "Precision. Hit the glowing vein before it fades. 12 targets.",
	"strikeoff": "Mining race. Ten strikes, each faster than the last. Land them in the gold."}
const DuelView = preload("res://scripts/duel_view.gd")
# The Training Knight: the sparring partner in practice and cups.
const KNIGHT_LOOK := {"skin": 0, "hair_style": 0, "hair_color": 4, "shirt": 0, "pants": 3, "accent": 1, "face": 4}
const EMOTE_TEXT := {"cheer": "Cheer", "wow": "Wow", "laugh": "Ha!", "gg": "GG", "fire": "Fire", "salute": "Salute"}

var M
var tabs := {}
var tab := "practice"
var body: VBoxContainer
var shell: VBoxContainer
var playing := false
var status := {}
var duel_game := "quickdraw"
var duel_stake := 10
var challenge_name := ""
var poll := 0.0
var open := false
var more := "thrones"
var more_tabs := {}
var ghost_game := "quickdraw"
var bounty_game := "quickdraw"


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	shell = VBoxContainer.new()
	shell.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(shell)
	UI.add_title(shell, "THE ARENA", "Pure skill. Same challenge for both players. No gear bonuses.")
	tabs = UI.add_tabs(shell, ["practice", "duels", "tournaments", "more"], ["PRACTICE", "DUELS", "CUPS", "MORE"], _set_tab)
	body = UI.add_scroll(shell)
	UI.set_tab(tabs, tab)


func on_open() -> void:
	open = true
	if str(M.pending_challenge) != "":
		prefill_challenge(M.pending_challenge)
		M.pending_challenge = ""
	_set_tab(tab)


func on_close() -> void:
	open = false


func prefill_challenge(username: String) -> void:
	challenge_name = username
	tab = "duels"


func _set_tab(t: String) -> void:
	tab = t
	UI.set_tab(tabs, t)
	await _refresh()


func _process(delta: float) -> void:
	if not open or playing or tab != "duels":
		return
	poll += delta
	if poll > 4.0:
		poll = 0.0
		_refresh()


func _refresh() -> void:
	if playing:
		return
	if tab == "practice":
		_render_practice()
	elif tab == "duels":
		var r: Dictionary = await M.api.get_json("/pvp/status")
		if r.get("ok", false) and tab == "duels" and not playing:
			status = r
			_render_duels()
	elif tab == "more":
		await _render_more()
	else:
		var r2: Dictionary = await M.api.get_json("/tournaments")
		if r2.get("ok", false) and tab == "tournaments" and not playing:
			_render_tournaments(r2)


# ------------------------------------------------------------------ practice
func _render_practice() -> void:
	UI.clear(body)
	var best: Dictionary = M.profile.get("best", {})
	for g in GAMES:
		var card := UI.add_card(body, "dark")
		UI.add_label(card, UI.game_name(g).to_upper(), 26, UI.TEAL_L)
		UI.add_label(card, ABOUT[g], 18, UI.MUTED)
		UI.add_label(card, "Personal best: %s" % UI.n(best.get(g)), 20, UI.GOLD)
		if g == "quickdraw" and M.daily.has("knight_ms"):
			var done: bool = M.daily.get("knight_done", false)
			UI.add_label(card, ("Today's Training Knight: %d ms average - " % int(M.daily["knight_ms"])) + ("beaten today!" if done else "beat it for an ore purse"), 18, UI.TEAL_L if done else UI.AMBER)
		var b := UI.add_button(card, "PRACTICE", "teal", 58, 22)
		b.pressed.connect(func(): _play("practice", g, ""))
	UI.add_label(body, "No signal? Practice still works offline; your score just is not saved.", 16, UI.MUTED)


# ------------------------------------------------------------------ duels
func _render_duels() -> void:
	UI.clear(body)
	var ranks: Dictionary = status.get("ranks", {})
	var elo: Dictionary = status.get("elo", {})
	var rc := UI.add_card(body, "deep")
	UI.add_label(rc, "YOUR RANKS", 20, UI.AMBER)
	for g in GAMES:
		UI.add_label(rc, "%s - %s (%s)" % [UI.game_name(g), str(ranks.get(g, "Bronze")), UI.n(elo.get(g, 1200))], 20)
	var invites: Array = status.get("invites", [])
	for inv in invites:
		var ic := UI.add_card(body, "gold")
		UI.add_label(ic, "%s challenges you: %s for %s PLS" % [inv["from"], UI.game_name(inv["game"]), UI.n(inv["stake"])], 22, UI.GOLD)
		var row := UI.add_row(ic)
		var acc := UI.add_button(row, "ACCEPT", "green", 56, 22)
		var dec := UI.add_button(row, "DECLINE", "red", 56, 22)
		var iid: String = inv["id"]
		acc.pressed.connect(func(): _respond(iid, true))
		dec.pressed.connect(func(): _respond(iid, false))
	var q = status.get("queue")
	var card := UI.add_card(body, "stone")
	if q != null:
		UI.add_label(card, "Searching for a %s opponent at %s PLS... (%ss)" % [UI.game_name(q["game"]), UI.n(q["stake"]), UI.n(q["waiting"])], 22, UI.TEAL_L)
		var cancel := UI.add_button(card, "CANCEL SEARCH", "red", 56, 22)
		cancel.pressed.connect(func(): _post("/pvp/cancel", {}, "Search cancelled. Stake returned."))
	else:
		UI.add_label(card, "FIND A DUEL", 22, UI.AMBER)
		var gr := UI.add_row(card, 6)
		for g in GAMES:
			var gb := UI.add_button(gr, UI.game_name(g).split(" ")[0].to_upper(), "amber" if g == duel_game else "stone", 52, 18)
			gb.pressed.connect(func():
				duel_game = g
				_render_duels()
			)
		UI.add_label(card, "Stake (PLS):", 18, UI.MUTED)
		var sr := UI.add_row(card, 4)
		for s in status.get("stakes", [0, 10, 25, 50, 100, 250]):
			var sv := int(s)
			var sb := UI.add_button(sr, str(sv), "amber" if sv == duel_stake else "stone", 50, 18)
			sb.pressed.connect(func():
				duel_stake = sv
				_render_duels()
			)
		var find := UI.add_button(card, "FIND OPPONENT", "amber", 62, 24)
		find.pressed.connect(func(): _queue())
		UI.add_label(card, "Winner takes the pot minus 5% (burned). Draws refund both. A stake of 0 is a friendly ranked match.", 16, UI.MUTED)
		var cc := UI.add_card(body, "dark")
		UI.add_label(cc, "CHALLENGE A PLAYER", 20, UI.AMBER)
		var name_in := UI.add_input(cc, "Their username")
		name_in.text = challenge_name
		var send := UI.add_button(cc, "SEND CHALLENGE (%s, %d PLS)" % [UI.game_name(duel_game), duel_stake], "teal", 56, 20)
		send.pressed.connect(func():
			challenge_name = name_in.text.strip_edges()
			_post("/pvp/challenge", {"username": challenge_name, "game": duel_game, "stake": duel_stake}, "Challenge sent!")
		)
	var sent: Array = status.get("sent", [])
	for s in sent:
		UI.add_label(body, "Waiting for %s to accept your %s challenge (%s PLS)." % [s["to"], UI.game_name(s["game"]), UI.n(s["stake"])], 18, UI.MUTED)
	var matches: Array = status.get("matches", [])
	if not matches.is_empty():
		UI.add_label(body, "YOUR DUELS", 22, UI.AMBER)
	for m in matches:
		var mc := UI.add_card(body, "dark")
		UI.add_label(mc, "vs %s (%s)  -  %s  -  %s PLS" % [m["opponent"], UI.n(m["opponent_elo"]), UI.game_name(m["game"]), UI.n(m["stake"])], 20)
		if m["state"] == "active":
			if m["my_score"] == null:
				var mid: String = m["id"]
				var g2: String = m["game"]
				var pb := UI.add_button(mc, "PLAY NOW (%s min left)" % UI.n(float(m["deadline_in"]) / 60.0), "amber", 58, 22)
				pb.pressed.connect(func(): _play("pvp", g2, mid))
				UI.add_label(mc, "You only get one run - leaving mid-game scores 0.", 16, UI.MUTED)
			else:
				UI.add_label(mc, "Your score: %s. %s" % [UI.n(m["my_score"]), "Opponent has played - settling..." if m["they_played"] else "Waiting for your opponent to play."], 18, UI.TEAL_L)
		else:
			var res = m.get("result")
			var txt := "Cancelled - stakes refunded."
			var col := UI.MUTED
			if res != null:
				if res.get("winner") == null:
					txt = "Draw - stakes refunded." if str(res.get("reason", "")) == "draw" else "Nobody played - refunded."
				elif str(res["winner"]) == str(M.profile.get("username", "")):
					txt = "WON +%s PLS  (%s vs %s)" % [UI.n(res.get("payout", 0)), UI.n(m["my_score"]), UI.n(m["their_score"])]
					col = UI.GREEN
				else:
					txt = "LOST  (%s vs %s)" % [UI.n(m["my_score"]), UI.n(m["their_score"])]
					col = UI.RED
			UI.add_label(mc, txt, 20, col)
			if res != null and res.get("winner") != null:
				var mid2: String = m["id"]
				var won: bool = str(res["winner"]) == str(M.profile.get("username", ""))
				var br := UI.add_row(mc, 6)
				if won:
					var sh := UI.add_button(br, "SHARE WIN", "teal", 50, 18)
					sh.pressed.connect(func(): M.share_card({"kind": "duel", "match_id": mid2}))
				elif int(m["stake"]) > 0:
					var rm := UI.add_button(br, "DOUBLE OR NOTHING (%d)" % (int(m["stake"]) * 2), "amber", 50, 18)
					rm.pressed.connect(func(): _post("/pvp/rematch", {"match_id": mid2}, "Rematch offered at double the stake!"))
				var wb := UI.add_button(br, "REPLAY", "stone", 50, 18)
				wb.pressed.connect(func(): _show_replay(mid2))


func _queue() -> void:
	var r: Dictionary = await M.api.post("/pvp/queue", {"game": duel_game, "stake": duel_stake})
	if not r.get("ok", false):
		M.error_toast(r)
		return
	M.apply({"balance": float(M.profile.get("balance", 0)) - duel_stake})
	if r["status"] == "matched":
		M.toast("Opponent found: %s! Play your run." % str(r["match"]["opponent"]), UI.GOLD)
		M.play("go")
	else:
		M.toast("Searching for an opponent...", UI.TEAL_L)
	await _refresh()


func _respond(iid: String, yes: bool) -> void:
	await _post("/pvp/respond", {"invite_id": iid, "accept": yes}, "Duel on!" if yes else "Declined.")


func _post(path: String, body_data: Dictionary, ok_text: String) -> void:
	var r: Dictionary = await M.api.post(path, body_data)
	if r.get("ok", false):
		M.toast(ok_text, UI.TEAL_L)
		M.refresh_profile()
	else:
		M.error_toast(r)
	await _refresh()


# ------------------------------------------------------------------ tournaments
func _render_tournaments(r: Dictionary) -> void:
	UI.clear(body)
	UI.add_label(body, "Week %s. Entry 50 PLS = 5 attempts. 10%% of entries is burned; the rest is the prize pot." % str(r["week"]), 18, UI.MUTED)
	for t in r["active"]:
		var card := UI.add_card(body, "dark")
		var g: String = t["game"]
		UI.add_label(card, "%s CUP" % UI.game_name(g).to_upper(), 24, UI.TEAL_L)
		UI.add_label(card, "Pot: %s PLS   Players: %s" % [UI.n(t["pot"]), UI.n(t["players"])], 20, UI.GOLD)
		var top: Array = t["top"]
		for row in top.slice(0, 5):
			UI.add_label(card, "#%s  %s  -  %s" % [UI.n(row["place"]), row["username"], UI.n(row["score"])], 18)
		if t["my_best"] != null:
			UI.add_label(card, "Your best: %s (place %s)" % [UI.n(t["my_best"]), UI.n(t["my_place"])], 18, UI.WHITE)
		var left := int(t["my_attempts_left"])
		if left > 0:
			var pb := UI.add_button(card, "PLAY ATTEMPT (%d left)" % left, "amber", 58, 22)
			pb.pressed.connect(func(): _play("tournament", g, ""))
		else:
			var eb := UI.add_button(card, "ENTER - 50 PLS", "teal", 58, 22)
			eb.pressed.connect(func(): _enter(g))
	var recent: Array = r.get("recent", [])
	if not recent.is_empty():
		UI.add_label(body, "LAST RESULTS", 20, UI.AMBER)
		for t in recent:
			for p in t["payouts"]:
				UI.add_label(body, "%s %s: #%s %s won %s PLS" % [t["week"], UI.game_name(t["game"]), UI.n(p["place"]), p["username"], UI.n(p["prize"])], 16, UI.MUTED)


func _enter(g: String) -> void:
	var r: Dictionary = await M.api.post("/tournament/enter", {"game": g})
	if r.get("ok", false):
		M.toast("Entered the %s Cup!" % UI.game_name(g), UI.GOLD)
		M.play("coin")
		M.refresh_profile()
	else:
		M.error_toast(r)
	await _refresh()


# ------------------------------------------------------------------ playing
func _play(mode: String, game: String, match_id: String) -> void:
	if playing:
		return
	var r: Dictionary
	if mode == "practice":
		r = await M.api.post("/practice/start", {"game": game})
		if not r.get("ok", false) and str(r.get("error", "")) == "network":
			r = {"ok": true, "id": "", "challenge": SkillGame.local_challenge(game), "offline": true}
			M.toast("Offline practice - your score will not be saved.", UI.AMBER)
	elif mode == "pvp":
		r = await M.api.post("/pvp/play", {"match_id": match_id})
	elif mode == "koth":
		r = await M.api.post("/koth/challenge", {"game": game})
	elif mode == "ghost":
		r = await M.api.post("/ghost/start", {"game": game, "username": match_id})
	else:
		r = await M.api.post("/tournament/start", {"game": game})
	if not r.get("ok", false):
		M.error_toast(r)
		await _refresh()
		return
	playing = true
	shell.visible = false
	var sg = SkillGame.new()
	sg.cid = "" if r.get("offline", false) else str(r.get("id", ""))
	add_child(sg)
	var heading: String = {"practice": "PRACTICE", "pvp": "DUEL", "tournament": "CUP ATTEMPT", "koth": "THRONE CHALLENGE",
		"ghost": "GHOST RACE"}[mode] + " - " + UI.game_name(game).to_upper()
	if mode == "ghost" and r.has("ghost"):
		heading += "  vs %s (%s)" % [str(r["ghost"]["username"]), UI.n(r["ghost"]["score"])]
	if game == "quickdraw":
		sg.duel_info = _duel_info(mode, r)
	sg.run(M, r["challenge"], heading)
	var result: Dictionary = await sg.finished
	remove_child(sg)
	sg.queue_free()
	shell.visible = true
	playing = false
	if result.is_empty():
		M.toast("Run abandoned." + (" It counts as 0 in a duel." if mode == "pvp" else ""), UI.AMBER)
		if mode == "pvp":
			await M.api.post("/pvp/forfeit", {"match_id": match_id})
		await _refresh()
		return
	if r.get("offline", false):
		var local := SkillGame.local_score(r["challenge"], result)
		M.toast("Offline score: %s (not saved)" % UI.n(local), UI.GOLD)
		await _refresh()
		return
	var path: String = {"practice": "/practice/submit", "pvp": "/pvp/submit", "tournament": "/tournament/submit",
		"koth": "/koth/submit", "ghost": "/ghost/submit"}[mode]
	var s: Dictionary = await M.api.post(path, {"id": r["id"], "result": result})
	if not s.get("ok", false):
		M.error_toast(s)
		await _refresh()
		return
	var msg := "Score %s - %s" % [UI.n(s["score"]), str(s["detail"])]
	if mode == "practice":
		M.tutorial_event("practice")
		if s.get("new_best", false):
			msg = "NEW PERSONAL BEST! " + msg
			M.play("rare")
		else:
			M.play("coin")
		var best: Dictionary = M.profile.get("best", {})
		best[game] = s["best"]
		M.profile["best"] = best
		var kn = s.get("knight")
		if kn != null and typeof(kn) == TYPE_DICTIONARY:
			if kn.has("reward"):
				var rw: Dictionary = kn["reward"]
				var parts := []
				for k in rw.keys():
					parts.append("%d %s" % [int(rw[k]), str(k)])
				M.toast("You beat the Training Knight! Purse: %s" % ", ".join(PackedStringArray(parts)), UI.GOLD)
				M.log_msg("Training Knight beaten (%d ms vs %d ms): %s." % [int(kn["avg"]), int(kn["target"]), ", ".join(PackedStringArray(parts))], UI.GOLD)
				M.daily["knight_done"] = true
				M.refresh_profile()
			elif not kn.get("done", false) and int(kn.get("avg", 9999)) < 9999:
				M.log_msg("The Training Knight was faster today: %d ms vs your %d ms." % [int(kn["target"]), int(kn["avg"])], UI.AMBER)
		for bc in s.get("bounties_claimed", []):
			M.toast("BOUNTY CLAIMED! +%s PLS from %s" % [UI.n(bc["amount"]), str(bc["by"])], UI.GOLD)
			M.play("win")
	elif mode == "tournament":
		msg += "   (cup best improved)" if s.get("improved", false) else ""
		M.play("coin")
	elif mode == "koth":
		msg = ("YOU TOOK THE THRONE! " if s.get("crowned", false) else "The king holds. ") + msg
		M.play("win" if s.get("crowned", false) else "lose")
	elif mode == "ghost":
		msg = ("YOU BEAT %s'S GHOST! " % str(s["ghost_name"]) if s.get("won", false) else "The ghost wins this time. ") + msg + "  (ghost: %s)" % UI.n(s["ghost_score"])
		M.play("win" if s.get("won", false) else "lose")
	else:
		M.play("coin")
	M.toast(msg, UI.GOLD)
	M.vibrate(60)
	M.refresh_profile()
	if mode == "pvp" and game == "quickdraw":
		# if the other player already drew, show the whole sword fight now
		var rep: Dictionary = await M.api.get_json("/duels/replay?id=" + match_id)
		if rep.get("ok", false) and str(rep.get("state", "active")) != "active":
			await _sword_fight(rep)
			return
		M.toast("Your opponent hasn't drawn yet. Watch the sword fight from DUELS once they do.", UI.TEAL_L)
	await _refresh()


# Who you cross swords with in Quickdraw, and (when known) how fast they are each round.
func _duel_info(mode: String, r: Dictionary) -> Dictionary:
	var me_look: Dictionary = M.profile.get("appearance", {}).duplicate()
	me_look["win_streak"] = int(M.profile.get("win_streak", 0))
	me_look["crew_color"] = int(M.profile.get("crew_color", -1))
	var tier: String = str(M.world.hero.pick_tier) if M.world and M.world.hero else "iron"
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var knight_rts := []
	var kt := int(M.daily.get("knight_ms", 300))
	for i in range(5):
		knight_rts.append(clampi(kt + rng.randi_range(-30, 30), 180, 480))
	match mode:
		"ghost":
			var g: Dictionary = r.get("ghost", {})
			var res = g.get("result", {})
			return {"me_look": me_look, "me_tier": tier, "op_name": str(g.get("username", "Ghost")) + "'s ghost", "op_look": g.get("look", KNIGHT_LOOK),
				"op_rts": res.get("reactions", knight_rts) if typeof(res) == TYPE_DICTIONARY else knight_rts}
		"pvp":
			var o: Dictionary = r.get("opponent", {})
			return {"me_look": me_look, "me_tier": tier, "op_name": str(o.get("username", "Opponent")), "op_look": o.get("look", KNIGHT_LOOK), "op_rts": [],
				"rivalry": r.get("rivalry", {})}
		"koth":
			var t: Dictionary = r.get("throne", {})
			if t.get("king") == null:
				return {"me_look": me_look, "me_tier": tier, "op_name": "Empty throne", "op_look": KNIGHT_LOOK, "op_rts": knight_rts}
			# the throne keeps only the king's total, so the king fights at their average speed
			var avg := clampi(500 - int(t.get("score", 1000)) / 5, 150, 480)
			var rts := []
			for i in range(5):
				rts.append(clampi(avg + rng.randi_range(-25, 25), 140, 500))
			return {"me_look": me_look, "me_tier": tier, "op_name": "King " + str(t["king"]), "op_look": t.get("king_look", KNIGHT_LOOK), "op_rts": rts}
		_:
			return {"me_look": me_look, "me_tier": tier, "op_name": "Training Knight", "op_look": KNIGHT_LOOK, "op_rts": knight_rts}


# Full-screen replay of a finished Quickdraw duel, round by round.
func _sword_fight(rep: Dictionary) -> void:
	var sides: Array = rep.get("sides", [])
	if sides.size() < 2:
		await _refresh()
		return
	var mine: Dictionary = sides[0] if sides[0].get("me", false) else sides[1]
	var theirs: Dictionary = sides[1] if sides[0].get("me", false) else sides[0]
	var spectator: bool = not sides[0].get("me", false) and not sides[1].get("me", false)
	if spectator:
		mine = sides[0]
		theirs = sides[1]
	var a = mine.get("replay")
	var b = theirs.get("replay")
	if typeof(a) != TYPE_DICTIONARY or typeof(b) != TYPE_DICTIONARY or not a.has("reactions") or not b.has("reactions"):
		await _refresh()
		return
	playing = true
	shell.visible = false
	var box := VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(box)
	UI.add_label(box, "QUICKDRAW DUEL - %s PLS" % UI.n(rep.get("stake", 0)), 24, UI.GOLD)
	var dv = DuelView.new()
	box.add_child(dv)
	var mlook: Dictionary = mine.get("look", {})
	dv.setup(M, mlook, "iron", str(theirs.get("username", "Opponent")), theirs.get("look", KNIGHT_LOOK))
	dv.set_rivalry(rep.get("rivalry", {}))
	if int(rep.get("cheers", 0)) > 0:
		dv.cheers = int(rep["cheers"])
	dv.custom_minimum_size = Vector2(0, 560)
	if spectator:
		dv.me_name = str(mine.get("username", "A"))
		dv.names.get_child(0).text = dv.me_name
	var row := UI.add_row(box, 8)
	var skip := UI.add_button(row, "SKIP", "stone", 54, 20)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(fill)
	var st := {"done": false}          # lambdas capture locals by value, so share a dictionary
	skip.pressed.connect(func(): st["done"] = true)
	var res = rep.get("result")
	var final_w := ""
	if res != null and typeof(res) == TYPE_DICTIONARY and res.get("winner") != null:
		final_w = "me" if str(res["winner"]) == str(mine.get("username", "")) else "op"
	await get_tree().create_timer(0.8).timeout
	var fight := func(): await dv.replay(a["reactions"], b["reactions"], final_w)
	fight.call()
	while not st["done"] and is_instance_valid(dv):
		await get_tree().create_timer(0.25).timeout
		if dv.caption.text.ends_with("WINS THE DUEL!") or dv.caption.text.ends_with("wins the duel.") or dv.caption.text.begins_with("A draw"):
			skip.text = "CONTINUE"
	remove_child(box)
	box.queue_free()
	shell.visible = true
	playing = false
	await _refresh()


# ------------------------------------------------------------------ more: thrones, ghosts, bounties, best-of-3, watch
func _render_more() -> void:
	UI.clear(body)
	more_tabs = UI.add_tabs(body, ["thrones", "ghosts", "bounties", "series", "watch"], ["KING", "GHOSTS", "BOUNTY", "BEST OF 3", "WATCH"],
		func(k):
			more = k
			_refresh())
	UI.set_tab(more_tabs, more)
	match more:
		"thrones":
			var r: Dictionary = await M.api.get_json("/koth")
			if not r.get("ok", false) or tab != "more":
				return
			UI.add_label(body, "Beat the king's score to take the throne. Challengers pay 10 PLS into the pot; when the king falls they keep 80%% of it and 20%% is burned.", 17, UI.MUTED)
			for t in r["thrones"]:
				var c := UI.add_card(body, "gold" if t["king"] == M.profile.get("username") else "dark")
				var g: String = t["game"]
				UI.add_label(c, "%s THRONE" % UI.game_name(g).to_upper(), 22, UI.TEAL_L)
				if t["king"] == null:
					UI.add_label(c, "Empty! The first score claims it for free.", 18, UI.GOLD)
				else:
					UI.add_label(c, "King: %s  -  score %s  -  pot %s PLS  -  %s defenses" % [t["king"], UI.n(t["score"]), UI.n(t["pot"]), UI.n(t.get("defenses", 0))], 18, UI.GOLD)
				if t["king"] != M.profile.get("username"):
					var b := UI.add_button(c, "CHALLENGE (%s PLS)" % (UI.n(t["entry"]) if t["king"] != null else "free"), "amber", 54, 20)
					b.pressed.connect(func(): _play("koth", g, ""))
				else:
					UI.add_label(c, "You hold this throne. Every failed challenge grows your pot.", 17, UI.GREEN)
		"ghosts":
			var gr := UI.add_row(body, 6)
			for g in GAMES:
				var gb := UI.add_button(gr, UI.game_name(g).split(" ")[0].to_upper(), "amber" if g == ghost_game else "stone", 48, 16)
				gb.pressed.connect(func():
					ghost_game = g
					_refresh())
			var r2: Dictionary = await M.api.get_json("/ghosts?game=" + ghost_game)
			if not r2.get("ok", false) or tab != "more":
				return
			UI.add_label(body, "Race the exact run another player set. Same challenge, their score to beat.", 17, UI.MUTED)
			if r2["ghosts"].is_empty():
				UI.add_label(body, "No ghosts yet. Set a score in practice to leave yours.", 18)
			for gh in r2["ghosts"]:
				var c2 := UI.add_card(body, "dark")
				UI.add_label(c2, "%s  -  %s  (%s)" % [gh["username"], UI.n(gh["score"]), gh["why"]], 20)
				var who: String = gh["username"]
				var rb := UI.add_button(c2, "RACE THIS GHOST", "teal", 50, 18)
				rb.pressed.connect(func(): _play("ghost", ghost_game, who))
		"bounties":
			var r3: Dictionary = await M.api.get_json("/bounties")
			if not r3.get("ok", false) or tab != "more":
				return
			UI.add_label(body, "Put PLS on your best practice score. Anyone who beats it in practice takes the bounty (5% is burned). Unclaimed bounties come back after 7 days.", 17, UI.MUTED)
			var pc := UI.add_card(body, "stone")
			var gr2 := UI.add_row(pc, 6)
			for g in GAMES:
				var gb2 := UI.add_button(gr2, UI.game_name(g).split(" ")[0].to_upper(), "amber" if g == bounty_game else "stone", 46, 16)
				gb2.pressed.connect(func():
					bounty_game = g
					_refresh())
			var amt := UI.add_input(pc, "Bounty in PLS (10 - 1000)")
			var post := UI.add_button(pc, "POST BOUNTY ON MY %s SCORE" % UI.game_name(bounty_game).to_upper(), "amber", 54, 18)
			post.pressed.connect(func(): _post("/bounty/post", {"game": bounty_game, "amount": int(amt.text)}, "Bounty posted!"))
			for b in r3["bounties"]:
				var c3 := UI.add_card(body, "gold" if not b["mine"] else "dark")
				UI.add_label(c3, "%s PLS - beat %s's %s score of %s" % [UI.n(b["amount"]), b["by"], UI.game_name(b["game"]), UI.n(b["target"])], 19, UI.GOLD)
				UI.add_label(c3, "%s days left" % UI.n(float(b["ends_in"]) / 86400.0), 16, UI.MUTED)
				if not b["mine"]:
					var g3: String = b["game"]
					var tb := UI.add_button(c3, "TRY FOR IT (practice)", "teal", 48, 18)
					tb.pressed.connect(func(): _play("practice", g3, ""))
		"series":
			var r4: Dictionary = await M.api.get_json("/series")
			if not r4.get("ok", false) or tab != "more":
				return
			UI.add_label(body, "First to two wins takes the pot (5% burned). Challenge a friend; each game shows up in DUELS.", 17, UI.MUTED)
			for inv in r4["invites"]:
				var ic := UI.add_card(body, "gold")
				UI.add_label(ic, "%s wants a best-of-3 %s for %s PLS" % [inv["from"], UI.game_name(inv["game"]), UI.n(inv["stake"])], 20, UI.GOLD)
				var row := UI.add_row(ic)
				var sid: String = inv["id"]
				var a := UI.add_button(row, "ACCEPT", "green", 50, 18)
				a.pressed.connect(func(): _post("/series/respond", {"id": sid, "accept": true}, "Series on! Play game 1 in DUELS."))
				var d := UI.add_button(row, "DECLINE", "red", 50, 18)
				d.pressed.connect(func(): _post("/series/respond", {"id": sid, "accept": false}, "Declined."))
			var sc := UI.add_card(body, "stone")
			UI.add_label(sc, "CHALLENGE TO A BEST OF 3  (%s, %d PLS)" % [UI.game_name(duel_game), duel_stake], 19, UI.AMBER)
			UI.add_label(sc, "Pick the game and stake in DUELS first.", 15, UI.MUTED)
			var nm := UI.add_input(sc, "Their username")
			var go_b := UI.add_button(sc, "SEND", "amber", 50, 18)
			go_b.pressed.connect(func(): _post("/series/challenge", {"username": nm.text.strip_edges(), "game": duel_game, "stake": duel_stake}, "Best-of-3 challenge sent!"))
			for se in r4["series"]:
				var c4 := UI.add_card(body, "dark")
				var w: Dictionary = se["wins"]
				var line := "vs %s  -  %s  -  %s PLS  -  " % [se["opponent"], UI.game_name(se["game"]), UI.n(se["stake"])]
				for k in w.keys():
					line += "%s %s  " % [k, UI.n(w[k])]
				UI.add_label(c4, line, 18)
				var st := str(se["state"])
				UI.add_label(c4, {"active": "Game %s in progress - play it in DUELS." % UI.n(se["games"]), "invited": "Waiting for them to accept.",
					"settled": "Winner: %s" % str(se.get("winner")) if se.get("winner") != null else "Draw - refunded."}.get(st, st), 17, UI.TEAL_L)
		"watch":
			var r5: Dictionary = await M.api.get_json("/duels/live")
			if not r5.get("ok", false) or tab != "more":
				return
			UI.add_label(body, "Duels being played right now and just finished. Tap one to watch the replay and react.", 17, UI.MUTED)
			for d in r5["duels"].slice(0, 25):
				var c5 := UI.add_card(body, "dark")
				var state := "LIVE (%d/2 played)" % int(d["played"]) if d["state"] == "active" else ("Winner: %s" % str(d["winner"]) if d["winner"] != null else "Draw")
				UI.add_label(c5, "%s vs %s  -  %s  -  %s PLS" % [d["a"], d["b"], UI.game_name(d["game"]), UI.n(d["stake"])], 19)
				UI.add_label(c5, state + ("   %s reactions" % UI.n(d["reactions"]) if int(d["reactions"]) > 0 else ""), 16, UI.TEAL_L if d["state"] == "active" else UI.MUTED)
				var mid: String = d["id"]
				var vrow := UI.add_row(c5, 6)
				var vb := UI.add_button(vrow, "WATCH", "teal", 46, 18)
				vb.pressed.connect(func(): _show_replay(mid))
				var chb := UI.add_button(vrow, "CHEER (%d)" % int(d.get("cheers", 0)), "amber", 46, 18)
				chb.pressed.connect(func():
					var rr: Dictionary = await M.api.post("/duels/cheer", {"id": mid})
					if rr.get("ok", false):
						chb.text = "CHEERED (%d)" % int(rr["cheers"])
						chb.disabled = true
						M.play("coin", 1.3)
					else:
						M.error_toast(rr))


func _show_replay(mid: String) -> void:
	var r: Dictionary = await M.api.get_json("/duels/replay?id=" + mid)
	if not r.get("ok", false):
		M.error_toast(r)
		return
	UI.clear(body)
	var back := UI.add_button(body, "BACK", "stone", 50, 18)
	back.pressed.connect(func(): _refresh())
	UI.add_label(body, "%s DUEL - %s PLS" % [UI.game_name(r["game"]).to_upper(), UI.n(r["stake"])], 24, UI.GOLD)
	for side in r["sides"]:
		var c := UI.add_card(body, "dark")
		UI.add_label(c, "%s  -  %s" % [side["username"], UI.n(side["score"]) if side["score"] != null else "not played yet"], 21, UI.TEAL_L)
		if side.get("detail") != null:
			UI.add_label(c, str(side["detail"]), 17, UI.MUTED)
		var rep = side.get("replay")
		if rep != null and typeof(rep) == TYPE_DICTIONARY:
			var bits := []
			if rep.has("reactions"):
				for x in rep["reactions"]:
					bits.append("early!" if int(x) < 0 else "%d ms" % int(x))
			elif rep.has("taps"):
				bits.append("%d strikes" % rep["taps"].size())
			elif rep.has("hits"):
				var n_hit := 0
				for h in rep["hits"]:
					if h.get("hit", false):
						n_hit += 1
				bits.append("%d of %d veins hit" % [n_hit, rep["hits"].size()])
			elif rep.has("reached"):
				bits.append("reached %d runes" % int(rep["reached"]))
			UI.add_label(c, "Round by round: " + ", ".join(bits), 17)
	var res = r.get("result")
	if res != null and res.get("winner") != null:
		UI.add_label(body, "WINNER: %s" % str(res["winner"]), 24, UI.GOLD)
	if int(r.get("cheers", 0)) > 0:
		UI.add_label(body, "%d spectators cheered this duel." % int(r["cheers"]), 18, UI.AMBER)
	var rv: Dictionary = r.get("rivalry", {})
	if rv.get("rival", false):
		UI.add_label(body, "RIVALS - your record: %d won, %d lost" % [int(rv["wins"]), int(rv["losses"])], 18, Color("#ff8a6a"))
	if str(r.get("game", "")) == "quickdraw" and str(r.get("state", "")) != "active":
		var fb := UI.add_button(body, "WATCH THE SWORD FIGHT", "amber", 60, 22)
		fb.pressed.connect(func(): _sword_fight(r))
	var er := UI.add_row(body, 6)
	for e in EMOTE_TEXT.keys():
		var eb := UI.add_button(er, EMOTE_TEXT[e], "stone", 48, 16)
		var ek: String = e
		eb.pressed.connect(func():
			var rr: Dictionary = await M.api.post("/duels/react", {"id": mid, "emote": ek})
			if rr.get("ok", false):
				M.toast("Sent: " + EMOTE_TEXT[ek], UI.TEAL_L)
				M.play("click"))
	var reacts: Array = r.get("reactions", [])
	if not reacts.is_empty():
		var t := ""
		for x in reacts.slice(-12):
			t += "%s: %s   " % [x["from"], EMOTE_TEXT.get(x["emote"], x["emote"])]
		UI.add_label(body, t, 16, UI.MUTED)
