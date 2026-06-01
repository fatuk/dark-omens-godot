class_name InfoBar
extends HBoxContainer

## Информационная панель внизу picker'а: HP/санити, атрибуты, стартовые предметы.
##
## Публичное API:
##   update(inv: Dictionary) — обновить значения из словаря сыщика.

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
const _TICKET_SCALE: float = 0.34
# Наклон второго билета (градусы, по часовой). Он лежит поверх первого —
# лёгкий поворот даёт ощущение небрежно брошенной стопки.
const _TICKET_TILT_DEG: float = 7.0
# Ширина жёлоба баров HP/санити (display-px). Бар фиксированной ширины —
# увеличь/уменьши это число, чтобы растянуть или сжать оба бара.
const _HUD_BAR_WIDTH: float = 180.0
# Тень билета: размытый силуэт-копия, сдвинутая влево-вниз, под билетом.
const _TICKET_SHADOW_OFFSET := Vector2(-6.0, 6.0)
const _TICKET_SHADOW_ALPHA: float = 0.55
const _TICKET_SHADOW_BLUR: float = 6.0  # радиус размытия (в TEXTURE_PIXEL_SIZE)

# Шейдер тени: 5×5 box-blur alpha-маски текстуры → мягкий чёрный силуэт.
const _SHADOW_BLUR_SHADER := """
shader_type canvas_item;
uniform float blur : hint_range(0.0, 32.0) = 6.0;
uniform float shadow_alpha : hint_range(0.0, 1.0) = 0.55;
void fragment() {
	vec2 stp = TEXTURE_PIXEL_SIZE * blur;
	float a = 0.0;
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			a += texture(TEXTURE, UV + vec2(float(x), float(y)) * stp).a;
		}
	}
	COLOR = vec4(0.0, 0.0, 0.0, (a / 25.0) * shadow_alpha);
}
"""
const _HUD_PANEL_BG: Texture2D = preload("res://assets/player-hud/player-hud-bg.png")
const _HUD_ROW_BG: Texture2D = preload("res://assets/player-hud/hud-item-bg.png")
const _HUD_BAR_BG: Texture2D = preload("res://assets/player-hud/bar-bg.png")
const _HEALTH_ICON: Texture2D = preload("res://assets/player-hud/health-icon.png")
const _HEALTH_BAR: Texture2D = preload("res://assets/player-hud/health-bar.png")
const _SANITY_ICON: Texture2D = preload("res://assets/player-hud/sanity-icon.png")
const _SANITY_BAR: Texture2D = preload("res://assets/player-hud/sanity-ba.png")
const _TRAIN_TICKET: Texture2D = preload("res://assets/player-hud/train-ticket.png")
const _OCEAN_TICKET: Texture2D = preload("res://assets/player-hud/ocean-ticket.png")

# Иконки-медальоны токенов (выводятся в ряду ресурсов рядом с билетами).
const _CLUE_ICON: Texture2D = preload("res://assets/map/clue-icon.png")
const _RESOURCE_ICON: Texture2D = preload("res://assets/map/resource-icon.png")
const _TOKEN_ICON_H: float = 52.0  # высота медальона токена (px)

# Ассеты панели атрибутов. Все @2× — выводим в half-size.
const _ATTR_PANEL_TEX: Texture2D = preload("res://assets/virtues-panel/virues-panel.png")
const _DICE_TEX: Texture2D = preload("res://assets/virtues-panel/cube.png")
const _DIVIDER_TEX: Texture2D = preload("res://assets/virtues-panel/divider.png")
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

# Цвет крупных цифр атрибутов — тёплое золото под бронзовые иконки.
const _ATTR_VALUE_COLOR := Color("c39b6a")

# Эффект «дешифровки» при смене сыщика: цифра атрибута сначала пробегает
# несколько случайных ктулху-рун (шрифт CTHUR), затем проявляется число.
const _RUNE_FONT: Font = preload("res://assets/fonts/CTHUR___.TTF")
const _SCRAMBLE_STEPS: int = 8  # сколько кадров мелькнёт
const _SCRAMBLE_STEP_TIME: float = 0.08  # длительность одного кадра
# Сколько рун мелькает в одном кадре. У атрибута значение — одна цифра, хватает
# одной руны; у баров HP/санити значение длиннее («NN / NN») — используем 3.
const _BAR_SCRAMBLE_RUNES: int = 2

# ВРЕМЕННО / тест: модификаторы атрибутов до появления upgrade-системы.
# Атрибут с бонусом > 0 показывает строку «+N 🎲». Удалить, когда бонусы
# начнут приходить из реальных данных.
const _TEST_BONUSES := {"will": 2}

