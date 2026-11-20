extends VBoxContainer
# THE FORGE - craft, repair and upgrade mining gear.
# Gear only helps in the mine: pickaxe = more damage per strike, gauntlets =
# wider strike zone, visor = slower marker. Arena games are gear-neutral.

const UI = preload("res://scripts/ui.gd")
const SLOT_HELP := {"pickaxe": "More damage per strike", "gauntlets": "Wider strike zone", "visor": "Slower strike marker"}

var M
var list: VBoxContainer
var recipes := {}


func init(m) -> void:
	M = m
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	UI.add_title(self, "THE FORGE", "Ore + PLS = gear. Gear wears down as you mine - repair it here.")
	list = UI.add_scroll(self)


func on_open() -> void:
	if recipes.is_empty():
		var r: Dictionary = await M.api.get_json("/recipes")
		if not r.get("ok", false):
			M.error_toast(r)
			return
		recipes = r["recipes"]
	await M.refresh_profile()
	_render()


func on_close() -> void:
	pass


func _render() -> void:
	UI.clear(list)
	var p: Dictionary = M.profile
	var gear: Dictionary = p.get("gear", {})
	var ore: Dictionary = p.get("ore", {})
	UI.add_label(list, "EQUIPPED", 22, UI.AMBER)
	for slot in ["pickaxe", "gauntlets", "visor"]:
		var card := UI.add_card(list, "stone")
		var g = gear.get(slot)
		if g == null:
			UI.add_label(card, "%s - empty" % slot.capitalize(), 22, UI.MUTED)
			UI.add_label(card, SLOT_HELP[slot], 18, UI.MUTED)
			continue
		var stars := ""
		for i in range(int(g.get("stars", 0))):
			stars += "*"
		var nick := str(g.get("nick", ""))
		var head := UI.add_row(card, 6)
		UI.add_label(head, ("\"%s\"  (%s) %s" % [nick, str(g["name"]), stars]) if nick != "" else "%s %s" % [str(g["name"]), stars], 24, UI.TEAL_L if not g["broken"] else UI.RED)
		var nb := UI.add_button(head, "NAME", "stone", 44, 16)
		nb.custom_minimum_size = Vector2(110, 44)
		nb.size_flags_horizontal = Control.SIZE_SHRINK_END
		var name_slot: String = slot
		nb.pressed.connect(func(): _name_gear(name_slot, nick))
		UI.add_label(card, SLOT_HELP[slot] + ("   BROKEN - no bonus until repaired" if g["broken"] else ""), 18, UI.MUTED)
		var frac := float(g["dur"]) / maxf(1.0, float(g["max_dur"]))
		UI.add_bar(card, frac, UI.GREEN if frac > 0.3 else UI.RED, 14)
		UI.add_label(card, "Durability %s / %s" % [UI.n(g["dur"]), UI.n(g["max_dur"])], 18, UI.WHITE)
		var row := UI.add_row(card)
		var rc := int(g.get("repair_cost", 0))
		var rore: Dictionary = g.get("repair_ore", {})
		var needs: bool = g.get("needs_repair", rc > 0)
		var cost_parts := []
		if rc > 0:
			cost_parts.append("%d PLS" % rc)
		for k in rore.keys():
			cost_parts.append("%s %s" % [UI.n(rore[k]), UI.ore_name(k).to_lower()])
		var rep := UI.add_button(row, ("REPAIR (%s)" % " + ".join(PackedStringArray(cost_parts))) if needs else "LIKE NEW", "teal", 56, 20)
		rep.disabled = not needs or not g.get("can_repair", float(p.get("balance", 0)) >= rc)
		if needs and not rore.is_empty():
			UI.add_label(card, "Repairs take ore of this tier or better.", 15, UI.MUTED)
		rep.pressed.connect(func(): _act("/repair", {"slot": slot}, "Repaired!"))
		var up = g.get("upgrade_cost")
		if up != null:
			var up_ore: Dictionary = up["ore"]
			var parts := []
			for k in up_ore.keys():
				parts.append("%s %s" % [UI.n(up_ore[k]), UI.ore_name(k)])
			var ub := UI.add_button(row, "UPGRADE", "amber", 56, 20)
			ub.pressed.connect(func(): _act("/upgrade", {"slot": slot}, "Upgraded!"))
			UI.add_label(card, "Upgrade: %s PLS + %s" % [UI.n(up["pls"]), ", ".join(PackedStringArray(parts))], 16, UI.MUTED)
	UI.add_label(list, "RECIPES", 22, UI.AMBER)
	var ids := recipes.keys()
	ids.sort_custom(func(a, b): return _tier_rank(recipes[a]["tier"]) * 10 + _slot_rank(recipes[a]["slot"]) < _tier_rank(recipes[b]["tier"]) * 10 + _slot_rank(recipes[b]["slot"]))
	for rid in ids:
		var rec: Dictionary = recipes[rid]
		var card := UI.add_card(list, "dark")
		var head := UI.add_row(card)
		UI.add_label(head, str(rec["name"]), 24, UI.WHITE)
		UI.add_label(head, "Durability %s" % UI.n(rec["durability"]), 16, UI.MUTED)
		var chips := UI.add_row(card, 8)
		var can := float(p.get("balance", 0)) >= float(rec["cost_pls"])
		var cost: Dictionary = rec["cost_ore"]
		for k in cost.keys():
			var have := int(ore.get(k, 0))
			var need := int(cost[k])
			can = can and have >= need
			_chip(chips, UI.ORE_ICONS[k], have, need)
		_chip(chips, "coin", int(p.get("balance", 0)), int(rec["cost_pls"]))
		var b := UI.add_button(card, "FORGE" if can else "NEED MORE", "amber", 56, 22)
		b.disabled = not can
		b.pressed.connect(func(): _act("/forge", {"recipe": rid}, "Forged %s!" % rec["name"]))


