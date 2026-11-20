extends VBoxContainer
# THE MARKET - trade with other players.
#  AUCTION HOUSE  sell ore, gems and fish for PLS. 5% of each sale is burned.
#  GEAR RENTAL    lend your gear for a day, or rent someone else's. 5% of the fee is burned.

const UI = preload("res://scripts/ui.gd")
const KINDS := {"ore": ["coal", "iron", "crystal", "void"], "gem": ["amber", "garnet", "sapphire", "voidstone"]}

var M
var tabs := {}
var tab := "buy"
var body: VBoxContainer
var sell_kind := "ore"
var sell_item := "coal"


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	UI.add_title(self, "THE MARKET", "Trade with other miners. 5% of every sale is burned.")
	tabs = UI.add_tabs(self, ["buy", "sell", "rent"], ["BUY", "SELL", "GEAR RENTAL"], _set_tab)
	body = UI.add_scroll(self)


func on_open() -> void:
	_set_tab(tab)


func on_close() -> void:
	pass


func _set_tab(t: String) -> void:
	tab = t
	UI.set_tab(tabs, t)
	await _refresh()


func _refresh() -> void:
	UI.clear(body)
	if tab == "rent":
		await _render_rent()
		return
	var r: Dictionary = await M.api.get_json("/market")
	if not r.get("ok", false):
		M.error_toast(r)
		return
	if tab == "buy":
		_render_buy(r["listings"])
	else:
		_render_sell(r["listings"])


func _item_name(kind: String, item: String) -> String:
	if kind == "ore":
		return UI.ore_name(item)
	return item.capitalize()


func _render_buy(listings: Array) -> void:
	# the wandering merchant (weekends): one rare dye, paid in ore
	var mm: Dictionary = M.daily.get("merchant", {})
	if mm.get("here", false):
		var mc := UI.add_card(body, "gold")
		UI.add_label(mc, "WANDERING MERCHANT - here for the weekend", 20, UI.GOLD)
		var price: Dictionary = mm.get("price", {})
		var parts := []
		for k in price.keys():
			parts.append("%s %s" % [UI.n(price[k]), str(k)])
		UI.add_label(mc, "%s  -  %s" % [str(mm.get("name", "Dye")), ", ".join(PackedStringArray(parts))], 19, UI.WHITE)
		var owned: bool = M.profile.get("cosmetics", []).has(str(mm.get("item", "")))
		var mb := UI.add_button(mc, "ALREADY YOURS" if owned else "TRADE ORE FOR IT", "amber", 50, 20)
		mb.disabled = owned
		mb.pressed.connect(func():
			var rr: Dictionary = await M.api.post("/merchant/buy", {})
			if rr.get("ok", false):
				M.apply(rr)
				M.toast("The merchant hands you the %s. Try it in ME > LOOK." % str(mm.get("name", "dye")), UI.GOLD)
				M.play("rare")
			else:
				M.error_toast(rr)
			_refresh())
	var others := listings.filter(func(x): return not x["mine"])
	if others.is_empty():
		UI.add_label(body, "Nothing for sale right now. Check back soon, or sell something yourself.", 19, UI.MUTED)
	for x in others:
		var c := UI.add_card(body, "dark")
		var row := UI.add_row(c, 6)
		UI.add_label(row, "%s x %s" % [UI.n(x["qty"]), _item_name(x["kind"], x["item"])], 20, UI.TEAL_L)
		UI.add_label(row, "%s PLS" % UI.n(x["price"]), 20, UI.GOLD)
		UI.add_label(c, "Seller: %s" % x["seller"], 16, UI.MUTED)
		var id: String = x["id"]
		var b := UI.add_button(c, "BUY", "amber", 50, 20)
		b.pressed.connect(func():
			var rr: Dictionary = await M.api.post("/market/buy", {"id": id})
			if rr.get("ok", false):
				M.toast("Bought!", UI.GOLD)
				M.play("coin")
				M.refresh_profile()
			else:
				M.error_toast(rr)
			_refresh())