var _hp_label: Label
var _sanity_label: Label
var _attr_value_lbls: Dictionary = {}  # field name -> Label
var _ticket_shadow_mat: ShaderMaterial  # общий blur-материал теней билетов
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

# Трейт ассета → ключ перевода для подзаголовка карточки (как в магазине).
const _TRAIT_KEY := {
	"weapon": "TRAIT_WEAPON",
	"magical": "TRAIT_MAGICAL",
	"relic": "TRAIT_RELIC",
	"tome": "TRAIT_TOME",
	"teamwork": "TRAIT_TEAMWORK",
	"item": "TRAIT_ITEM",
	"trinket": "TRAIT_TRINKET",
	"task": "TRAIT_TASK",
	"service": "TRAIT_SERVICE",
	"ally": "TRAIT_ALLY",
}


func _ready() -> void:
	_ticket_shadow_mat = _build_ticket_shadow_material()
	add_theme_constant_override("separation", 16)
	# По центру, по ширине контента — панель НЕ растягивается на весь экран
	# (по бокам остаётся пусто).
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(_build_stats_panel())
	add_child(_build_attributes_panel())
	add_child(_build_items_panel())


func _build_ticket_shadow_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = _SHADOW_BLUR_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("blur", _TICKET_SHADOW_BLUR)
	mat.set_shader_parameter("shadow_alpha", _TICKET_SHADOW_ALPHA)
	return mat


# ── Public API ────────────────────────────────────────────────────────────────


func update(inv: Dictionary) -> void:
	var hp_max: int = int(inv.get("health", 0))
	var san_max: int = int(inv.get("sanity", 0))
	# В picker'е бар всегда полный (показываем max/max) — числа в значении.
	# Перед новыми числами на месте значения пробегают ктулху-руны (как у
	# атрибутов) — эффект «дешифровки» при смене сыщика. Значение длиннее
	# цифры атрибута — мелькаем по _BAR_SCRAMBLE_RUNES руны.
	_scramble_to(_hp_label, "%d / %d" % [hp_max, hp_max], _BAR_SCRAMBLE_RUNES)
	_scramble_to(_sanity_label, "%d / %d" % [san_max, san_max], _BAR_SCRAMBLE_RUNES)
	var sk: Dictionary = inv.get("skills", {})
	for field: String in _attr_value_lbls.keys():
		_scramble_to(_attr_value_lbls[field], str(int(sk.get(field, 0))))
	_render_items(inv.get("startingItems", []))
	_render_resources(inv)


# Анимация «дешифровки»: на месте числа пробегает _SCRAMBLE_STEPS кадров по
# rune_count случайных рун, затем выставляется final_text обычным шрифтом.
# Прерываема — повторный вызов (быстрое перелистывание) убивает старый tween
# и стартует новый.
func _scramble_to(lbl: Label, final_text: String, rune_count: int = 1) -> void:
	if lbl.has_meta("__scramble_tw"):
		var prev = lbl.get_meta("__scramble_tw")
		if prev and (prev as Tween).is_valid():
			(prev as Tween).kill()

	var tw := create_tween()
	for i in range(_SCRAMBLE_STEPS):
		tw.tween_callback(
			func() -> void:
				lbl.add_theme_font_override("font", _RUNE_FONT)
				lbl.text = _random_runes(rune_count)
		)
		tw.tween_interval(_SCRAMBLE_STEP_TIME)
	# Финал: возвращаем обычный шрифт темы и настоящую цифру.
	tw.tween_callback(
		func() -> void:
			lbl.remove_theme_font_override("font")
			lbl.text = final_text
	)
	lbl.set_meta("__scramble_tw", tw)


# Строка из count случайных строчных букв a–z → в шрифте CTHUR это глифы рун.
# (Глифы рун там только на строчных; заглавные A–Z в шрифте отсутствуют.)
func _random_runes(count: int) -> String:
	var s := ""
	for i in range(count):
		s += char(randi_range(97, 122))
	return s


# ── Stats ─────────────────────────────────────────────────────────────────────


# Левая панель: декоративный фон player-hud-bg + поверх 2 строки статов
# (HP/санити) на ассетах player-hud + ряд билетов снизу. Панель фиксированного
# размера (= фон @_HUD_SCALE) — у фона запечены угловые орнаменты.
func _build_stats_panel() -> Control:
	var panel := Control.new()
	panel.name = "StatsPanel"
	panel.custom_minimum_size = _HUD_PANEL_BG.get_size() * _HUD_SCALE

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
	bar_row.add_child(_make_hud_bar(fill_tex))

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


