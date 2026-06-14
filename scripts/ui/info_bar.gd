class_name InfoBar
extends HBoxContainer

## Информационная панель: HP/санити, атрибуты, стартовые предметы. Используется
## в picker'е (полная) и в player-panel на карте (compact — без панели предметов).
##
## Публичное API:
##   update(inv: Dictionary) — обновить значения из словаря сыщика.

## compact=true — вариант для player-panel на карте: без панели стартовых
## предметов (карты нужны только в пикере) + по высоте не растягиваемся, чтобы
## вписаться в полосу ~240px. Задавать ДО входа в дерево (в сцене или сразу
## после InfoBar.new()).
@export var compact: bool = false

# Атрибуты (translation_key, ключ в skills{}). Поле field совпадает с именем
# PNG-иконки в assets/virtues-panel/.
const ATTRIBUTES := [
	["SKILL_STRENGTH", "strength"],
	["SKILL_LORE", "lore"],
	["SKILL_WILL", "will"],
	["SKILL_INFLUENCE", "influence"],
	["SKILL_OBSERVATION", "observation"],
]

# Ассеты левой панели (player-hud). @2× — выводим с _HUD_SCALE.
const _HUD_SCALE: float = 0.5
# Ширина жёлоба баров HP/санити (display-px). Бар фиксированной ширины —
# увеличь/уменьши это число, чтобы растянуть или сжать оба бара.
const _HUD_BAR_WIDTH: float = 180.0
const _HUD_PANEL_BG: Texture2D = preload("res://assets/player-hud/player-hud-bg.png")
const _HUD_ROW_BG: Texture2D = preload("res://assets/player-hud/hud-item-bg.png")
const _HUD_BAR_BG: Texture2D = preload("res://assets/player-hud/bar-bg.png")
const _HEALTH_ICON: Texture2D = preload("res://assets/player-hud/health-icon.png")
const _HEALTH_BAR: Texture2D = preload("res://assets/player-hud/health-bar.png")
const _SANITY_ICON: Texture2D = preload("res://assets/player-hud/sanity-icon.png")
const _SANITY_BAR: Texture2D = preload("res://assets/player-hud/sanity-ba.png")

# Иконки-медальоны токенов (выводятся в ряду ресурсов рядом с билетами).
const _CLUE_ICON: Texture2D = preload("res://assets/map/clue-icon.png")
const _RESOURCE_ICON: Texture2D = preload("res://assets/map/resource-icon.png")
const _TOKEN_ICON_H: float = 52.0  # высота медальона токена (px)

# Ассеты панели атрибутов. Все @2× — выводим в half-size.
const _ATTR_PANEL_TEX: Texture2D = preload("res://assets/virtues-panel/virues-panel.png")
const _ATTR_ICONS: Dictionary = {
	"strength": preload("res://assets/virtues-panel/strength.png"),
	"lore": preload("res://assets/virtues-panel/lore.png"),
	"will": preload("res://assets/virtues-panel/will.png"),
	"influence": preload("res://assets/virtues-panel/influence.png"),
	"observation": preload("res://assets/virtues-panel/observation.png"),
}

# Геометрия наложения контента на virues-panel.png. Значения в display-px
# (после × _ASSET_SCALE). Подобраны под текущий PNG — при смене ассета
# пересчитать визуально.
const _ASSET_SCALE: float = 0.5
# Иконки атрибутов рендерятся мельче общего @2×-масштаба: ячейка панели низкая
# (~160px), а с full-size иконкой (~74px) колонка с dice-секцией не влезала.
const _ICON_SCALE: float = 0.40
const _TITLE_Y: int = 6
const _TITLE_H: int = 26
# Инсеты блока колонок от краёв панели. LEFT/RIGHT раздельные — позволяют
# не только сжать ряд, но и сдвинуть его целиком (увеличь LEFT и уменьши
# RIGHT на ту же величину → весь ряд уезжает вправо).
const _COLS_MARGIN_LEFT: int = 5
const _COLS_MARGIN_RIGHT: int = 3
const _COLS_MARGIN_TOP: int = 40
const _COLS_MARGIN_BOTTOM: int = 12

# Compact (player-panel на карте): высота панелей ~25% меньше натуральной
# (~238 → 178px). Режем вертикальные отступы; иконки/цифры/бары не трогаем.
const _COMPACT_PANEL_H: float = 178.0
const _COMPACT_COLS_MARGIN_TOP: int = 34
const _COMPACT_COLS_MARGIN_BOTTOM: int = 8

