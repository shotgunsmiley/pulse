extends VBoxContainer
# THE GAMBIT HALL - luck wagering against the house with in-game PLS.
#  CRYSTAL FLIP  pick teal or amber - pays 1.94x
#  ORE DICE      roll under your target (2-95) - higher risk, higher pay
#  CAVE-IN       5x5 mine field: open safe tiles, cash out before a cave-in
#  FAIRNESS      every result is provably fair: the server commits to a hidden
#                seed (shows its hash) before you bet, and reveals it when you
#                rotate seeds, so this screen can re-check every result.
#  HIGH-LOW ORE  higher or lower than this ore card? cash out any time
#  CART DROP     an ore falls through 10 rows of pegs into a prize slot (3 risk levels)
#  THREE CHESTS  pick a chest: empty, half, or 2.41x - then double-or-nothing if you dare
#  LUCKY WHEEL   spin for a multiplier; plus one free daily spin that pays ore
# Every game can be played for PLS or for ore. The house keeps 3% over time. PLS has no cash value.

const UI = preload("res://scripts/ui.gd")
const PRESETS := [5, 10, 25, 50, 100]

var M
var tabs := {}
var tab := "flip"
var body: VBoxContainer
var bet := 10
var dice_target := 50
var caves := 3
var cave := {}            # active cave-in run from the server
var history := []         # this session's results: {"game","nonce","roll"} for later checking
var fair := {}
var busy := false
var cur := "pls"          # bet with "pls" or "ore"
var ore_kind := "coal"
var info := {}            # /luck/info: tables, wheel layout, free spin, open runs
var hl := {}              # open High-Low run
var risk := "medium"      # Cart Drop risk
var chest := {}           # open chest prize
const ORES := ["coal", "iron", "crystal", "void"]


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	UI.add_title(self, "THE GAMBIT HALL", "Luck games for PLS or ore. The house keeps 3% over time. No cash value.")
	# 8 games: two rows of four
	tabs = {}
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	add_child(grid)
	var keys := ["flip", "dice", "cavein", "highlow", "drop", "chests", "wheel", "fair"]
	var labels := ["FLIP", "DICE", "CAVE-IN", "HIGH-LOW", "CART DROP", "CHESTS", "WHEEL", "FAIR"]
	for i in range(keys.size()):
		var key: String = keys[i]
		var b := UI.add_button(grid, labels[i], "stone", 48, 17)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func(): _set_tab(key))
		tabs[key] = b
	body = UI.add_scroll(self)


func on_open() -> void:
	var r: Dictionary = await M.api.get_json("/luck/cavein")
	if r.get("ok", false) and r["game"] != null:
		cave = r["game"]
		tab = "cavein"
	var li: Dictionary = await M.api.get_json("/luck/info")
	if li.get("ok", false):
		info = li
		if li.get("highlow") != null:
			hl = li["highlow"]
			tab = "highlow"
		if li.get("chests_open") != null:
			chest = li["chests_open"]
			tab = "chests"
	_set_tab(tab)


func on_close() -> void:
	pass


func _set_tab(t: String) -> void:
	tab = t
	busy = false          # an animation cut short by a tab change must not lock the Hall
	UI.set_tab(tabs, t)
	UI.clear(body)
	match t:
		"flip":
			_render_flip()
		"dice":
			_render_dice()
		"cavein":
			_render_cave()
		"highlow":
			_render_highlow()
		"drop":
			_render_drop()
		"chests":
			_render_chests()
		"wheel":
			_render_wheel()
		"fair":
			await _render_fair()
	if info.get("gotd_luck", "") == t:
		var gl := UI.add_label(body, "LUCK GAME OF THE DAY", 18, UI.GOLD, true)
		body.move_child(gl, 0)


func _unit() -> String:
	return "PLS" if cur == "pls" else ore_kind


func _have() -> int:
	return int(M.profile.get("balance", 0)) if cur == "pls" else int(M.profile.get("ore", {}).get(ore_kind, 0))


# Every bet goes out with the currency the player picked.
func _b(extra: Dictionary) -> Dictionary:
	var d := {"bet": bet, "currency": cur, "ore": ore_kind}
	d.merge(extra, true)
	return d


func _apply(r: Dictionary) -> void:
	var x := {}
	if r.has("balance"):
		x["balance"] = r["balance"]
	if r.has("ore_inv"):
		x["ore_inv"] = r["ore_inv"]
	M.apply(x)


