class_name InfoBar
extends HBoxContainer

## Информационная панель внизу picker'а: HP/санити, атрибуты, стартовые предметы.
##
## Публичное API:
##   update(inv: Dictionary) — обновить значения из словаря сыщика.

# Атрибуты (translation_key, ключ в skills{}). Поле field совпадает с именем
# PNG-иконки в assets/virtues-panel/.
const ATTRIBUTES := [
	["SKILL_STRENGTH",    "strength"],
	["SKILL_LORE",        "lore"],
	["SKILL_WILL",        "will"],
	["SKILL_INFLUENCE",   "influence"],
	["SKILL_OBSERVATION", "observation"],
]

const _HP_COLOR     := Color(0.85, 0.20, 0.20)
const _SANITY_COLOR := Color(0.30, 0.55, 0.85)

# Ассеты панели атрибутов. Все @2× — выводим в half-size.
const _ATTR_PANEL_TEX: Texture2D = preload("res://assets/virtues-panel/virues-panel.png")
const _DICE_TEX:       Texture2D = preload("res://assets/virtues-panel/cube.png")
const _DIVIDER_TEX:    Texture2D = preload("res://assets/virtues-panel/divider.png")
const _ATTR_ICONS: Dictionary = {
	"strength":    preload("res://assets/virtues-panel/strength.png"),
	"lore":        preload("res://assets/virtues-panel/lore.png"),
	"will":        preload("res://assets/virtues-panel/will.png"),
	"influence":   preload("res://assets/virtues-panel/influence.png"),
	"observation": preload("res://assets/virtues-panel/observation.png"),
}

# Геометрия наложения контента на virues-panel.png. Значения в display-px
# (после × _ASSET_SCALE). Подобраны под текущий PNG — при смене ассета
# пересчитать визуально.
const _ASSET_SCALE: float = 0.5
const _TITLE_Y:            int = 6
const _TITLE_H:            int = 26
# Инсеты блока колонок от краёв панели. LEFT/RIGHT раздельные — позволяют
# не только сжать ряд, но и сдвинуть его целиком (увеличь LEFT и уменьши
# RIGHT на ту же величину → весь ряд уезжает вправо).
const _COLS_MARGIN_LEFT:   int = 5
const _COLS_MARGIN_RIGHT:  int = 3
const _COLS_MARGIN_TOP:    int = 40
const _COLS_MARGIN_BOTTOM: int = 12

# Цвет крупных цифр атрибутов — тёплое золото под бронзовые иконки.
const _ATTR_VALUE_COLOR := Color("c39b6a")

# ВРЕМЕННО / тест: модификаторы атрибутов до появления upgrade-системы.
# Атрибут с бонусом > 0 показывает строку «+N 🎲». Удалить, когда бонусы
# начнут приходить из реальных данных.
const _TEST_BONUSES := { "will": 2 }

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

# Панель атрибутов = декоративный PNG virues-panel.png с пятью встроенными
# ячейками + накладываемый поверх контент (title + 5 колонок). Панель
# фиксированного размера (НЕ stretch) — у PNG запечены разделители ячеек,
# их растягивание исказило бы рамку.
func _build_attributes_panel() -> Control:
	var disp: Vector2 = _ATTR_PANEL_TEX.get_size() * _ASSET_SCALE

	var panel := Control.new()
	panel.name = "AttrsPanel"
	panel.custom_minimum_size = disp
	# size_flags по умолчанию (FILL без EXPAND) — панель остаётся disp-ширины,
	# stats/items по бокам забирают остаток через свой EXPAND.

	var bg := TextureRect.new()
	bg.name          = "Background"
	bg.texture       = _ATTR_PANEL_TEX
	bg.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode  = TextureRect.STRETCH_SCALE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	panel.add_child(bg)

	# Заголовок в верхней полосе PNG.
	var hdr := UIStyle.label("SECTION_ATTRIBUTES", 14, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	hdr.name = "Header"
	hdr.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hdr.offset_top    = _TITLE_Y
	hdr.offset_bottom = _TITLE_Y + _TITLE_H
	panel.add_child(hdr)

	# 5 колонок, инсетнутые под встроенные ячейки PNG.
	var cols := HBoxContainer.new()
	cols.name = "Columns"
	cols.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cols.offset_left   =  _COLS_MARGIN_LEFT
	cols.offset_right  = -_COLS_MARGIN_RIGHT
	cols.offset_top    =  _COLS_MARGIN_TOP
	cols.offset_bottom = -_COLS_MARGIN_BOTTOM
	cols.add_theme_constant_override("separation", 0)
	panel.add_child(cols)

	for i: int in range(ATTRIBUTES.size()):
		cols.add_child(_make_attr_box(ATTRIBUTES[i][0], ATTRIBUTES[i][1]))
	return panel


func _make_attr_box(label_key: String, field: String) -> Control:
	var col := VBoxContainer.new()
	col.name = "Attr_%s" % field
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Выравнивание по верхнему краю — иначе колонка с dice-строкой (выше
	# остальных) центрируется иначе и элементы съезжают по высоте.
	col.alignment = BoxContainer.ALIGNMENT_BEGIN
	col.add_theme_constant_override("separation", 2)

	var name_lbl := UIStyle.label(label_key, 13, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	name_lbl.name = "Label"
	col.add_child(name_lbl)

	var icon := TextureRect.new()
	icon.name             = "Icon"
	icon.texture          = _ATTR_ICONS[field]
	icon.expand_mode      = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode     = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size      = (_ATTR_ICONS[field] as Texture2D).get_size() * _ASSET_SCALE
	icon.size_flags_horizontal    = Control.SIZE_SHRINK_CENTER
	col.add_child(icon)

	var val := UIStyle.label("—", 26, _ATTR_VALUE_COLOR, HORIZONTAL_ALIGNMENT_CENTER)
	val.name = "Value"
	col.add_child(val)
	_attr_value_lbls[field] = val

	col.add_child(_make_dice_section(field))
	return col


# Секция модификатора: разделитель divider.png + строка «+N 🎲». N — будущая
# прокачка статов. Вся секция видна только для атрибутов с бонусом > 0
# (источник — _TEST_BONUSES, временно; позже — данные upgrade-системы,
# обновлять в update()).
func _make_dice_section(field: String) -> Control:
	var bonus: int = int(_TEST_BONUSES.get(field, 0))

	var section := VBoxContainer.new()
	section.name = "DiceSection"
	section.add_theme_constant_override("separation", 6)
	section.visible = bonus > 0

	var divider := TextureRect.new()
	divider.name          = "Divider"
	divider.texture       = _DIVIDER_TEX
	divider.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
	divider.stretch_mode  = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	divider.custom_minimum_size   = _DIVIDER_TEX.get_size() * _ASSET_SCALE
	divider.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	section.add_child(divider)

	var row := HBoxContainer.new()
	row.name = "DiceRow"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	section.add_child(row)

	var mod_lbl := UIStyle.label("+%d" % bonus, 15, UIColors.ACCENT)
	mod_lbl.name = "Modifier"
	mod_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(mod_lbl)

	var dice := TextureRect.new()
	dice.name          = "Dice"
	dice.texture       = _DICE_TEX
	dice.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
	dice.stretch_mode  = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Кубик мельче остальных ассетов панели — _ASSET_SCALE * 0.5.
	dice.custom_minimum_size = _DICE_TEX.get_size() * _ASSET_SCALE * 0.5
	row.add_child(dice)
	return section


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