# Цвет крупных цифр атрибутов — тёплое золото под бронзовые иконки.
const _ATTR_VALUE_COLOR := Color("c39b6a")

# Эффект «дешифровки» при смене сыщика — общий хелпер UIStyle.rune_scramble.
# Сколько рун мелькает в одном кадре. У атрибута значение — одна цифра, хватает
# одной руны; у баров HP/санити значение длиннее («NN / NN») — используем 2.
const _BAR_SCRAMBLE_RUNES: int = 2

var _hp_label: Label
var _sanity_label: Label
var _hp_fill_clip: Control  # клип заливки бара HP (ширина = доля current/max)
var _sanity_fill_clip: Control  # клип заливки бара рассудка
var _fill_inner_w: float = 0.0  # внутренняя ширина заливки бара (для пропорции)
const _VITAL_ANIM_DUR := 0.4  # длительность анимации изменения HP/рассудка (сек)
var _hp_cur: int = -1  # последнее показанное HP (для анимации; -1 = ещё не задано)
var _sanity_cur: int = -1  # последнее показанное значение рассудка
var _hp_tween: Tween = null  # активная анимация бара HP
var _sanity_tween: Tween = null  # активная анимация бара рассудка
var _attr_value_lbls: Dictionary = {}  # field name -> Label
var _items_row: HBoxContainer  # ряд карточек стартового имущества (заполняется в update)
var _tickets_row: HBoxContainer  # ряд билетов (заполняется в update из startingTickets)
var _item_deck: Array = []  # payload'ы карт имущества (для веера по клику)
var _fan: HandCarousel  # веер-просмотр карт имущества (создаётся лениво)

# Высота миниатюры карты имущества (px); ширина — по аспекту GameCard.
const _ITEM_CARD_H: float = 168.0
# «Нормальный» размер карты (как в магазине / по наведению в веере). Миниатюра —
# это полноразмерная карта, уменьшенная через scale (так шрифт/рамка выглядят
# как на полной карте, а не свёрстаны в маленьком размере).
const _ITEM_FULL_H: float = 459.0
const _ITEM_SLOTS: int = 3  # макс. карт; под столько резервируем ширину панели
const _ITEM_SEP: int = 8  # отступ между карточками
const _ITEMS_BG_MARGIN: int = 24  # 9-slice угол (в HALF-res текстуре, см. ниже)
const _ITEMS_BG_PAD: int = 18  # инсет контента от рамки фона


func _ready() -> void:
	add_theme_constant_override("separation", 16)
	# По центру, по ширине контента — панель НЕ растягивается на весь экран
	# (по бокам остаётся пусто).
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	alignment = BoxContainer.ALIGNMENT_CENTER
	if compact:
		# На карте: по высоте не растягиваемся (сидим компактно в полосе ~240px).
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_child(_build_stats_panel())
	add_child(_build_attributes_panel())
	# Панель стартовых предметов — только в пикере (на карте карты не нужны).
	if not compact:
		add_child(_build_items_panel())


# ── Public API ────────────────────────────────────────────────────────────────


func update(inv: Dictionary) -> void:
	var hp_max: int = int(inv.get("health", 0))
	var san_max: int = int(inv.get("sanity", 0))
	# В picker'е бар всегда полный (показываем max/max) — числа в значении.
	# Перед новыми числами на месте значения пробегают ктулху-руны (как у
	# атрибутов) — эффект «дешифровки» при смене сыщика. Значение длиннее
	# цифры атрибута — мелькаем по _BAR_SCRAMBLE_RUNES руны.
	# В compact (HUD на карте) HP/рассудок задаёт set_live_vitals живыми значениями
	# — здесь их не трогаем, чтобы scramble не перетирал live-значение.
	if not compact:
		_scramble_to(_hp_label, "%d / %d" % [hp_max, hp_max], _BAR_SCRAMBLE_RUNES)
		_scramble_to(_sanity_label, "%d / %d" % [san_max, san_max], _BAR_SCRAMBLE_RUNES)
	var sk: Dictionary = inv.get("skills", {})
	for field: String in _attr_value_lbls.keys():
		_scramble_to(_attr_value_lbls[field], str(int(sk.get(field, 0))))
	_render_items(inv.get("startingItems", []))
	_render_resources(inv)