func _bet_row(parent: Node) -> void:
	var card := UI.add_card(parent, "deep")
	# play for PLS, or for ore with nothing but ore at risk
	var crow := UI.add_row(card, 6)
	var pb_ := UI.add_button(crow, "PLAY FOR PLS", "amber" if cur == "pls" else "stone", 46, 16)
	var ob := UI.add_button(crow, ("PLAY FOR ORE: %s" % ore_kind.to_upper()) if cur == "ore" else "PLAY FOR ORE", "amber" if cur == "ore" else "stone", 46, 16)
	pb_.pressed.connect(func():
		cur = "pls"
		_set_tab(tab))
	ob.pressed.connect(func():
		if cur == "ore":
			ore_kind = ORES[(ORES.find(ore_kind) + 1) % ORES.size()]
		cur = "ore"
		_set_tab(tab))
	UI.add_label(card, "You have %s %s.%s" % [UI.n(_have()), _unit(), "  Tap again to change ore." if cur == "ore" else ""], 16, UI.MUTED)
	var row := UI.add_row(card, 6)
	UI.add_label(row, "BET", 22, UI.AMBER)
	var minus := UI.add_button(row, "-", "stone", 54, 26)
	var amount := UI.add_label(row, "%d %s" % [bet, _unit()], 28, UI.GOLD, true)
	var plus := UI.add_button(row, "+", "stone", 54, 26)
	minus.pressed.connect(func():
		bet = maxi(1, bet - (10 if bet > 20 else 1))
		amount.text = "%d %s" % [bet, _unit()]
	)
	plus.pressed.connect(func():
		bet = mini(500, bet + (10 if bet >= 20 else 1))
		amount.text = "%d %s" % [bet, _unit()]
	)
	var pr := UI.add_row(card, 4)
	for p in PRESETS:
		var pb := UI.add_button(pr, str(p), "dark", 46, 18)
		pb.pressed.connect(func():
			bet = p
			amount.text = "%d %s" % [bet, _unit()]
		)


func _after_bet(r: Dictionary, game: String) -> void:
	_apply(r)
	history.append({"game": game, "nonce": int(r["nonce"]), "roll": float(r.get("roll", -1.0)), "hash": str(r.get("server_hash", ""))})


# ------------------------------------------------------------------ flip
func _render_flip() -> void:
	_bet_row(body)
	var card := UI.add_card(body, "dark")
	UI.add_label(card, "CRYSTAL FLIP", 26, UI.TEAL_L)
	UI.add_label(card, "Call the crystal. Right call pays 1.94x your bet.", 18, UI.MUTED)
	var disp := UI.add_label(card, "?", 64, UI.WHITE, true)
	var res := UI.add_label(card, "", 24, UI.WHITE, true)
	var row := UI.add_row(card)
	var teal := UI.add_button(row, "TEAL", "teal", 90, 30)
	var amber := UI.add_button(row, "AMBER", "amber", 90, 30)
	teal.pressed.connect(func(): _flip("teal", disp, res))
	amber.pressed.connect(func(): _flip("amber", disp, res))


func _flip(pick: String, disp: Label, res: Label) -> void:
	if busy:
		return
	busy = true
	var r: Dictionary = await M.api.post("/luck/flip", _b({"pick": pick}))
	if not r.get("ok", false):
		busy = false
		M.error_toast(r)
		return
	for i in range(8):
		disp.text = "TEAL" if i % 2 == 0 else "AMBER"
		disp.add_theme_color_override("font_color", UI.TEAL_L if i % 2 == 0 else UI.AMBER)
		M.play("flip")
		await get_tree().create_timer(0.07 + i * 0.015).timeout
	var side := str(r["result"])
	disp.text = side.to_upper()
	disp.add_theme_color_override("font_color", UI.TEAL_L if side == "teal" else UI.AMBER)
	_result_text(res, r)
	_after_bet(r, "flip")
	busy = false


func _result_text(res: Label, r: Dictionary) -> void:
	if r["win"]:
		res.text = "YOU WIN +%s %s" % [UI.n(r["payout"]), "PLS" if str(r.get("currency", "pls")) == "pls" else str(r.get("ore", "ore"))]
		res.add_theme_color_override("font_color", UI.GREEN)
		M.play("win")
		M.vibrate(60)
	else:
		res.text = "The house wins this one."
		res.add_theme_color_override("font_color", UI.RED)
		M.play("lose")


# ------------------------------------------------------------------ dice
func _render_dice() -> void:
	_bet_row(body)
	var card := UI.add_card(body, "dark")
	UI.add_label(card, "ORE DICE", 26, UI.TEAL_L)
	UI.add_label(card, "Roll 0.00-99.99. Win if the roll is UNDER your target.", 18, UI.MUTED)
	var odds := UI.add_label(card, "", 22, UI.GOLD, true)
	var slider := HSlider.new()
	slider.min_value = 2
	slider.max_value = 95
	slider.step = 1
	slider.value = dice_target
	slider.custom_minimum_size = Vector2(0, 56)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_child(slider)
	var disp := UI.add_label(card, "--.--", 64, UI.WHITE, true)
	var res := UI.add_label(card, "", 24, UI.WHITE, true)
	var upd := func(v):
		dice_target = int(v)
		odds.text = "Target under %d  -  win chance %d%%  -  pays %.2fx" % [dice_target, dice_target, 97.0 / dice_target]
	upd.call(dice_target)
	slider.value_changed.connect(upd)
	var roll := UI.add_button(card, "ROLL", "amber", 80, 30)
	roll.pressed.connect(func(): _dice(disp, res))


