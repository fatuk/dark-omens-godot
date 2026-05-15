class_name InfoBar
extends HBoxContainer

## Информационная панель внизу picker'а: HP/санити, атрибуты, стартовые предметы.
##
## Публичное API:
##   update(inv: Dictionary) — обновить значения из словаря сыщика.

# Атрибуты (translation_key, ключ в skills{})
const ATTRIBUTES := [
	["SKILL_STRENGTH",    "strength"],
	["SKILL_LORE",        "lore"],
	["SKILL_WILL",        "will"],
	["SKILL_INFLUENCE",   "influence"],
	["SKILL_OBSERVATION", "observation"],
]

const _HP_COLOR     := Color(0.85, 0.20, 0.20)
const _SANITY_COLOR := Color(0.30, 0.55, 0.85)

var _hp_bar:     ProgressBar
var _hp_label:   Label
var _sanity_bar: ProgressBar
var _sanity_label: Label
var _attr_value_lbls: Dictionary = {}   # field name -> Label


func _ready() -> void:
	add_theme_constant_override("separation", 16)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_build_stats_panel())
	add_child(_build_attributes_panel())
	add_child(_build_items_panel())


# ── Public API ────────────────────────────────────────────────────────────────

func update(inv: Dictionary) -> void:
	var hp_max:  int = int(inv.get("health", 0))
	var san_max: int = int(inv.get("sanity", 0))
	_hp_bar.max_value = float(maxi(1, hp_max))
	_hp_bar.value     = float(hp_max)
	_hp_label.text    = "%d / %d" % [hp_max, hp_max]
	_sanity_bar.max_value = float(maxi(1, san_max))
	_sanity_bar.value     = float(san_max)
	_sanity_label.text    = "%d / %d" % [san_max, san_max]
	var sk: Dictionary = inv.get("skills", {})
	for field: String in _attr_value_lbls.keys():
		(_attr_value_lbls[field] as Label).text = str(int(sk.get(field, 0)))


# ── Stats ─────────────────────────────────────────────────────────────────────

func _build_stats_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "StatsPanel"
	UIStyle.style_panel(p, 14)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_stretch_ratio = 1.0
	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 8)
	p.add_child(vb)
	vb.add_child(_make_bar_row("STATS_HEALTH", _HP_COLOR,     true))
	vb.add_child(_make_bar_row("STATS_SANITY", _SANITY_COLOR, false))
	var tickets := UIStyle.label("STATS_TICKETS", 11, UIColors.MUTED)
	tickets.name = "Tickets"
	vb.add_child(tickets)
	return p


func _make_bar_row(caption_key: String, color: Color, is_hp: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "HpRow" if is_hp else "SanityRow"
	row.add_theme_constant_override("separation", 8)

	var caption := UIStyle.label(caption_key, 11, UIColors.MUTED)
	caption.name = "Caption"
	caption.custom_minimum_size = Vector2(70, 0)
	row.add_child(caption)

	var bar := _make_progress_bar(color)
	bar.name = "Bar"
	row.add_child(bar)

	var val := UIStyle.label("—", 11, UIColors.TEXT, HORIZONTAL_ALIGNMENT_RIGHT)
	val.name = "Value"
	val.custom_minimum_size = Vector2(48, 0)
	row.add_child(val)

	if is_hp:
		_hp_bar = bar
		_hp_label = val
	else:
		_sanity_bar = bar
		_sanity_label = val
	return row


func _make_progress_bar(color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(120, 14)
	var fg := StyleBoxFlat.new()
	fg.bg_color = color
	fg.set_corner_radius_all(3)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.05, 0.08)
	bg.set_corner_radius_all(3)
	bg.border_color = UIColors.BORDER
	bg.set_border_width_all(1)
	bar.add_theme_stylebox_override("fill", fg)
	bar.add_theme_stylebox_override("background", bg)
	return bar


# ── Attributes ────────────────────────────────────────────────────────────────

func _build_attributes_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "AttrsPanel"
	UIStyle.style_panel(p, 14)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_stretch_ratio = 1.5
	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 6)
	p.add_child(vb)
	var hdr := UIStyle.label("SECTION_ATTRIBUTES", 11, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	hdr.name = "Header"
	vb.add_child(hdr)
	var hb := HBoxContainer.new()
	hb.name = "Row"
	hb.add_theme_constant_override("separation", 6)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(hb)
	for i: int in range(ATTRIBUTES.size()):
		hb.add_child(_make_attr_box(ATTRIBUTES[i][0], ATTRIBUTES[i][1]))
	return p


func _make_attr_box(label_key: String, field: String) -> Control:
	var col := VBoxContainer.new()
	col.name = "Attr_%s" % field
	col.add_theme_constant_override("separation", 2)
	col.custom_minimum_size = Vector2(56, 0)

	var name_lbl := UIStyle.label(label_key, 10, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	name_lbl.name = "Label"
	col.add_child(name_lbl)

	var icon_panel := Panel.new()
	icon_panel.name = "Icon"
	icon_panel.custom_minimum_size = Vector2(36, 36)
	var icon_style := StyleBoxFlat.new()
	icon_style.bg_color = Color(0.10, 0.09, 0.16)
	icon_style.border_color = UIColors.BORDER
	icon_style.set_border_width_all(1)
	icon_style.set_corner_radius_all(18)
	icon_panel.add_theme_stylebox_override("panel", icon_style)
	col.add_child(icon_panel)

	var val := UIStyle.label("—", 18, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	val.name = "Value"
	col.add_child(val)
	_attr_value_lbls[field] = val
	return col


# ── Items ─────────────────────────────────────────────────────────────────────

func _build_items_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "ItemsPanel"
	UIStyle.style_panel(p, 14)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_stretch_ratio = 1.0
	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 6)
	p.add_child(vb)
	var hdr := UIStyle.label("SECTION_STARTING_ITEMS", 11, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	hdr.name = "Header"
	vb.add_child(hdr)
	var hb := HBoxContainer.new()
	hb.name = "Row"
	hb.add_theme_constant_override("separation", 6)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(hb)
	for i: int in range(3):
		var slot := _make_item_slot()
		slot.name = "Slot_%d" % i
		hb.add_child(slot)
	return p


func _make_item_slot() -> Control:
	var slot := PanelContainer.new()
	slot.custom_minimum_size = Vector2(64, 80)
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.08, 0.07, 0.13)
	s.border_color = UIColors.BORDER
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	slot.add_theme_stylebox_override("panel", s)
	var lbl := UIStyle.label("—", 14, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Placeholder"
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	slot.add_child(lbl)
	return slot