## Живые значения HP/рассудка (current/max) для HUD на карте: числа «cur / max» +
## заливка баров пропорционально current/max. Изменения анимируются (ease-in-out):
## заливка и число плавно «доезжают» до нового значения. Первый показ — мгновенно.
func set_live_vitals(hp: int, hp_max: int, sanity: int, sanity_max: int) -> void:
	_animate_vital(true, hp, hp_max)
	_animate_vital(false, sanity, sanity_max)


# Анимирует один бар (HP или рассудок): ширину заливки и счёт числа от текущего
# к новому значению с ease-in-out. Без изменения значения / первый показ — мгновенно.
func _animate_vital(is_hp: bool, new_val: int, max_val: int) -> void:
	var label: Label = _hp_label if is_hp else _sanity_label
	var clip: Control = _hp_fill_clip if is_hp else _sanity_fill_clip
	if not (is_instance_valid(label) and is_instance_valid(clip)):
		return
	var target_w: float = (float(new_val) / maxf(1.0, float(max_val))) * _fill_inner_w
	var cur: int = _hp_cur if is_hp else _sanity_cur
	var prev: Tween = _hp_tween if is_hp else _sanity_tween
	var animating: bool = prev != null and prev.is_valid()
	# То же значение: если бар уже анимируется к нему — НЕ трогаем (иначе дубль
	# state_changed от отдыха/синка снапнул бы бегущий твин на финал). Иначе
	# (первый показ или смена только max без анимации) — выставляем мгновенно.
	if new_val == cur:
		if not animating:
			label.remove_theme_font_override("font")
			label.text = "%d / %d" % [new_val, max_val]
			clip.size.x = target_w
		return
	if cur < 0:
		# Первый показ — мгновенно (без анимации).
		label.remove_theme_font_override("font")  # сбросить рунный шрифт scramble
		label.text = "%d / %d" % [new_val, max_val]
		clip.size.x = target_w
		_set_vital_cur(is_hp, new_val)
		return
	# Значение изменилось — анимируем; гасим предыдущий твин, чтобы не накладывались.
	if animating:
		prev.kill()
	var tw := create_tween().set_parallel(true)
	tw.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.tween_property(clip, "size:x", target_w, _VITAL_ANIM_DUR)
	tw.tween_method(
		func(v: float) -> void: label.text = "%d / %d" % [roundi(v), max_val],
		float(cur),
		float(new_val),
		_VITAL_ANIM_DUR
	)
	if is_hp:
		_hp_tween = tw
	else:
		_sanity_tween = tw
	_set_vital_cur(is_hp, new_val)


func _set_vital_cur(is_hp: bool, v: int) -> void:
	if is_hp:
		_hp_cur = v
	else:
		_sanity_cur = v


# Анимация «дешифровки» — делегируем общему хелперу (тот же эффект, что и в орбе
# раунда на карте). Прерываема (повторный вызов убивает старый tween).
func _scramble_to(lbl: Label, final_text: String, rune_count: int = 1) -> void:
	UIStyle.rune_scramble(lbl, final_text, rune_count)


# ── Stats ─────────────────────────────────────────────────────────────────────


# Левая панель: декоративный фон player-hud-bg + поверх 2 строки статов
# (HP/санити) на ассетах player-hud + ряд билетов снизу. Панель фиксированного
# размера (= фон @_HUD_SCALE) — у фона запечены угловые орнаменты.
func _build_stats_panel() -> Control:
	var panel := Control.new()
	panel.name = "StatsPanel"
	panel.custom_minimum_size = _HUD_PANEL_BG.get_size() * _HUD_SCALE
	if compact:
		panel.custom_minimum_size.y = _COMPACT_PANEL_H

	var bg := TextureRect.new()
	bg.name = "Background"
	bg.texture = _HUD_PANEL_BG
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(bg)

	var vb := VBoxContainer.new()
	vb.name = "Rows"
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 6)
	panel.add_child(vb)
	vb.add_child(_make_hud_stat_row("HealthRow", "STATS_HEALTH", _HEALTH_ICON, _HEALTH_BAR, true))
	vb.add_child(_make_hud_stat_row("SanityRow", "STATS_SANITY", _SANITY_ICON, _SANITY_BAR, false))
	# Ряд билетов/ресурсов — только в пикере; на карте (compact) опускаем.
	if not compact:
		vb.add_child(_make_tickets_row())
	return panel