func _dice(disp: Label, res: Label) -> void:
	if busy:
		return
	busy = true
	var r: Dictionary = await M.api.post("/luck/dice", _b({"target": dice_target}))
	if not r.get("ok", false):
		busy = false
		M.error_toast(r)
		return
	for i in range(9):
		disp.text = "%05.2f" % randf_range(0.0, 99.99)
		M.play("roll")
		await get_tree().create_timer(0.06).timeout
	disp.text = "%05.2f" % float(r["roll"])
	disp.add_theme_color_override("font_color", UI.GREEN if r["win"] else UI.RED)
	_result_text(res, r)
	_after_bet(r, "dice")
	busy = false


# ------------------------------------------------------------------ cave-in
func _render_cave() -> void:
	if cave.is_empty():
		_bet_row(body)
		var card := UI.add_card(body, "dark")
		UI.add_label(card, "CAVE-IN", 26, UI.TEAL_L)
		UI.add_label(card, "25 tiles hide some cave-ins. Every safe tile raises your multiplier. Cash out any time - hit a cave-in and you lose the bet.", 18, UI.MUTED)
		var lab := UI.add_label(card, "", 22, UI.GOLD, true)
		var slider := HSlider.new()
		slider.min_value = 1
		slider.max_value = 10
		slider.step = 1
		slider.value = caves
		slider.custom_minimum_size = Vector2(0, 56)
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_child(slider)
		var upd := func(v):
			caves = int(v)
			lab.text = "%d cave-ins  -  first safe tile pays %.2fx" % [caves, _mult(caves, 1)]
		upd.call(caves)
		slider.value_changed.connect(upd)
		var start := UI.add_button(card, "START RUN", "amber", 76, 28)
		start.pressed.connect(_cave_start)
		return
	var c2 := UI.add_card(body, "dark")
	UI.add_label(c2, "CAVE-IN - bet %s %s, %s cave-ins" % [UI.n(cave["bet"]), _unit(), UI.n(cave["caves"])], 22, UI.TEAL_L)
	var nxt = cave.get("next_multiplier")
	UI.add_label(c2, "Now x%.2f (%s %s)   Next tile x%s" % [float(cave["multiplier"]), UI.n(float(cave["bet"]) * float(cave["multiplier"])), _unit(), "%.2f" % float(nxt) if nxt != null else "-"], 20, UI.GOLD)
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	c2.add_child(grid)
	# JSON numbers arrive as floats; turn them into ints so has(i) matches.
	var opened := []
	for x in cave["opened"]:
		opened.append(int(x))
	var caves_shown := []
	for x in cave.get("cave_cells", []):
		caves_shown.append(int(x))
	for i in range(25):
		var kind := "stone"
		var txt := ""
		if caves_shown.has(i):
			kind = "red"
			txt = "X"
		elif opened.has(i):
			kind = "teal"
			txt = "OK"
		var b := UI.add_button(grid, txt, kind, 92, 22)
		if not opened.has(i) and caves_shown.is_empty():
			b.pressed.connect(func(): _cave_reveal(i))
	if caves_shown.is_empty():
		var co := UI.add_button(c2, "CASH OUT %s %s" % [UI.n(float(cave["bet"]) * float(cave["multiplier"])), _unit()], "green", 70, 26)
		co.disabled = opened.is_empty()
		co.pressed.connect(_cave_cashout)
	else:
		var again := UI.add_button(c2, "NEW RUN", "amber", 64, 24)
		again.pressed.connect(func():
			cave = {}
			_set_tab("cavein")
		)


func _mult(c: int, safe: int) -> float:
	var m := 1.0
	for i in range(safe):
		m *= float(25 - i) / float(25 - c - i)
	return m * 0.97


func _cave_start() -> void:
	if busy:
		return
	busy = true
	var r: Dictionary = await M.api.post("/luck/cavein/start", _b({"caves": caves}))
	busy = false
	if not r.get("ok", false):
		M.error_toast(r)
		return
	cave = r["game"]
	_apply(r)
	M.play("click")
	_set_tab("cavein")


