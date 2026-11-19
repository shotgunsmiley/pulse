extends VBoxContainer
# THE GAMBIT HALL - luck wagering against the house with in-game PLS.
#  CRYSTAL FLIP  pick teal or amber - pays 1.94x
#  ORE DICE      roll under your target (2-95) - higher risk, higher pay
#  CAVE-IN       5x5 mine field: open safe tiles, cash out before a cave-in
#  FAIRNESS      every result is provably fair: the server commits to a hidden
#                seed (shows its hash) before you bet, and reveals it when you
#                rotate seeds, so this screen can re-check every result.
# The house keeps 3% over time. PLS has no cash value.

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


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	UI.add_title(self, "THE GAMBIT HALL", "Luck games with in-game PLS. The house keeps 3% over time. No cash value.")
	tabs = UI.add_tabs(self, ["flip", "dice", "cavein", "fair"], ["FLIP", "DICE", "CAVE-IN", "FAIR"], _set_tab)
	body = UI.add_scroll(self)


func on_open() -> void:
	var r: Dictionary = await M.api.get_json("/luck/cavein")
	if r.get("ok", false) and r["game"] != null:
		cave = r["game"]
		tab = "cavein"
	_set_tab(tab)


func on_close() -> void:
	pass


func _set_tab(t: String) -> void:
	tab = t
	UI.set_tab(tabs, t)
	UI.clear(body)
	match t:
		"flip":
			_render_flip()
		"dice":
			_render_dice()
		"cavein":
			_render_cave()
		"fair":
			await _render_fair()


func _bet_row(parent: Node) -> void:
	var card := UI.add_card(parent, "deep")
	var row := UI.add_row(card, 6)
	UI.add_label(row, "BET", 22, UI.AMBER)
	var minus := UI.add_button(row, "-", "stone", 54, 26)
	var amount := UI.add_label(row, "%d PLS" % bet, 28, UI.GOLD, true)
	var plus := UI.add_button(row, "+", "stone", 54, 26)
	minus.pressed.connect(func():
		bet = maxi(1, bet - (10 if bet > 20 else 1))
		amount.text = "%d PLS" % bet
	)
	plus.pressed.connect(func():
		bet = mini(500, bet + (10 if bet >= 20 else 1))
		amount.text = "%d PLS" % bet
	)
	var pr := UI.add_row(card, 4)
	for p in PRESETS:
		var pb := UI.add_button(pr, str(p), "dark", 46, 18)
		pb.pressed.connect(func():
			bet = p
			amount.text = "%d PLS" % bet
		)


func _after_bet(r: Dictionary, game: String) -> void:
	M.apply({"balance": r["balance"]})
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
	var r: Dictionary = await M.api.post("/luck/flip", {"bet": bet, "pick": pick})
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
		res.text = "YOU WIN +%s PLS" % UI.n(r["payout"])
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
	var r: Dictionary = await M.api.post("/luck/dice", {"bet": bet, "target": dice_target})
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
	UI.add_label(c2, "CAVE-IN - bet %s PLS, %s cave-ins" % [UI.n(cave["bet"]), UI.n(cave["caves"])], 22, UI.TEAL_L)
	var nxt = cave.get("next_multiplier")
	UI.add_label(c2, "Now x%.2f (%s PLS)   Next tile x%s" % [float(cave["multiplier"]), UI.n(float(cave["bet"]) * float(cave["multiplier"])), "%.2f" % float(nxt) if nxt != null else "-"], 20, UI.GOLD)
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
		var co := UI.add_button(c2, "CASH OUT %s PLS" % UI.n(float(cave["bet"]) * float(cave["multiplier"])), "green", 70, 26)
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
	var r: Dictionary = await M.api.post("/luck/cavein/start", {"bet": bet, "caves": caves})
	busy = false
	if not r.get("ok", false):
		M.error_toast(r)
		return
	cave = r["game"]
	M.apply({"balance": r["balance"]})
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
		M.apply({"balance": r["balance"]})
		history.append({"game": "cavein", "nonce": int(cave["nonce"]), "roll": -1.0})
	elif r.get("cleared", false):
		M.play("rare")
		M.toast("Cleared every safe tile! +%s PLS" % UI.n(r["payout"]), UI.GOLD)
		M.apply({"balance": r["balance"]})
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
	M.apply({"balance": r["balance"]})
	M.play("win")
	M.toast("Cashed out +%s PLS" % UI.n(r["payout"]), UI.GREEN)
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
		var expect := f if h["game"] == "flip" else floorf(f * 10000.0) / 100.0
		var tol := 0.002 if h["game"] == "dice" else 0.000002
		if absf(expect - float(h["roll"])) < tol:
			good += 1
	out.text = "Revealed secret: %s\nHash matches: %s\nRe-checked %d of %d flips/dice from this session: %s" % [
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
