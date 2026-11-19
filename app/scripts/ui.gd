extends RefCounted
# Shared look for Pulse: chunky panels with hard edges, gold and teal accents,
# big touch targets. Every screen builds its widgets with these helpers.
# v5: old-school menus. Every panel and button is a bevelled, slightly rough stone
# frame tinted with its colour, and gold-trimmed when highlighted.

const BG := Color("#23282E")
const PANEL := Color("#2E333A")
const PANEL_D := Color("#1f2328")
const STONE := Color("#4a4440")
const CREAM := Color("#EFE6D0")
const AMBER := Color("#E2A93B")
const TEAL := Color("#2A9D8F")
const TEAL_L := Color("#7fe3d3")
const WHITE := Color("#F5F5F2")
const MUTED := Color("#A6A69E")
const GREEN := Color("#33CC66")
const RED := Color("#E64C4C")
const GOLD := Color("#FFC93C")
const VOID := Color("#b48cf0")
const INK := Color("#2a2015")
const OUTLINE := Color("#141518")

const BTN := {
	"amber": [Color("#E2A93B"), Color("#2a2015")],
	"teal": [Color("#2A9D8F"), Color("#F5F5F2")],
	"stone": [Color("#4a4440"), Color("#F5F5F2")],
	"red": [Color("#c94040"), Color("#F5F5F2")],
	"green": [Color("#2fae5a"), Color("#F5F5F2")],
	"void": [Color("#6a3fa8"), Color("#F5F5F2")],
	"dark": [Color("#2E333A"), Color("#F5F5F2")],
}

const ORE_NAMES := {"coal": "Coal", "iron": "Iron Ore", "crystal": "Pulse Crystal", "void": "Void Shard"}
const ORE_ICONS := {"coal": "coal", "iron": "iron", "crystal": "pulse_crystal", "void": "void_shard"}
const GAME_NAMES := {"quickdraw": "Quickdraw", "sequence": "Rune Sequence", "sniper": "Vein Sniper", "strikeoff": "Strike-Off"}
const FRAME = preload("res://textures/ui_frame.png")
const FRAME_GOLD = preload("res://textures/ui_frame_gold.png")


static func box(fill: Color, border: Color = OUTLINE, width: int = 4, shadow: int = 0) -> StyleBox:
	if width <= 2:
		var sb := StyleBoxFlat.new()
		sb.bg_color = fill
		sb.border_color = border
		sb.set_border_width_all(width)
		sb.anti_aliasing = false
		sb.content_margin_left = 6
		sb.content_margin_right = 6
		return sb
	var gold := border == AMBER or border == GOLD
	var st := StyleBoxTexture.new()
	st.texture = FRAME_GOLD if gold else FRAME
	st.texture_margin_left = 8
	st.texture_margin_right = 8
	st.texture_margin_top = 8
	st.texture_margin_bottom = 8
	st.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	st.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	# the frame is light grey, so tint it a little brighter than the colour asked for
	st.modulate_color = Color(minf(fill.r * 1.18, 1.0), minf(fill.g * 1.18, 1.0), minf(fill.b * 1.18, 1.0), fill.a)
	st.content_margin_left = 14
	st.content_margin_right = 14
	st.content_margin_top = 10
	st.content_margin_bottom = 10 + mini(shadow, 3)
	return st


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = 24
	t.set_color("font_color", "Label", WHITE)
	t.set_stylebox("panel", "PanelContainer", box(PANEL, OUTLINE, 4, 4))
	t.set_stylebox("normal", "LineEdit", box(CREAM, OUTLINE, 3))
	t.set_stylebox("focus", "LineEdit", box(CREAM, AMBER, 3))
	t.set_stylebox("read_only", "LineEdit", box(Color("#cfc6b0"), OUTLINE, 3))
	t.set_color("font_color", "LineEdit", INK)
	t.set_color("font_placeholder_color", "LineEdit", Color("#8a7d63"))
	t.set_color("caret_color", "LineEdit", INK)
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	t.set_stylebox("background", "ProgressBar", box(PANEL_D, OUTLINE, 2))
	t.set_stylebox("fill", "ProgressBar", box(TEAL, OUTLINE, 2))
	t.set_constant("separation", "VBoxContainer", 10)
	t.set_constant("separation", "HBoxContainer", 10)
	t.set_color("default_color", "RichTextLabel", WHITE)
	return t