func _cave_reveal(cell: int) -> void:
	if busy:
		return
	busy = true
	var r: Dictionary = await M.api.post("/luck/cavein/reveal", {"cell": cell})
	busy = false
	if not r.get("ok", false):
		M.error_toast(r)
		return
	cave = r["game"]
	if r["hit"]:
		M.play("boom")
		M.vibrate(200)
		M.toast("CAVE-IN! The bet is lost.", UI.RED)
		_apply(r)
		history.append({"game": "cavein", "nonce": int(cave["nonce"]), "roll": -1.0})
	elif r.get("cleared", false):
		M.play("rare")
		M.toast("Cleared every safe tile! +%s %s" % [UI.n(r["payout"]), _unit()], UI.GOLD)
		_apply(r)
		history.append({"game": "cavein", "nonce": int(cave["nonce"]), "roll": -1.0})
	else:
		M.play("clink")
		M.vibrate(20)
	_set_tab("cavein")


func _cave_cashout() -> void:
	if busy:
		return
	busy = true
	var r: Dictionary = await M.api.post("/luck/cavein/cashout", {})
	busy = false
	if not r.get("ok", false):
		M.error_toast(r)
		return
	cave = r["game"]
	_apply(r)
	M.play("win")
	M.toast("Cashed out +%s %s" % [UI.n(r["payout"]), _unit()], UI.GREEN)
	history.append({"game": "cavein", "nonce": int(cave["nonce"]), "roll": -1.0})
	_set_tab("cavein")


# ------------------------------------------------------------------ fairness
func _render_fair() -> void:
	var r: Dictionary = await M.api.get_json("/luck/fair")
	if not r.get("ok", false):
		M.error_toast(r)
		return
	fair = r["fair"]
	UI.clear(body)
	var card := UI.add_card(body, "deep")
	UI.add_label(card, "PROVABLY FAIR", 26, UI.TEAL_L)
	UI.add_label(card, "Before you bet, the server locks in a secret seed and shows you its fingerprint (SHA-256 hash). Each result = HMAC-SHA256(secret, your seed : bet number). Rotate seeds to reveal the secret and re-check every result.", 18, UI.MUTED)
	UI.add_label(card, "Server seed hash:", 18, UI.AMBER)
	UI.add_label(card, str(fair["server_hash"]), 16, UI.WHITE)
	UI.add_label(card, "Your seed: %s     Bets on these seeds: %s" % [str(fair["client_seed"]), UI.n(fair["nonce"])], 18, UI.WHITE)
	var seed_in := UI.add_input(card, "New seed of your own (optional)")
	var rot := UI.add_button(card, "REVEAL + NEW SEEDS", "teal", 60, 22)
	var out := UI.add_label(card, "", 18, UI.WHITE)
	rot.pressed.connect(func(): _rotate(seed_in.text.strip_edges(), out))


func _rotate(seed_text: String, out: Label) -> void:
	var r: Dictionary = await M.api.post("/luck/seed", {"client_seed": seed_text} if seed_text != "" else {})
	if not r.get("ok", false):
		M.error_toast(r)
		return
	var rev: Dictionary = r["revealed"]
	var server_seed := str(rev["server_seed"])
	var ok_hash := server_seed.sha256_text() == str(rev["server_hash"])
	var checked := 0
	var good := 0
	for h in history:
		if h["roll"] < 0.0 or str(h.get("hash", "")) != str(rev["server_hash"]):
			continue
		checked += 1
		var f := _fair_float(server_seed, str(rev["client_seed"]), int(h["nonce"]))
		var expect := f if h["game"] in ["flip", "wheel"] else floorf(f * 10000.0) / 100.0
		var tol := 0.002 if h["game"] == "dice" else 0.000002
		if absf(expect - float(h["roll"])) < tol:
			good += 1
	out.text = "Revealed secret: %s\nHash matches: %s\nRe-checked %d of %d flips, dice and wheel spins from this session: %s" % [
		server_seed, "YES" if ok_hash else "NO", good, checked, "all correct" if good == checked else "MISMATCH"]
	out.add_theme_color_override("font_color", UI.GREEN if ok_hash and good == checked else UI.RED)
	history = history.filter(func(h): return str(h.get("hash", "")) != str(rev["server_hash"]))
	M.play("coin")


# Same maths as the server: first 13 hex digits of HMAC-SHA256 / 16^13.
func _fair_float(server_seed: String, client_seed: String, nonce: int) -> float:
	var ctx := HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, server_seed.to_utf8_buffer())
	ctx.update(("%s:%d:%d" % [client_seed, nonce, 0]).to_utf8_buffer())
	var hex := ctx.finish().hex_encode()
	return float(hex.substr(0, 13).hex_to_int()) / pow(16.0, 13.0)


