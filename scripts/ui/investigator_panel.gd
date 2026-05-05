extends CanvasLayer

## HUD-панель сыщика.
## Иконка-портрет всегда видна в левом нижнем углу.
## Клик открывает/закрывает горизонтальную полосу снизу с анимацией.

const _PREFS_PATH    := "user://dark_omens_prefs.cfg"
const _PREFS_SECTION := "player"
const _DATA_PATH     := "res://data/investigators.json"

const BAR_H     := 280.0   # высота выезжающей панели
const PORT_W    := 150.0   # ширина иконки-портрета (всегда видна)
const PORT_H    := 200.0   # высота иконки-портрета
const ANIM_DUR  :=   0.28
const MARGIN    :=   8.0
const SEP       :=   6.0
const ITEM_W    :=  72.0
const ITEM_H    := 112.0
const CARD_W    :=  68.0
const CARD_H    := 100.0
const MAX_CARDS :=   20

var _inv_name: String     = ""
var _inv_data: Dictionary = {}
var _shown:    bool       = false
var _tween:    Tween      = null
var _panel:    Control    = null
var _balloon:  Control    = null


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 10
	_load_data()
	_build_ui()


# ── Данные ────────────────────────────────────────────────────────────────────

func _load_data() -> void:
	# Приоритет 1: живое состояние NetworkManager (актуально для текущей сессии,
	# корректно при нескольких инстансах на одной машине)
	var nm: Node = get_node_or_null("/root/NetworkManager")
	if nm:
		var my_id: String      = (nm as Node).get("my_id")
		var players: Dictionary = (nm as Node).get("players")
		if players.has(my_id):
			_inv_name = players[my_id].get("investigator", "")
	# Приоритет 2: последний сохранённый выбор (фолбэк / соло-режим)
	if _inv_name.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(_PREFS_PATH) == OK:
			_inv_name = cfg.get_value(_PREFS_SECTION, "last_investigator", "")
	if _inv_name.is_empty():
		return
	var text: String = FileAccess.get_file_as_string(_DATA_PATH)
	if text.is_empty():
		return
	var arr: Variant = JSON.parse_string(text)
	if not arr is Array:
		return
	for i: int in range((arr as Array).size()):
		var inv: Dictionary = (arr as Array)[i]
		if inv.get("name", "") == _inv_name:
			_inv_data = inv
			break


# ── Построение UI ─────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Выезжающая панель — добавляем первой, чтобы портрет-иконка была поверх
	_panel = _make_info_panel()
	add_child(_panel)

	# Портрет-иконка (всегда видна)
	var port_btn := _make_portrait_btn()
	add_child(port_btn)

	# Балун с цитатой (над иконкой)
	_balloon = _make_balloon()
	add_child(_balloon)
	port_btn.mouse_entered.connect(func() -> void: _balloon.visible = true)
	port_btn.mouse_exited.connect(func() -> void:  _balloon.visible = false)
	port_btn.pressed.connect(_toggle)


# ── Иконка-портрет ────────────────────────────────────────────────────────────

func _make_portrait_btn() -> Button:
	var btn := Button.new()
	btn.anchor_left   = 0.0
	btn.anchor_right  = 0.0
	btn.anchor_top    = 1.0
	btn.anchor_bottom = 1.0
	btn.offset_left   = MARGIN
	btn.offset_right  = MARGIN + PORT_W
	btn.offset_top    = -(PORT_H + MARGIN)
	btn.offset_bottom = -MARGIN
	btn.flat          = true
	btn.clip_contents = true
	btn.focus_mode    = Control.FOCUS_NONE

	var sn := StyleBoxFlat.new()
	sn.bg_color = Color(0.08, 0.07, 0.13)
	sn.border_color = Color(0.55, 0.45, 0.18)
	sn.set_border_width_all(2)
	sn.set_corner_radius_all(4)
	sn.set_content_margin_all(0)
	btn.add_theme_stylebox_override("normal",   sn)
	btn.add_theme_stylebox_override("pressed",  sn)
	btn.add_theme_stylebox_override("disabled", sn)

	var sh := StyleBoxFlat.new()
	sh.bg_color = Color(0.14, 0.12, 0.22)
	sh.border_color = Color(0.78, 0.64, 0.26)
	sh.set_border_width_all(2)
	sh.set_corner_radius_all(4)
	sh.set_content_margin_all(0)
	btn.add_theme_stylebox_override("hover", sh)

	var tex := TextureRect.new()
	tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	tex.expand_mode  = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tex.texture      = _load_portrait()
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(tex)

	# Тёмная подложка под именем
	var overlay := ColorRect.new()
	overlay.anchor_left   = 0.0
	overlay.anchor_right  = 1.0
	overlay.anchor_top    = 1.0
	overlay.anchor_bottom = 1.0
	overlay.offset_top    = -44.0
	overlay.offset_bottom = 0.0
	overlay.color         = Color(0.04, 0.03, 0.08, 0.80)
	overlay.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	btn.add_child(overlay)

	var name_lbl := Label.new()
	name_lbl.text = _inv_data.get("name", _inv_name if not _inv_name.is_empty() else "???")
	name_lbl.anchor_left   = 0.0
	name_lbl.anchor_right  = 1.0
	name_lbl.anchor_top    = 1.0
	name_lbl.anchor_bottom = 1.0
	name_lbl.offset_top    = -42.0
	name_lbl.offset_bottom = -22.0
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 13)
	name_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(name_lbl)

	var occ_lbl := Label.new()
	occ_lbl.text = _inv_data.get("occupation", "")
	occ_lbl.anchor_left   = 0.0
	occ_lbl.anchor_right  = 1.0
	occ_lbl.anchor_top    = 1.0
	occ_lbl.anchor_bottom = 1.0
	occ_lbl.offset_top    = -22.0
	occ_lbl.offset_bottom = -2.0
	occ_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	occ_lbl.add_theme_font_size_override("font_size", 11)
	occ_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	occ_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(occ_lbl)

	return btn