# Строка стата: фон hud-item-bg + иконка-медальон слева + (лейбл / бар+значение).
func _make_hud_stat_row(
	node_name: String, label_key: String, icon_tex: Texture2D, fill_tex: Texture2D, is_hp: bool
) -> Control:
	var row := Control.new()
	row.name = node_name
	row.custom_minimum_size = _HUD_ROW_BG.get_size() * _HUD_SCALE
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	var bg := TextureRect.new()
	bg.name = "Background"
	bg.texture = _HUD_ROW_BG
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bg)

	var content := HBoxContainer.new()
	content.name = "Content"
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.offset_left = 8
	content.offset_right = -10
	content.offset_top = 6
	content.offset_bottom = -6
	content.add_theme_constant_override("separation", 8)
	row.add_child(content)

	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = icon_tex
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = icon_tex.get_size() * _HUD_SCALE
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	content.add_child(icon)

	var info := VBoxContainer.new()
	info.name = "Info"
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info.add_theme_constant_override("separation", 3)
	content.add_child(info)

	var caption := UIStyle.label(label_key, 13, UIColors.ACCENT)
	caption.name = "Caption"
	info.add_child(caption)

	var bar_row := HBoxContainer.new()
	bar_row.name = "BarRow"
	bar_row.add_theme_constant_override("separation", 8)
	info.add_child(bar_row)
	bar_row.add_child(_make_hud_bar(fill_tex, is_hp))

	# Значение прижато влево — цифры держатся вплотную к концу бара, а не
	# улетают к правому краю строки.
	var val := UIStyle.label("—", 13, _ATTR_VALUE_COLOR, HORIZONTAL_ALIGNMENT_LEFT)
	val.name = "Value"
	val.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# Фикс. ширина — при scramble'е на месте «NN / NN» мелькает одна руна;
	# без неё ширина значения скакала бы и дёргала бар.
	val.custom_minimum_size.x = 56
	bar_row.add_child(val)

	if is_hp:
		_hp_label = val
	else:
		_sanity_label = val
	return row


# Бар: жёлоб bar-bg + заливка fill_tex поверх. Долю заполнения задаёт ширина
# клипа (set_live_vitals); по умолчанию полная.
func _make_hud_bar(fill_tex: Texture2D, is_hp: bool) -> Control:
	var bar := Control.new()
	bar.name = "Bar"
	bar.custom_minimum_size = Vector2(_HUD_BAR_WIDTH, _HUD_BAR_BG.get_size().y * _HUD_SCALE)
	bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var groove := TextureRect.new()
	groove.name = "Groove"
	groove.texture = _HUD_BAR_BG
	groove.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	groove.stretch_mode = TextureRect.STRETCH_SCALE
	groove.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	groove.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(groove)

	# Заливка инсетится внутрь рамки жёлоба. Долю заполнения (current/max) задаёт
	# ШИРИНА клипа: внутри заливка во всю внутреннюю ширину, клип её обрезает
	# слева-направо (текстура не сжимается, а отсекается). По умолчанию полная.
	var inset_x: float = (_HUD_BAR_BG.get_size().x - fill_tex.get_size().x) * 0.5 * _HUD_SCALE
	var inset_y: float = (_HUD_BAR_BG.get_size().y - fill_tex.get_size().y) * 0.5 * _HUD_SCALE
	var bar_h: float = _HUD_BAR_BG.get_size().y * _HUD_SCALE
	var inner_w: float = _HUD_BAR_WIDTH - 2.0 * inset_x
	_fill_inner_w = inner_w

	var clip := Control.new()
	clip.name = "FillClip"
	clip.clip_contents = true
	clip.position = Vector2(inset_x, inset_y)
	clip.size = Vector2(inner_w, bar_h - 2.0 * inset_y)
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(clip)

	var fill := TextureRect.new()
	fill.name = "Fill"
	fill.texture = fill_tex
	fill.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fill.stretch_mode = TextureRect.STRETCH_SCALE
	fill.position = Vector2.ZERO
	fill.size = Vector2(inner_w, clip.size.y)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip.add_child(fill)

	if is_hp:
		_hp_fill_clip = clip
	else:
		_sanity_fill_clip = clip
	return bar