# ================================================================== HIGH-LOW ORE
const CARD_COL := [Color("#8a8580"), Color("#3a3634"), Color("#4a4440"), Color("#a07050"), Color("#b0683e"), Color("#c07a50"),
	Color("#e8a040"), Color("#c0304a"), Color("#5fe0cf"), Color("#3fd0bd"), Color("#3a6ad0"), Color("#9a6ae0"), Color("#b48cf0")]


func _card_panel(parent: Node, rank: int, name: String) -> void:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(0, 180)
	p.add_theme_stylebox_override("panel", UI.box(CARD_COL[clampi(rank - 1, 0, 12)].darkened(0.35), UI.GOLD, 5, 4))
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	p.add_child(v)
	UI.add_label(v, str(rank), 64, UI.WHITE, true)
	UI.add_label(v, name.to_upper(), 24, UI.GOLD, true)
	parent.add_child(p)


func _render_highlow() -> void:
	var card := UI.add_card(body, "dark")
	UI.add_label(card, "HIGH-LOW ORE", 26, UI.TEAL_L)
	UI.add_label(card, "13 ore cards, Pebble (1) to Voidstone (13). Will the next one be higher or lower? A tie loses. Cash out whenever you like.", 17, UI.MUTED)
	if hl.is_empty():
		_bet_row(body)
		body.move_child(body.get_child(body.get_child_count() - 1), 0)
		var st := UI.add_button(card, "DEAL THE FIRST CARD", "amber", 64, 24)
		st.pressed.connect(func():
			if busy:
				return
			busy = true
			var r: Dictionary = await M.api.post("/luck/highlow/start", _b({}))
			busy = false
			if not r.get("ok", false):
				M.error_toast(r)
				return
			_apply(r)
			hl = r["game"]
			M.play("flip")
			_set_tab("highlow"))
		return
	var cards: Array = hl["cards"]
	_card_panel(card, int(hl["card"]), str(hl["card_name"]))
	if cards.size() > 1:
		var trail := []
		for c in cards.slice(maxi(0, cards.size() - 8), cards.size() - 1):
			trail.append(str(c))
		UI.add_label(card, "Before: " + "  ".join(PackedStringArray(trail)), 17, UI.MUTED, true)
	var unit := "PLS" if str(hl.get("currency", "pls")) == "pls" else str(hl.get("ore", "ore"))
	UI.add_label(card, "Bet %s %s  -  %d right so far  -  cash out now: x%.2f" % [UI.n(hl["bet"]), unit, int(hl["steps"]), float(hl["multiplier"])], 19, UI.GOLD, true)
	var row := UI.add_row(card, 8)
	var hi = hl.get("next_higher")
	var lo = hl.get("next_lower")
	var hb := UI.add_button(row, "HIGHER  x%.2f" % float(hi) if hi != null else "HIGHER  -", "teal", 80, 22)
	var lb := UI.add_button(row, "LOWER  x%.2f" % float(lo) if lo != null else "LOWER  -", "amber", 80, 22)
	hb.disabled = hi == null
	lb.disabled = lo == null
	hb.pressed.connect(func(): _hl_guess("higher"))
	lb.pressed.connect(func(): _hl_guess("lower"))
	var co := UI.add_button(card, "CASH OUT  %s %s" % [UI.n(float(hl["bet"]) * float(hl["multiplier"])), unit], "green", 60, 22)
	co.disabled = int(hl["steps"]) < 1
	co.pressed.connect(func():
		if busy:
			return
		busy = true
		var r: Dictionary = await M.api.post("/luck/highlow/cashout", {})
		busy = false
		if not r.get("ok", false):
			M.error_toast(r)
			return
		_apply(r)
		M.play("win")
		M.toast("Cashed out +%s %s" % [UI.n(r["payout"]), unit], UI.GREEN)
		history.append({"game": "highlow", "nonce": -1, "roll": -1.0})
		hl = {}
		_set_tab("highlow"))


func _hl_guess(guess: String) -> void:
	if busy:
		return
	busy = true
	var r: Dictionary = await M.api.post("/luck/highlow/guess", {"guess": guess})
	busy = false
	if not r.get("ok", false):
		M.error_toast(r)
		return
	_apply(r)
	var g: Dictionary = r["game"]
	M.play("flip")
	if not r["win"]:
		M.play("lose")
		M.vibrate(120)
		M.toast("%s - wrong call. The house wins." % str(g["card_name"]).to_upper(), UI.RED)
		hl = {}
	elif r.get("done", false):
		M.play("rare")
		M.toast("THE MAX RUN! +%s" % UI.n(r["payout"]), UI.GOLD)
		hl = {}
	else:
		M.play("clink", 1.0 + int(g["steps"]) * 0.05)
		hl = g
	_set_tab("highlow")