# ── Балун с цитатой ───────────────────────────────────────────────────────────

func _make_balloon() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.anchor_left   = 0.0
	panel.anchor_right  = 0.0
	panel.anchor_top    = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left   = MARGIN
	panel.offset_right  = MARGIN + PORT_W + 80.0
	# прижат снизу к верхнему краю портрета, высота ~100px
	panel.offset_bottom = -(PORT_H + MARGIN + 4.0)
	panel.offset_top    = -(PORT_H + MARGIN + 4.0 + 100.0)
	panel.visible       = false

	var style := StyleBoxFlat.new()
	style.bg_color     = Color(0.07, 0.06, 0.13, 0.97)
	style.border_color = Color(0.55, 0.45, 0.18)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left   = 12
	style.content_margin_right  = 12
	style.content_margin_top    = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)

	var lbl := Label.new()
	lbl.text          = "«%s»" % _inv_data.get("quote", "…")
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", UIColors.MUTED)
	panel.add_child(lbl)

	return panel


# ── Выезжающая панель ─────────────────────────────────────────────────────────

func _make_info_panel() -> Control:
	var bar := Control.new()
	bar.anchor_left   = 0.0
	bar.anchor_right  = 1.0
	bar.anchor_top    = 1.0
	bar.anchor_bottom = 1.0
	bar.offset_top    = 0.0    # закрыто: скрыта под нижним краем
	bar.offset_bottom = 0.0
	bar.visible       = false

	# Фон
	var bg := Panel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color         = Color(0.05, 0.04, 0.09, 0.88)
	bg_style.border_color     = Color(0.30, 0.24, 0.50, 0.70)
	bg_style.border_width_top = 1
	bg.add_theme_stylebox_override("panel", bg_style)
	bar.add_child(bg)

	# Контент начинается правее иконки-портрета
	var cx := MARGIN + PORT_W + SEP * 2

	# Статы + навыки + роли
	var info := _make_info_col()
	info.anchor_left   = 0.0
	info.anchor_right  = 0.0
	info.anchor_top    = 0.0
	info.anchor_bottom = 1.0
	info.offset_left   = cx
	info.offset_right  = cx + 280.0
	bar.add_child(info)

	# Слоты предметов
	var items_x := cx + 280.0 + MARGIN * 2
	for idx: int in range(2):
		var slot := _make_item_slot()
		slot.anchor_left   = 0.0
		slot.anchor_right  = 0.0
		slot.anchor_top    = 0.5
		slot.anchor_bottom = 0.5
		slot.offset_left   = items_x + float(idx) * (ITEM_W + SEP)
		slot.offset_right  = items_x + float(idx) * (ITEM_W + SEP) + ITEM_W
		slot.offset_top    = -ITEM_H / 2.0
		slot.offset_bottom =  ITEM_H / 2.0
		bar.add_child(slot)

	# Веер карт
	var fan_x := items_x + 2.0 * (ITEM_W + SEP) + MARGIN * 2
	_add_card_fan(bar, fan_x)

	return bar


# ── Статы + навыки + роли ─────────────────────────────────────────────────────

func _make_info_col() -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 10)

	# HP / Рассудок
	var stats_row := HBoxContainer.new()
	stats_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	stats_row.add_theme_constant_override("separation", 32)
	vbox.add_child(stats_row)
	_stat_pill(stats_row, "❤", "%.1f" % float(_inv_data.get("health", 0)),
			Color(0.85, 0.22, 0.22), "HP")
	_stat_pill(stats_row, "✦", "%.1f" % float(_inv_data.get("sanity", 0)),
			Color(0.28, 0.55, 0.90), "РАССУДОК")

	# Навыки
	var sk: Dictionary = _inv_data.get("skills", {})
	var skills_lbl := Label.new()
	skills_lbl.text = "Lore %d  ·  Infl %d  ·  Obs %d\nStr %d  ·  Will %d" % [
		int(sk.get("lore", 0)), int(sk.get("influence", 0)),
		int(sk.get("observation", 0)), int(sk.get("strength", 0)),
		int(sk.get("will", 0))
	]
	skills_lbl.add_theme_font_size_override("font_size", 26)
	skills_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	vbox.add_child(skills_lbl)

	# Роли — бейджи с рамкой
	var roles: Array = _inv_data.get("role", [])
	if not roles.is_empty():
		var role_row := HBoxContainer.new()
		role_row.add_theme_constant_override("separation", 6)
		vbox.add_child(role_row)
		for i: int in range(roles.size()):
			role_row.add_child(_make_role_badge(roles[i]))

	return vbox