static func style_button(b: Button, kind: String = "amber") -> void:
	var c: Array = BTN.get(kind, BTN["amber"])
	var fill: Color = c[0]
	var text: Color = c[1]
	b.add_theme_stylebox_override("normal", box(fill, OUTLINE, 4, 5))
	b.add_theme_stylebox_override("hover", box(fill, OUTLINE, 4, 5))
	b.add_theme_stylebox_override("pressed", box(fill.darkened(0.2), OUTLINE, 4, 1))
	b.add_theme_stylebox_override("disabled", box(Color("#55585e"), OUTLINE, 4, 2))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	for k in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(k, text)
	b.add_theme_color_override("font_disabled_color", Color("#9a9a9a"))


static func add_button(parent: Node, text: String, kind: String = "amber", h: int = 64, font: int = 24) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", font)
	b.clip_text = true
	style_button(b, kind)
	parent.add_child(b)
	return b


static func add_label(parent: Node, text: String, size: int = 24, color: Color = WHITE, center: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if center:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(l)
	return l


static func add_title(parent: Node, text: String, sub: String = "") -> Label:
	var l := add_label(parent, text, 32, GOLD)
	if sub != "":
		add_label(parent, sub, 20, MUTED)
	return l


static func add_card(parent: Node, kind: String = "dark") -> VBoxContainer:
	var p := PanelContainer.new()
	var fills := {"dark": PANEL, "stone": STONE, "parch": CREAM, "deep": PANEL_D, "teal": Color("#1d4f49"), "void": Color("#33224d")}
	var border := AMBER if kind == "gold" else OUTLINE
	var fill: Color = fills.get(kind, PANEL)
	p.add_theme_stylebox_override("panel", box(fill, border, 4, 4))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(p)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)
	return v


static func add_row(parent: Node, sep: int = 10) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(h)
	return h


static func add_icon(parent: Node, icon_name: String, size: int = 32) -> TextureRect:
	var r := TextureRect.new()
	r.texture = load("res://icons/%s.png" % icon_name)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.custom_minimum_size = Vector2(size, size)
	parent.add_child(r)
	return r


static func add_scroll(parent: Node) -> VBoxContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(s)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	s.add_child(v)
	return v


static func add_input(parent: Node, placeholder: String, secret: bool = false) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.secret = secret
	e.custom_minimum_size = Vector2(0, 62)
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.add_theme_font_size_override("font_size", 24)
	parent.add_child(e)
	return e


static func add_bar(parent: Node, frac: float, color: Color = TEAL, h: int = 16) -> ProgressBar:
	var b := ProgressBar.new()
	b.min_value = 0.0
	b.max_value = 1.0
	b.step = 0.001
	b.value = clampf(frac, 0.0, 1.0)
	b.show_percentage = false
	b.custom_minimum_size = Vector2(0, h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_stylebox_override("fill", box(color, OUTLINE, 2))
	parent.add_child(b)
	return b


static func add_space(parent: Node, h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(c)
	return c


# A row of tab buttons. on_pick is called with the tab key.
static func add_tabs(parent: Node, keys: Array, labels: Array, on_pick: Callable) -> Dictionary:
	var row := add_row(parent, 6)
	var out := {}
	for i in range(keys.size()):
		var key: String = keys[i]
		var b := add_button(row, labels[i], "stone", 54, 20)
		b.pressed.connect(func(): on_pick.call(key))
		out[key] = b
	return out


static func set_tab(tabs: Dictionary, active: String) -> void:
	for k in tabs.keys():
		style_button(tabs[k], "amber" if k == active else "stone")


static func clear(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()


static func n(x) -> String:
	if x == null:
		return "-"
	return str(int(x))


static func ore_name(k: String) -> String:
	return ORE_NAMES.get(k, k)


static func game_name(k: String) -> String:
	return GAME_NAMES.get(k, k)


static func bb_escape(t) -> String:
	return str(t).replace("[", "[lb]")