# ================================================================== CART DROP
class PegBoard extends Control:
	var mults: Array = []
	var path: Array = []
	var step := -1.0      # ball progress through the rows (animated)
	var slot := -1

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(0, 0, w, h), Color("#1e1712"))
		var rows := 10
		var top := 30.0
		var gap_y := (h - 110) / rows
		var gap_x := w / 12.0
		for r in range(rows):
			for k in range(r + 1):
				var x := w / 2 + (k - r / 2.0) * gap_x
				draw_circle(Vector2(x, top + r * gap_y), 5, Color("#8a8078"))
		# slots
		for k in range(11):
			var x0 := w / 2 + (k - 5.5) * gap_x
			var m := float(mults[k]) if k < mults.size() else 0.0
			var col := Color("#3a6a3a") if m >= 1.0 else Color("#5a3a30")
			if m >= 3.0:
				col = Color("#b8902e")
			if k == slot:
				col = col.lightened(0.45)
			draw_rect(Rect2(x0 + 2, h - 70, gap_x - 4, 60), col)
			draw_string(ThemeDB.fallback_font, Vector2(x0 + 4, h - 32), ("%.1f" % m) if m < 10 else str(int(m)), HORIZONTAL_ALIGNMENT_LEFT, gap_x - 6, 15, Color.WHITE)
		# the falling ore
		if step >= 0.0 and not path.is_empty():
			var r2 := int(step)
			var frac := step - r2
			var pos := 0.0           # number of rights so far
			for i in range(mini(r2, path.size())):
				pos += 1.0 if path[i] == "R" else 0.0
			var x1 := w / 2 + (pos - r2 / 2.0) * gap_x
			var y1 := top + r2 * gap_y - 14
			var nxt := pos + (1.0 if r2 < path.size() and path[r2] == "R" else 0.0)
			var x2 := w / 2 + (nxt - (r2 + 1) / 2.0) * gap_x
			var y2 := top + (r2 + 1) * gap_y - 14
			if r2 >= rows:
				x2 = x1
				y2 = h - 50
			var bx := lerpf(x1, x2, frac)
			var by := lerpf(y1, y2, frac) - sin(frac * PI) * 10
			draw_circle(Vector2(bx, by), 11, Color("#3fd0bd"))
			draw_circle(Vector2(bx - 3, by - 3), 4, Color("#c8fff4"))


func _render_drop() -> void:
	_bet_row(body)
	var card := UI.add_card(body, "dark")
	UI.add_label(card, "CART DROP", 26, UI.TEAL_L)
	UI.add_label(card, "Drop an ore through 10 rows of pegs. Edges pay big, the middle pays little. Pick your risk.", 17, UI.MUTED)
	var rr := UI.add_row(card, 6)
	for k in ["low", "medium", "high"]:
		var kb := UI.add_button(rr, k.to_upper(), "amber" if k == risk else "stone", 46, 18)
		var kk: String = k
		kb.pressed.connect(func():
			risk = kk
			_set_tab("drop"))
	var board := PegBoard.new()
	board.custom_minimum_size = Vector2(0, 460)
	board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tables: Dictionary = info.get("drop", {})
	board.mults = tables.get(risk, [])
	card.add_child(board)
	var res := UI.add_label(card, "", 24, UI.WHITE, true)
	var db := UI.add_button(card, "DROP THE ORE", "amber", 64, 24)
	db.pressed.connect(func():
		if busy:
			return
		busy = true
		var r: Dictionary = await M.api.post("/luck/drop", _b({"risk": risk}))
		if not r.get("ok", false):
			busy = false
			M.error_toast(r)
			return
		board.mults = r["table"]
		board.path = r["path"]
		board.slot = -1
		for i in range(0, 110):
			if not is_instance_valid(board):
				break
			board.step = i / 10.0
			if i % 10 == 0 and i <= 100:
				M.play("click", 1.0 + i * 0.004)
			await get_tree().create_timer(0.022).timeout
		busy = false
		_after_bet(r, "cartdrop")
		if not is_instance_valid(board):
			return              # the player switched tabs mid-drop; the result is already paid
		board.slot = int(r["slot"])
		var unit := "PLS" if str(r.get("currency", "pls")) == "pls" else str(r.get("ore", "ore"))
		res.text = "x%.2f  ->  %s %s" % [float(r["multiplier"]), UI.n(r["payout"]), unit]
		res.add_theme_color_override("font_color", UI.GREEN if r["win"] else UI.RED)
		M.play("win" if r["win"] else "lose")
		if float(r["multiplier"]) >= 5.0:
			M.toast("EDGE SLOT! x%.1f" % float(r["multiplier"]), UI.GOLD)
			M.vibrate(120))