func _tier_rank(t) -> int:
	return {"iron": 1, "crystal": 2, "void": 3}.get(str(t), 0)


func _slot_rank(s) -> int:
	return {"pickaxe": 1, "gauntlets": 2, "visor": 3}.get(str(s), 0)


func _chip(parent: Node, icon_name: String, have: int, need: int) -> void:
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(v)
	var r := UI.add_row(v, 4)
	UI.add_icon(r, icon_name, 24)
	UI.add_label(r, "%d/%d" % [mini(have, need), need], 18, UI.GREEN if have >= need else UI.WHITE)
	UI.add_bar(v, float(have) / maxf(1.0, float(need)), UI.GREEN if have >= need else UI.AMBER, 8)


func _act(path: String, body: Dictionary, ok_text: String) -> void:
	var r: Dictionary = await M.api.post(path, body)
	if r.get("ok", false):
		M.apply(r)
		M.play("anvil")
		M.vibrate(60)
		M.toast(ok_text, UI.GOLD)
		_render()
	else:
		M.error_toast(r)


# Name your gear: up to 16 letters. The name shows here and when you examine yourself.
func _name_gear(slot: String, current: String) -> void:
	var card := UI.add_card(list, "deep")
	list.move_child(card, 0)
	UI.add_label(card, "Name your %s" % slot, 20, UI.AMBER)
	var inp := UI.add_input(card, "e.g. Old Betsy")
	inp.text = current
	inp.max_length = 16
	var row := UI.add_row(card, 6)
	var ok := UI.add_button(row, "SAVE NAME", "amber", 50, 18)
	var cancel := UI.add_button(row, "CANCEL", "stone", 50, 18)
	cancel.pressed.connect(func(): card.queue_free())
	ok.pressed.connect(func():
		var r: Dictionary = await M.api.post("/gear/name", {"slot": slot, "name": inp.text.strip_edges()})
		if r.get("ok", false):
			M.apply(r)
			M.toast("Named it!", UI.GOLD)
			on_open()
		else:
			M.error_toast(r))