# Ряд ресурсов под статами — заполняется в update(): билеты + токены (улики,
# ресурсы). Фикс. высота — чтобы строка не схлопывалась без ресурсов и панель не
# дёргалась при смене сыщика. Между группами — положительный отступ (нахлёст
# билетов — внутри своей под-группы).
func _make_tickets_row() -> Control:
	_tickets_row = HBoxContainer.new()
	_tickets_row.name = "ResourcesRow"
	_tickets_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_tickets_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_tickets_row.add_theme_constant_override("separation", 16)
	_tickets_row.custom_minimum_size.y = TicketsRow.ticket_height_px()
	return _tickets_row


# Ресурсы под статами: билеты (startingTickets) + токены улик/ресурсов из
# startingItems ({clue:N}/{resource:N}). На старте сыщик не имеет 2 билетов И
# токенов одновременно — ряд всегда влезает.
func _render_resources(inv: Dictionary) -> void:
	if not is_instance_valid(_tickets_row):
		return
	for c in _tickets_row.get_children():
		c.queue_free()
	var tk: Dictionary = inv.get("startingTickets", {})
	var train: int = int(tk.get("train", 0))
	var ship: int = int(tk.get("ship", 0))
	if train > 0 or ship > 0:
		var tickets := TicketsRow.new()
		tickets.name = "Tickets"
		tickets.set_counts(train, ship)
		_tickets_row.add_child(tickets)
	var items: Array = inv.get("startingItems", [])
	var clue: int = _token_count(items, "clue")
	var resource: int = _token_count(items, "resource")
	if clue > 0:
		_tickets_row.add_child(_make_token(_CLUE_ICON, clue))
	if resource > 0:
		_tickets_row.add_child(_make_token(_RESOURCE_ICON, resource))


# Сумма токенов вида {key: N} в списке стартового имущества.
func _token_count(items: Array, key: String) -> int:
	var n: int = 0
	for e in items:
		if e is Dictionary and (e as Dictionary).has(key):
			n += int((e as Dictionary)[key])
	return n


# Токен-чип: круглый медальон-иконка + число.
func _make_token(icon_tex: Texture2D, count: int) -> Control:
	var hb := HBoxContainer.new()
	hb.name = "Token"
	hb.add_theme_constant_override("separation", 3)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = icon_tex
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var s: float = _TOKEN_ICON_H / icon_tex.get_size().y
	icon.custom_minimum_size = icon_tex.get_size() * s
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hb.add_child(icon)

	var lbl := UIStyle.label("×%d" % count, 20, _ATTR_VALUE_COLOR)
	lbl.name = "Count"
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hb.add_child(lbl)
	return hb


# ── Attributes ────────────────────────────────────────────────────────────────