# ================================================================== THREE CHESTS
func _render_chests() -> void:
	var card := UI.add_card(body, "dark")
	UI.add_label(card, "THREE CHESTS", 26, UI.TEAL_L)
	UI.add_label(card, "One chest is empty, one holds half your bet, one holds 2.41x. Win something? Double it on a coin toss (up to 3 times) - or walk away.", 17, UI.MUTED)
	if not chest.is_empty():
		var unit := _unit()
		UI.add_label(card, "In your hands: %s %s" % [UI.n(float(chest["bet"]) * float(chest["value"])), unit], 28, UI.GOLD, true)
		var row := UI.add_row(card, 8)
		var dbl := UI.add_button(row, "DOUBLE OR NOTHING", "amber", 70, 22)
		var take := UI.add_button(row, "TAKE IT", "green", 70, 22)
		dbl.pressed.connect(func():
			if busy:
				return
			busy = true
			var r: Dictionary = await M.api.post("/luck/chests/double", {})
			busy = false
			if not r.get("ok", false):
				M.error_toast(r)
				return
			_apply(r)
			M.play("flip")
			if r["win"]:
				if r.get("done", false):
					M.toast("Doubled three times! +%s %s" % [UI.n(r["payout"]), unit], UI.GOLD)
					M.play("rare")
					chest = {}
				else:
					chest["value"] = r["value"]
					M.play("win")
			else:
				M.toast("The coin says no. Nothing this time.", UI.RED)
				M.play("lose")
				chest = {}
			_set_tab("chests"))
		take.pressed.connect(func():
			if busy:
				return
			busy = true
			var r: Dictionary = await M.api.post("/luck/chests/take", {})
			busy = false
			if not r.get("ok", false):
				M.error_toast(r)
				return
			_apply(r)
			M.play("coin")
			M.toast("+%s %s" % [UI.n(r["payout"]), unit], UI.GREEN)
			chest = {}
			_set_tab("chests"))
		return
	_bet_row(body)
	body.move_child(body.get_child(body.get_child_count() - 1), 0)
	var res := UI.add_label(card, "Pick a chest.", 22, UI.WHITE, true)
	var row2 := UI.add_row(card, 8)
	var btns := []
	for i in range(3):
		var cb := UI.add_button(row2, "CHEST %d" % (i + 1), "amber", 150, 24)
		cb.size_flags_vertical = Control.SIZE_EXPAND_FILL
		btns.append(cb)
		var pick := i
		cb.pressed.connect(func():
			if busy:
				return
			busy = true
			var r: Dictionary = await M.api.post("/luck/chests/start", _b({"pick": pick}))
			busy = false
			if not r.get("ok", false):
				M.error_toast(r)
				return
			_apply(r)
			var cont: Array = r["contents"]
			for k in range(3):
				var v := float(cont[k])
				btns[k].text = "EMPTY" if v <= 0 else ("x%.2f" % v)
				UI.style_button(btns[k], "green" if k == pick and v > 0 else ("red" if k == pick else "dark"))
				btns[k].disabled = true
			M.play("rare" if float(r["value"]) > 1 else ("coin" if float(r["value"]) > 0 else "lose"))
			if r.get("done", false):
				res.text = "Empty! The house wins."
				res.add_theme_color_override("font_color", UI.RED)
				return
			res.text = "You found %s %s!" % [str(r["prize"]), _unit()]
			res.add_theme_color_override("font_color", UI.GOLD)
			chest = {"bet": bet, "value": r["value"]}
			await get_tree().create_timer(1.3).timeout
			_set_tab("chests"))


# ================================================================== LUCKY WHEEL
class Wheel extends Control:
	var labels: Array = []
	var colors: Array = []
	var angle := 0.0

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var c := size / 2
		var r := minf(size.x, size.y) / 2 - 10
		var n := maxi(1, labels.size())
		for i in range(n):
			var a0 := angle + TAU * i / n - PI / 2
			var a1 := angle + TAU * (i + 1) / n - PI / 2
			var pts := PackedVector2Array([c])
			for k in range(9):
				var a := lerpf(a0, a1, k / 8.0)
				pts.append(c + Vector2(cos(a), sin(a)) * r)
			draw_colored_polygon(pts, colors[i] if i < colors.size() else Color.GRAY)
			var mid := (a0 + a1) / 2
			var tp := c + Vector2(cos(mid), sin(mid)) * r * 0.72
			draw_string(ThemeDB.fallback_font, tp - Vector2(16, -6), str(labels[i]), HORIZONTAL_ALIGNMENT_CENTER, 34, 15, Color.WHITE)
		draw_arc(c, r, 0, TAU, 64, Color("#ffd36b"), 4.0)
		draw_circle(c, 18, Color("#2b2724"))
		# the pointer at the top
		draw_colored_polygon(PackedVector2Array([c + Vector2(-14, -r - 14), c + Vector2(14, -r - 14), c + Vector2(0, -r + 12)]), Color("#ff5a3a"))