# Бар: жёлоб bar-bg + статичная заливка fill_tex поверх (всегда полная).
func _make_hud_bar(fill_tex: Texture2D) -> Control:
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

	# Заливка инсетится внутрь рамки жёлоба — тянется по всей ширине.
	var inset_x: float = (_HUD_BAR_BG.get_size().x - fill_tex.get_size().x) * 0.5 * _HUD_SCALE
	var inset_y: float = (_HUD_BAR_BG.get_size().y - fill_tex.get_size().y) * 0.5 * _HUD_SCALE
	var fill := TextureRect.new()
	fill.name = "Fill"
	fill.texture = fill_tex
	fill.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	fill.stretch_mode = TextureRect.STRETCH_SCALE
	fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fill.offset_left = inset_x
	fill.offset_right = -inset_x
	fill.offset_top = inset_y
	fill.offset_bottom = -inset_y
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(fill)
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
	_tickets_row.custom_minimum_size.y = _TRAIN_TICKET.get_size().y * _TICKET_SCALE
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
		_tickets_row.add_child(_make_tickets_group(train, ship))
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


# Под-группа билетов (поездные + морские) с нахлёстом (отриц. separation внутри).
# PNG чуть разного размера (train 161×146, ocean 152×143) — нормализуем по высоте.
func _make_tickets_group(train_n: int, ship_n: int) -> Control:
	var hb := HBoxContainer.new()
	hb.name = "Tickets"
	hb.add_theme_constant_override("separation", -20)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var ticket_h: float = _TRAIN_TICKET.get_size().y * _TICKET_SCALE
	var idx: int = 0
	for i: int in range(maxi(0, train_n)):
		hb.add_child(_make_ticket(_TRAIN_TICKET, "TrainTicket%d" % i, ticket_h, _ticket_tilt(idx)))
		idx += 1
	for i: int in range(maxi(0, ship_n)):
		hb.add_child(_make_ticket(_OCEAN_TICKET, "OceanTicket%d" % i, ticket_h, _ticket_tilt(idx)))
		idx += 1
	return hb


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


# Наклон для эффекта брошенной стопки: первый билет ровно, дальше — вразнобой.
func _ticket_tilt(idx: int) -> float:
	if idx == 0:
		return 0.0
	return _TICKET_TILT_DEG * (1.0 if idx % 2 == 1 else -1.0)


func _make_ticket(
	tex: Texture2D, node_name: String, ticket_height: float, tilt_deg: float = 0.0
) -> Control:
	# Размер: фиксированная высота, ширина — по аспекту текстуры.
	var tex_size: Vector2 = tex.get_size()
	var ticket_size := Vector2(ticket_height * tex_size.x / tex_size.y, ticket_height)

	# holder — прямой ребёнок HBox. Контейнер принудительно сбрасывает
	# rotation/scale своих детей (fit_child_in_rect), поэтому наклоняем НЕ его,
	# а вложенный Tilt — он контейнеру не подчиняется.
	var holder := Control.new()
	holder.name = node_name
	holder.custom_minimum_size = ticket_size
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Поворот вокруг центра билета — иначе он уехал бы из своей ячейки.
	var tilt := Control.new()
	tilt.name = "Tilt"
	tilt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tilt.pivot_offset = ticket_size * 0.5
	tilt.rotation_degrees = tilt_deg
	tilt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(tilt)

	# Тень — силуэт-копия билета: blur-шейдер размывает alpha-маску текстуры
	# и красит в чёрный. Сдвинута влево-вниз, нарисована ПОД билетом —
	# у перекрывающихся билетов верхний отбрасывает тень на нижний.
	var shadow := TextureRect.new()
	shadow.name = "Shadow"
	shadow.texture = tex
	shadow.material = _ticket_shadow_mat
	shadow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shadow.stretch_mode = TextureRect.STRETCH_SCALE
	shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shadow.offset_left = _TICKET_SHADOW_OFFSET.x
	shadow.offset_right = _TICKET_SHADOW_OFFSET.x
	shadow.offset_top = _TICKET_SHADOW_OFFSET.y
	shadow.offset_bottom = _TICKET_SHADOW_OFFSET.y
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tilt.add_child(shadow)

	var ticket := TextureRect.new()
	ticket.name = "Ticket"
	ticket.texture = tex
	ticket.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ticket.stretch_mode = TextureRect.STRETCH_SCALE
	ticket.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ticket.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tilt.add_child(ticket)
	return holder


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
	cols.offset_top = _COLS_MARGIN_TOP
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
	icon.name = "Icon"
	icon.texture = _ATTR_ICONS[field]
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = (_ATTR_ICONS[field] as Texture2D).get_size() * _ICON_SCALE
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(icon)

	var val := UIStyle.label("—", 26, _ATTR_VALUE_COLOR, HORIZONTAL_ALIGNMENT_CENTER)
	val.name = "Value"
	# Фиксированная высота + вертикальный центр — руны при scramble'е другой
	# метрики, чем цифры; без этого само число дёргалось бы по высоте.
	val.custom_minimum_size.y = 36
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	col.add_child(val)
	_attr_value_lbls[field] = val

	# DiceSection сама EXPAND'ится (забирает свободное место колонки) — отдельная
	# распорка не нужна. Внутри неё дивайдер центрирован спейсерами.
	col.add_child(_make_dice_section(field))

	# 4px отступ под dice-секцией от нижнего края колонки.
	var bottom_pad := Control.new()
	bottom_pad.name = "BottomMargin"
	bottom_pad.custom_minimum_size.y = 4
	col.add_child(bottom_pad)
	return col