# Панель атрибутов = декоративный PNG virues-panel.png с пятью встроенными
# ячейками + накладываемый поверх контент (title + 5 колонок). Панель
# фиксированного размера (НЕ stretch) — у PNG запечены разделители ячеек,
# их растягивание исказило бы рамку.
func _build_attributes_panel() -> Control:
	var disp: Vector2 = _ATTR_PANEL_TEX.get_size() * _ASSET_SCALE
	if compact:
		disp.y = _COMPACT_PANEL_H

	var panel := Control.new()
	panel.name = "AttrsPanel"
	panel.custom_minimum_size = disp
	# size_flags по умолчанию (FILL без EXPAND) — панель остаётся disp-ширины,
	# stats/items по бокам забирают остаток через свой EXPAND.

	var bg := TextureRect.new()
	bg.name = "Background"
	bg.texture = _ATTR_PANEL_TEX
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(bg)

	# Заголовок в верхней полосе PNG.
	var hdr := UIStyle.label("SECTION_ATTRIBUTES", 14, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	hdr.name = "Header"
	hdr.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hdr.offset_top = _TITLE_Y
	hdr.offset_bottom = _TITLE_Y + _TITLE_H
	panel.add_child(hdr)

	# 5 колонок, инсетнутые под встроенные ячейки PNG.
	var cols := HBoxContainer.new()
	cols.name = "Columns"
	cols.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cols.offset_left = _COLS_MARGIN_LEFT
	cols.offset_right = -_COLS_MARGIN_RIGHT
	cols.offset_top = _COMPACT_COLS_MARGIN_TOP if compact else _COLS_MARGIN_TOP
	cols.offset_bottom = -(_COMPACT_COLS_MARGIN_BOTTOM if compact else _COLS_MARGIN_BOTTOM)
	cols.add_theme_constant_override("separation", 0)
	panel.add_child(cols)

	for i: int in range(ATTRIBUTES.size()):
		cols.add_child(_make_attr_box(ATTRIBUTES[i][0], ATTRIBUTES[i][1]))
	return panel


func _make_attr_box(label_key: String, field: String) -> Control:
	var col := VBoxContainer.new()
	col.name = "Attr_%s" % field
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_BEGIN
	col.add_theme_constant_override("separation", 0)

	# Равномерный вертикальный ритм: 4 одинаковых expand-спейсера (сверху, между
	# элементами и снизу) распределяют название/иконку/число с равными отступами.
	col.add_child(_attr_spacer("SpacerTop"))

	var name_lbl := UIStyle.label(label_key, 13, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	name_lbl.name = "Label"
	col.add_child(name_lbl)

	col.add_child(_attr_spacer("SpacerAboveIcon"))

	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.texture = _ATTR_ICONS[field]
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = (_ATTR_ICONS[field] as Texture2D).get_size() * _ICON_SCALE
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(icon)

	col.add_child(_attr_spacer("SpacerBelowIcon"))

	var val := UIStyle.label("—", 26, _ATTR_VALUE_COLOR, HORIZONTAL_ALIGNMENT_CENTER)
	val.name = "Value"
	# Фиксированная высота + вертикальный центр — руны при scramble'е другой
	# метрики, чем цифры; без этого само число дёргалось бы по высоте.
	val.custom_minimum_size.y = 36
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	col.add_child(val)
	_attr_value_lbls[field] = val

	col.add_child(_attr_spacer("SpacerBottom"))
	return col


# Распорка-spacer колонки атрибута (равные expand'ы задают вертикальный ритм).
func _attr_spacer(spacer_name: String) -> Control:
	var sp := Control.new()
	sp.name = spacer_name
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return sp


# ── Items ─────────────────────────────────────────────────────────────────────

# player-hud-bg @2× → half-res ImageTexture для 9-slice (углы рисуются 1:1 в px
# текстуры, поэтому без уменьшения были бы вдвое крупнее). Кэш — общий.
static var _hud_bg_half_cache: ImageTexture = null


static func _hud_bg_half() -> Texture2D:
	if _hud_bg_half_cache == null:
		var img: Image = _HUD_PANEL_BG.get_image()
		if img.is_compressed():
			img.decompress()
		img.resize(
			int(img.get_width() * 0.5), int(img.get_height() * 0.5), Image.INTERPOLATE_LANCZOS
		)
		_hud_bg_half_cache = ImageTexture.create_from_image(img)
	return _hud_bg_half_cache


# Панель стартового имущества: заголовок + ряд карточек (GameCard). Ряд
# наполняется в update() из inv.startingItems (id ассетов AssetCatalog). Панель по
# ширине контента — НЕ растягивается (общий ряд InfoBar центрирован).
func _build_items_panel() -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "ItemsPanel"
	# Оформление как у панели статов — player-hud-bg.png. 9-slice: угловые орнаменты
	# не тянутся, центр/края растягиваются под размер панели. Текстура @2× —
	# уменьшаем вдвое (9-slice рисует углы 1:1 в px текстуры; без этого орнаменты
	# были бы вдвое крупнее, чем у панели статов).
	var sb := StyleBoxTexture.new()
	sb.texture = _hud_bg_half()
	sb.set_texture_margin_all(_ITEMS_BG_MARGIN)
	sb.set_content_margin_all(_ITEMS_BG_PAD)
	p.add_theme_stylebox_override("panel", sb)
	p.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.add_theme_constant_override("separation", 6)
	p.add_child(vb)
	var hdr := UIStyle.label(
		"SECTION_STARTING_ITEMS", 11, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER
	)
	hdr.name = "Header"
	vb.add_child(hdr)
	_items_row = HBoxContainer.new()
	_items_row.name = "Row"
	_items_row.add_theme_constant_override("separation", _ITEM_SEP)
	_items_row.alignment = BoxContainer.ALIGNMENT_BEGIN  # карты по левому краю
	_items_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Резервируем ширину под МАКС _ITEM_SLOTS карт — при меньшем числе панель НЕ
	# сжимается (карты центрируются), секции не скачут при смене сыщика.
	var card_w: float = _ITEM_CARD_H * GameCard.ASPECT
	_items_row.custom_minimum_size.x = (
		float(_ITEM_SLOTS) * card_w + float(_ITEM_SLOTS - 1) * float(_ITEM_SEP)
	)
	vb.add_child(_items_row)
	_render_items([])  # до первого update — надпись «нет предметов»
	return p


# Перестроить ряд карточек по списку предметов. Нет карт → надпись «нет предметов».
# Заодно собираем _item_deck (payload'ы) — по клику открываем веер с этими картами.
func _render_items(items: Array) -> void:
	if not is_instance_valid(_items_row):
		return
	for c in _items_row.get_children():
		c.queue_free()
	_item_deck.clear()
	# Каждый элемент — объект: {"asset": id} (карта-ассет), {"spell": id}
	# (карта-заклинание) или токен {"clue": N} и т.п. Токены — не карты.
	for i: int in range(items.size()):
		# Заклинание: payload из SpellCatalog (как в веере руки), не из AssetCatalog.
		var entry: Variant = items[i]
		if entry is Dictionary and (entry as Dictionary).has("spell"):
			var sid: String = String((entry as Dictionary)["spell"])
			var sp: Dictionary = SpellCatalog.by_id(sid)
			if sp.is_empty():
				continue
			var spayload: Dictionary = SpellCatalog.card_payload(sp)
			_item_deck.append(spayload)
			_items_row.add_child(_make_card_node(spayload, true))
			continue
		var aid: String = AssetCatalog.entry_id(items[i])
		if aid.is_empty():
			continue
		var a: Dictionary = AssetCatalog.by_id(aid)
		if a.is_empty():
			continue
		var payload: Dictionary = AssetCatalog.card_payload(a)
		_item_deck.append(payload)
		_items_row.add_child(_make_card_node(payload, true))  # кликабельна → веер
	if _item_deck.is_empty():  # нет карт-предметов → надпись по центру (высоту держим)
		var empty := UIStyle.label(
			"SECTION_NO_ITEMS", 12, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER
		)
		empty.name = "EmptyLabel"
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		empty.custom_minimum_size.y = _ITEM_CARD_H
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_items_row.add_child(empty)


# Миниатюра карты имущества: GameCard В ПОЛНЫЙ РАЗМЕР (_ITEM_FULL_H), уменьшенный
# через scale до высоты _ITEM_CARD_H — превью с теми же пропорциями шрифта/рамки,
# что у полной карты. Слот-обёртка занимает в раскладке место миниатюры. Пустой
# payload → пустая рамка. clickable=true → слот по клику открывает веер.
func _make_card_node(payload: Dictionary = {}, clickable: bool = false) -> Control:
	var full_w: float = _ITEM_FULL_H * GameCard.ASPECT
	var scale_f: float = _ITEM_CARD_H / _ITEM_FULL_H

	var slot := Control.new()
	slot.name = "ItemCardSlot"
	slot.custom_minimum_size = Vector2(full_w * scale_f, _ITEM_CARD_H)
	slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if clickable:
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		slot.gui_input.connect(_on_item_clicked)
	else:
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var card := GameCard.new()
	card.name = "ItemCard"
	card.custom_minimum_size = Vector2(full_w, _ITEM_FULL_H)
	card.size = Vector2(full_w, _ITEM_FULL_H)
	card.pivot_offset = Vector2.ZERO
	card.scale = Vector2(scale_f, scale_f)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(card)

	if payload.is_empty():
		card.set_card({"cost": "", "title": "", "subtitle": "", "desc": ""})
	else:
		card.set_card(payload)
	return slot


# Клик по карте имущества — открыть веер со ВСЕМИ картами сыщика для просмотра.
func _on_item_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_open_items_fan()


func _open_items_fan() -> void:
	if _item_deck.is_empty():
		return
	if not is_instance_valid(_fan):
		_fan = HandCarousel.new()
		_fan.name = "ItemsFan"
		_fan.tab_enabled = false  # в пикере Tab не трогаем; открыли кликом
		add_child(_fan)
	_fan.set_cards(_item_deck)
	_fan.open()