func _wheel_spin_to(wheel: Wheel, seg: int, n: int) -> void:
	if not is_instance_valid(wheel):
		return
	# land so that segment `seg` sits under the pointer at the top
	var target := -TAU * (seg + 0.5) / n
	var start := wheel.angle
	var full := TAU * 5.0
	var goal := target - fposmod(target - start, TAU) + full + TAU
	var tw := create_tween()
	tw.tween_property(wheel, "angle", start + (goal - start), 3.2).set_trans(Tween.TRANS_QUART).set_ease(Tween.EASE_OUT)
	for i in range(14):
		get_tree().create_timer(0.08 + i * i * 0.012).timeout.connect(func(): M.play("click", 1.3))
	await tw.finished


func _render_wheel() -> void:
	var lay: Array = info.get("wheel", [])
	var free_ready: bool = info.get("free_spin_ready", false)
	var fc := UI.add_card(body, "gold" if free_ready else "dark")
	UI.add_label(fc, "FREE DAILY SPIN", 20, UI.GOLD)
	UI.add_label(fc, "Once a day, on the house. Pays ore (and sometimes a gem). No bet.", 16, UI.MUTED)
	var fb := UI.add_button(fc, "SPIN FOR FREE" if free_ready else "BACK TOMORROW", "amber", 54, 20)
	fb.disabled = not free_ready
	_bet_row(body)
	var card := UI.add_card(body, "dark")
	UI.add_label(card, "LUCKY WHEEL", 26, UI.TEAL_L)
	UI.add_label(card, "20 slices from x0 to x5. Spin and see.", 17, UI.MUTED)
	var wheel := Wheel.new()
	wheel.custom_minimum_size = Vector2(0, 460)
	wheel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for m in lay:
		var v := float(m)
		wheel.labels.append(("x%s" % ("%.1f" % v).trim_suffix(".0")) if v > 0 else "0")
		wheel.colors.append(Color("#3a2c26") if v == 0 else (Color("#5a4a30") if v < 1 else (Color("#2a7a6a") if v < 2 else (Color("#b8902e") if v < 5 else Color("#c0304a")))))
	card.add_child(wheel)
	var res := UI.add_label(card, "", 24, UI.WHITE, true)
	var sb := UI.add_button(card, "SPIN", "amber", 64, 26)
	sb.pressed.connect(func():
		if busy:
			return
		busy = true
		var r: Dictionary = await M.api.post("/luck/wheel", _b({}))
		if not r.get("ok", false):
			busy = false
			M.error_toast(r)
			return
		await _wheel_spin_to(wheel, int(r["segment"]), lay.size())
		busy = false
		_after_bet(r, "wheel")
		if not is_instance_valid(res):
			return
		var unit := "PLS" if str(r.get("currency", "pls")) == "pls" else str(r.get("ore", "ore"))
		res.text = "x%s  ->  %s %s" % [str(r["multiplier"]), UI.n(r["payout"]), unit]
		res.add_theme_color_override("font_color", UI.GREEN if r["win"] else (UI.WHITE if float(r["multiplier"]) > 0 else UI.RED))
		M.play("win" if r["win"] else "lose"))
	fb.pressed.connect(func():
		if busy:
			return
		busy = true
		var r: Dictionary = await M.api.post("/luck/wheel/free", {})
		if not r.get("ok", false):
			busy = false
			M.error_toast(r)
			return
		# show the free wheel's prizes while it spins
		var fl: Array = r["free_layout"]
		wheel.labels = []
		wheel.colors = []
		for p in fl:
			wheel.labels.append(("%d %s" % [int(p["qty"]), str(p["ore"]).left(4)]) if str(p["ore"]) != "gem" else "GEM")
			wheel.colors.append({"coal": Color("#3a3634"), "iron": Color("#8a5536"), "crystal": Color("#2a8c8c"), "gem": Color("#c0304a")}.get(str(p["ore"]), Color.GRAY))
		await _wheel_spin_to(wheel, int(r["segment"]), fl.size())
		busy = false
		var pz: Dictionary = r["prize"]
		var txt := ("a %s!" % str(pz["gem"])) if pz.has("gem") else ("%d %s" % [int(pz["qty"]), str(pz["ore"])])
		M.toast("Free spin: %s" % txt, UI.GOLD)
		M.log_msg("Free daily spin: %s" % txt, UI.GOLD)
		M.play("rare" if pz.has("gem") else "coin")
		M.apply({"ore_inv": r["ore_inv"]})
		info["free_spin_ready"] = false
		await get_tree().create_timer(1.2).timeout
		_set_tab("wheel"))