# Секция модификатора: разделитель divider.png + строка «+N 🎲». N — будущая
# прокачка статов. Вся секция видна только для атрибутов с бонусом > 0
# (источник — _TEST_BONUSES, временно; позже — данные upgrade-системы,
# обновлять в update()).
#
# Секция EXPAND'ится на свободную высоту колонки; внутри — два равных
# expanding-спейсера вокруг дивайдера, поэтому он оказывается ровно посередине
# между числом (сверху) и строкой кубика (снизу). diceRow прижата к низу.
func _make_dice_section(field: String) -> Control:
	var bonus: int = int(_TEST_BONUSES.get(field, 0))

	var section := VBoxContainer.new()
	section.name = "DiceSection"
	section.add_theme_constant_override("separation", 0)
	section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	section.visible = bonus > 0

	var sp_top := Control.new()
	sp_top.name = "SpacerTop"
	sp_top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	section.add_child(sp_top)

	var divider := TextureRect.new()
	divider.name = "Divider"
	divider.texture = _DIVIDER_TEX
	divider.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	divider.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	divider.custom_minimum_size = _DIVIDER_TEX.get_size() * _ASSET_SCALE
	divider.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	section.add_child(divider)

	var sp_bot := Control.new()
	sp_bot.name = "SpacerBottom"
	sp_bot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	section.add_child(sp_bot)

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
	dice.name = "Dice"
	dice.texture = _DICE_TEX
	dice.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dice.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Кубик мельче остальных ассетов панели — _ASSET_SCALE * 0.5.
	dice.custom_minimum_size = _DICE_TEX.get_size() * _ASSET_SCALE * 0.5
	row.add_child(dice)
	return section


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
	_render_items([])  # до первого update — пустые рамки
	return p


# Перестроить ряд карточек по списку id ассетов. Пусто → _ITEM_SLOTS пустых рамок.
# Заодно собираем _item_deck (payload'ы) — по клику открываем веер с этими картами.
func _render_items(items: Array) -> void:
	if not is_instance_valid(_items_row):
		return
	for c in _items_row.get_children():
		c.queue_free()
	_item_deck.clear()
	# Каждый элемент — объект: {"asset": id} (карта) или токен {"clue": N} и т.п.
	# Карточки рисуем только для ассетов; токены (clue/resource/focus) — не карты.
	for i: int in range(items.size()):
		var aid: String = _entry_asset_id(items[i])
		if aid.is_empty():
			continue
		var a: Dictionary = AssetCatalog.by_id(aid)
		if a.is_empty():
			continue
		var payload: Dictionary = _asset_payload(a)
		_item_deck.append(payload)
		_items_row.add_child(_make_card_node(payload, true))  # кликабельна → веер
	if _item_deck.is_empty():  # нет карт-ассетов → пустые рамки-плейсхолдеры
		for i: int in range(_ITEM_SLOTS):
			_items_row.add_child(_make_card_node())


# id ассета из элемента startingItems: {"asset": id} → id; токен/иное → "".
# Строку тоже принимаем (на случай старого формата).
func _entry_asset_id(entry: Variant) -> String:
	if entry is String:
		return String(entry)
	if entry is Dictionary and (entry as Dictionary).has("asset"):
		return String((entry as Dictionary)["asset"])
	return ""


# Payload карты ассета для GameCard.set_card (название/трейт/способность/стоимость).
func _asset_payload(a: Dictionary) -> Dictionary:
	var traits: Array = a.get("traits", [])
	var trait_id: String = String(traits[-1]) if not traits.is_empty() else "item"
	return {
		"cost": int(a.get("cost", 0)),
		"title": a.get("nameKey", ""),
		"subtitle": _TRAIT_KEY.get(trait_id, trait_id.to_upper()),
		"desc": a.get("abilityKey", ""),
	}


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
		_fan.set_hint("Esc / клик по фону — закрыть   ·   ← →  /  колесо — листать")
	_fan.set_cards(_item_deck)
	_fan.open()