func _stat_pill(parent: Control, icon: String, val: String,
		col: Color, sub: String) -> void:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)

	var icon_lbl := Label.new()
	icon_lbl.text = icon
	icon_lbl.add_theme_font_size_override("font_size", 36)
	icon_lbl.add_theme_color_override("font_color", col)
	box.add_child(icon_lbl)

	var val_lbl := Label.new()
	val_lbl.text = val
	val_lbl.add_theme_font_size_override("font_size", 36)
	val_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	box.add_child(val_lbl)

	var sub_lbl := Label.new()
	sub_lbl.text               = sub
	sub_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sub_lbl.add_theme_font_size_override("font_size", 20)
	sub_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	box.add_child(sub_lbl)


func _make_role_badge(badge_text: String) -> PanelContainer:
	var pc := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = UIColors.ACCENT
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left   = 10
	style.content_margin_right  = 10
	style.content_margin_top    = 4
	style.content_margin_bottom = 4
	pc.add_theme_stylebox_override("panel", style)

	var lbl := Label.new()
	lbl.text = badge_text
	lbl.add_theme_font_size_override("font_size", 24)
	lbl.add_theme_color_override("font_color", UIColors.ACCENT)
	pc.add_child(lbl)
	return pc


# ── Слот предмета ─────────────────────────────────────────────────────────────

func _make_item_slot() -> Panel:
	var panel := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color     = Color(0.18, 0.13, 0.09, 0.90)
	style.border_color = Color(0.45, 0.35, 0.20)
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	panel.add_theme_stylebox_override("panel", style)
	return panel


# ── Веер карт ─────────────────────────────────────────────────────────────────

func _add_card_fan(parent: Control, start_x: float) -> void:
	var count   := MAX_CARDS
	var arc_deg := 38.0
	var step    := arc_deg / maxf(float(count) - 1.0, 1.0)
	var x_step  := CARD_W * 0.52

	for i: int in range(count):
		var angle_deg := -arc_deg / 2.0 + float(i) * step

		var card := Panel.new()
		var style := StyleBoxFlat.new()
		style.bg_color     = Color(0.20, 0.15, 0.36, 0.93)
		style.border_color = Color(0.40, 0.30, 0.60)
		style.set_border_width_all(1)
		style.set_corner_radius_all(6)
		card.add_theme_stylebox_override("panel", style)

		card.anchor_left   = 0.0
		card.anchor_right  = 0.0
		card.anchor_top    = 1.0
		card.anchor_bottom = 1.0
		card.offset_left   = start_x + float(i) * x_step
		card.offset_right  = start_x + float(i) * x_step + CARD_W
		card.offset_top    = -CARD_H - 6.0
		card.offset_bottom = -6.0

		# Поворот вокруг нижнего центра — веер раскрывается вверх
		card.pivot_offset = Vector2(CARD_W / 2.0, CARD_H)
		card.rotation     = deg_to_rad(angle_deg)

		parent.add_child(card)


# ── Анимация ──────────────────────────────────────────────────────────────────

func _toggle() -> void:
	_shown = not _shown
	if _tween and _tween.is_valid():
		_tween.kill()

	if _shown:
		_panel.offset_top = 0.0
		_panel.visible    = true
		_tween = create_tween()
		_tween.set_ease(Tween.EASE_OUT)
		_tween.set_trans(Tween.TRANS_QUART)
		_tween.tween_property(_panel, "offset_top", -BAR_H, ANIM_DUR)
	else:
		_tween = create_tween()
		_tween.set_ease(Tween.EASE_IN)
		_tween.set_trans(Tween.TRANS_QUART)
		_tween.tween_property(_panel, "offset_top", 0.0, ANIM_DUR * 0.85)
		_tween.tween_callback(func() -> void: _panel.visible = false)


# ── Портрет (загрузка) ────────────────────────────────────────────────────────

func _load_portrait() -> Texture2D:
	if not _inv_name.is_empty():
		var path := "res://assets/investigators/%s.png" % _inv_name
		if ResourceLoader.exists(path):
			return load(path) as Texture2D
	var img := Image.create(80, 100, false, Image.FORMAT_RGB8)
	img.fill(Color(0.13, 0.12, 0.20))
	return ImageTexture.create_from_image(img)