func _render_sell(listings: Array) -> void:
	var c := UI.add_card(body, "stone")
	UI.add_label(c, "LIST AN ITEM", 20, UI.AMBER)
	var kr := UI.add_row(c, 6)
	for k in ["ore", "gem", "fish"]:
		var kb := UI.add_button(kr, k.to_upper(), "amber" if k == sell_kind else "stone", 46, 18)
		kb.pressed.connect(func():
			sell_kind = k
			sell_item = ""
			_refresh())
	var items: Array = KINDS.get(sell_kind, [])
	var have: Dictionary = {}
	if sell_kind == "ore":
		have = M.profile.get("ore", {})
	elif sell_kind == "gem":
		have = M.profile.get("gems", {})
	else:
		items = []
		have = M.profile.get("fish", {})
		for f in have.keys():
			items.append(f)
	if sell_item == "" and not items.is_empty():
		sell_item = items[0]
	var ir := HFlowContainer.new()
	c.add_child(ir)
	for it in items:
		var ib := UI.add_button(ir, "%s (%s)" % [_item_name(sell_kind, it), UI.n(have.get(it, 0))], "amber" if it == sell_item else "dark", 44, 16)
		ib.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		ib.custom_minimum_size = Vector2(150, 44)
		ib.pressed.connect(func():
			sell_item = it
			_refresh())
	if sell_kind == "fish" and items.is_empty():
		UI.add_label(c, "You have no fish. Try the Underground Lake.", 17, UI.MUTED)
	var qty := UI.add_input(c, "How many")
	var price := UI.add_input(c, "Total price in PLS")
	var go_b := UI.add_button(c, "LIST FOR SALE", "amber", 54, 20)
	go_b.pressed.connect(func():
		var rr: Dictionary = await M.api.post("/market/sell", {"kind": sell_kind, "item": sell_item, "qty": int(qty.text), "price": int(price.text)})
		if rr.get("ok", false):
			M.toast("Listed!", UI.GOLD)
			M.play("coin")
			M.refresh_profile()
		else:
			M.error_toast(rr)
		_refresh())
	var mine := listings.filter(func(x): return x["mine"])
	if not mine.is_empty():
		UI.add_label(body, "YOUR LISTINGS", 20, UI.AMBER)
	for x in mine:
		var row := UI.add_row(body, 6)
		UI.add_label(row, "%s x %s for %s PLS" % [UI.n(x["qty"]), _item_name(x["kind"], x["item"]), UI.n(x["price"])], 18)
		var id: String = x["id"]
		var cb := UI.add_button(row, "CANCEL", "red", 44, 16)
		cb.custom_minimum_size = Vector2(130, 44)
		cb.size_flags_horizontal = Control.SIZE_SHRINK_END
		cb.pressed.connect(func():
			await M.api.post("/market/cancel", {"id": id})
			M.refresh_profile()
			_refresh())


func _render_rent() -> void:
	var r: Dictionary = await M.api.get_json("/rentals")
	if not r.get("ok", false):
		M.error_toast(r)
		return
	UI.add_label(body, "Rent gear for 24 hours. The owner gets the fee (minus 5% burned) and the gear back when time is up.", 17, UI.MUTED)
	var returned: Dictionary = r.get("returned", {})
	for slot in returned.keys():
		var rc := UI.add_card(body, "gold")
		var sl: String = str(slot).replace("_returned", "")
		UI.add_label(rc, "Your %s came back from a rental." % str(returned[slot]), 19, UI.GOLD)
		var eb := UI.add_button(rc, "EQUIP IT", "amber", 48, 18)
		eb.pressed.connect(func():
			var rr: Dictionary = await M.api.post("/stash/claim", {"slot": sl})
			if rr.get("ok", false):
				M.apply(rr)
			_refresh())
	var gear: Dictionary = M.profile.get("gear", {})
	if not gear.is_empty():
		var oc := UI.add_card(body, "stone")
		UI.add_label(oc, "RENT OUT YOUR GEAR", 20, UI.AMBER)
		var price := UI.add_input(oc, "Price per day in PLS (5 - 5000)")
		for slot in gear.keys():
			var g: Dictionary = gear[slot]
			if g.get("rental") != null:
				continue
			var s2: String = slot
			var b := UI.add_button(oc, "RENT OUT %s" % str(g["name"]).to_upper(), "dark", 48, 18)
			b.pressed.connect(func():
				var rr: Dictionary = await M.api.post("/rent/offer", {"slot": s2, "price": int(price.text)})
				if rr.get("ok", false):
					M.toast("Your %s is up for rent." % str(g["name"]), UI.GOLD)
					M.refresh_profile()
				else:
					M.error_toast(rr)
				_refresh())
	for x in r["rentals"]:
		var c := UI.add_card(body, "dark")
		UI.add_label(c, "%s %s  (%s stars, %s durability)" % [x["gear"], "" if x["state"] == "offered" else "- RENTED", UI.n(x["stars"]), UI.n(x["dur"])], 19, UI.TEAL_L)
		UI.add_label(c, "%s PLS / day  -  owner %s" % [UI.n(x["price"]), x["owner"]], 17, UI.GOLD)
		var id: String = x["id"]
		if x["mine"] and x["state"] == "offered":
			var cb := UI.add_button(c, "TAKE IT BACK", "red", 46, 16)
			cb.pressed.connect(func():
				await M.api.post("/rent/cancel", {"id": id})
				M.refresh_profile()
				_refresh())
		elif x["state"] == "offered":
			var tb := UI.add_button(c, "RENT FOR A DAY", "amber", 46, 18)
			tb.pressed.connect(func():
				var rr: Dictionary = await M.api.post("/rent/take", {"id": id})
				if rr.get("ok", false):
					M.toast("Rented! It is equipped for 24 hours.", UI.GOLD)
					M.play("anvil")
					M.apply(rr)
				else:
					M.error_toast(rr)
				_refresh())
		elif x["renting"]:
			UI.add_label(c, "You are using this. %s hours left." % UI.n(float(x["ends_in"]) / 3600.0), 16, UI.GREEN)
