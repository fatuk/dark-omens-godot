class_name GameCard
extends Control

## Единый компонент игровой карты на рамке asset/card-frame.png — для карт товаров
## (магазин) и карт руки (веер). Рисует рамку и раскладывает контент по её зонам
## (стоимость / арт / заголовок / описание). Когда зоны/рамка поменяются — правка
## в одном месте, и обе колоды обновятся.
##
## API: set_card({cost, title, subtitle?, desc, art? : Texture2D, art_color?, glyph?,
##                frame? : Texture2D})  — frame: полно-артовая рамка (карта Концентрации).

const FRAME_TEX: Texture2D = preload("res://assets/cards/asset/card-frame.png")

## Аспект рамки (ширина/высота). Карту задавать в этих пропорциях, иначе рамка
## растянется. 1768×2796.
const ASPECT: float = 1768.0 / 2796.0

## Радиус скругления углов арт-слоя (px). Арт лежит ПОД рамкой; в прозрачных
## скруглённых углах рамки торчали бы прямоугольные углы арта — режем по радиусу.
const ART_CORNER_RADIUS: float = 24.0

const _ROUND_CORNERS_SHADER := """
shader_type canvas_item;
uniform float radius_px = 24.0;
uniform vec2 rect_px = vec2(100.0, 100.0);
void fragment() {
	vec2 q = abs(UV * rect_px - rect_px * 0.5) - (rect_px * 0.5 - vec2(radius_px));
	float dist = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius_px;
	COLOR.a *= 1.0 - smoothstep(-1.0, 1.0, dist);
}
"""

# Зоны контента — доли рамки (x, y, w, h ∈ 0..1). Подобраны под asset/card-frame.png.
const Z_COST := Rect2(0.075, 0.050, 0.160, 0.100)  # центр ≈ (0.12, 0.085) — герб-компас
const Z_ART := Rect2(0.025, 0.025, 0.950, 0.515)  # арт ПОД рамкой, 95% ширины, упёрт вверх
const Z_TITLE := Rect2(0.110, 0.555, 0.780, 0.092)
const Z_DESC := Rect2(0.120, 0.695, 0.760, 0.235)
# Плашка карты-сообщения (chat): текст фразы по центру нижнего пергамента новой
# рамки cards/chat/card-frame.png. Своя зона — эмблема-облачко уже вшита в рамку.
const Z_MSG := Rect2(0.130, 0.640, 0.740, 0.270)

const C_COST_TXT := UIColors.ACCENT  # янтарь — как заголовок
const C_TITLE_TXT := UIColors.ACCENT  # янтарь на синей плашке
const C_SUB_TXT := Color(0.62, 0.72, 0.82)  # приглушённый голубой — трейт
const C_DESC_TXT := Color(0, 0, 0)  # чёрный — на пергаменте
const C_MSG_TXT := Color(0.12, 0.09, 0.06)  # тёмная тушь — фраза на пергаменте карты-сообщения
const C_ART_FILL := Color(0.10, 0.08, 0.14)  # заглушка арт-слота (закрывает белый бокс)
const C_GLYPH := Color(0.55, 0.48, 0.35)

# Скролл описания курсором (когда текст не влезает в зону пергамента): позиция
# курсора по вертикали (клампится к высоте блока) задаёт направление и скорость —
# выше центра скроллит вверх, ниже вниз, по центру стоит; линейно к краям.
const _DESC_SCROLL_MAX_SPEED := 75.0  # px/сек на краях (вдвое медленнее прежнего)
const _DESC_SCROLL_DEADZONE := 0.04  # доля высоты от центра, где скролл стоит
const _DESC_LABEL_H := 2000.0  # заведомо большая высота лейбла (любое описание влезет)
const _DESC_BOTTOM_PAD := 4.0  # нижний запас, чтобы последняя строка не подрезалась

var _cost: Label
var _title: Label
var _sub: Label
var _desc: Label
var _desc_offset: float = 0.0  # текущий сдвиг описания вверх (px), 0..overflow
var _art: TextureRect
var _art_fill: ColorRect
var _glyph: Label
var _frame: TextureRect
var _message: Label  # карта-сообщение (chat): одна центрированная фраза в плашке


func _init() -> void:
	_build()


func _build() -> void:
	# Арт — ПОД рамкой: виден сквозь прозрачное окно рамки (мягкие края окна
	# растушёвывают его). Слот шире окна, COVER заполняет ширину.
	var art_zone := _zone("Art", Z_ART)
	_art_fill = ColorRect.new()
	_art_fill.name = "ArtFill"
	_art_fill.color = C_ART_FILL
	_art_fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art_zone.add_child(_art_fill)
	_art = TextureRect.new()
	_art.name = "Art"
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_art.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art.visible = false
	art_zone.add_child(_art)
	_glyph = _centered_label("Glyph", 40, C_GLYPH)
	art_zone.add_child(_glyph)

	# Скругляем углы арт-слоя по радиусу (один материал на заливку и текстуру);
	# rect_px обновляем по фактическому размеру зоны.
	var round_mat := ShaderMaterial.new()
	var round_sh := Shader.new()
	round_sh.code = _ROUND_CORNERS_SHADER
	round_mat.shader = round_sh
	round_mat.set_shader_parameter("radius_px", ART_CORNER_RADIUS)
	_art_fill.material = round_mat
	_art.material = round_mat
	art_zone.resized.connect(
		func() -> void: round_mat.set_shader_parameter("rect_px", art_zone.size)
	)

	# Рамка — ПОВЕРХ арта: бронзовый кант и плашки рисуются над артом, прозрачное
	# окно открывает арт.
	_frame = TextureRect.new()
	_frame.name = "Frame"
	_frame.texture = FRAME_TEX
	_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_frame.stretch_mode = TextureRect.STRETCH_SCALE
	_frame.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_frame)

	# Стоимость — в гербе сверху-слева.
	var cost_zone := _zone("Cost", Z_COST)
	_cost = _centered_label("CostLabel", 20, C_COST_TXT)
	cost_zone.add_child(_cost)

	# Заголовок + трейт — на синей плашке.
	var title_zone := _zone("Title", Z_TITLE)
	var tvb := VBoxContainer.new()
	tvb.name = "TitleVB"
	tvb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tvb.alignment = BoxContainer.ALIGNMENT_CENTER
	tvb.add_theme_constant_override("separation", 0)
	tvb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_zone.add_child(tvb)
	_title = _centered_label("Name", 14, C_TITLE_TXT)
	_title.clip_text = true
	tvb.add_child(_title)
	_sub = _centered_label("Subtitle", 9, C_SUB_TXT)
	_sub.clip_text = true
	tvb.add_child(_sub)

	# Описание — на пергаменте. Чёрный текст; не влезает → desc_zone клипует, а сам
	# текст (заведомо высокий Label) сдвигается курсором при наведении (_process).
	# Зона/лейбл — IGNORE, чтобы наведение ловила сама карта (self).
	var desc_zone := _zone("Desc", Z_DESC)
	desc_zone.clip_contents = true
	_desc = Label.new()
	_desc.name = "DescLabel"
	_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desc.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.add_theme_font_size_override("font_size", 12)
	_desc.add_theme_color_override("font_color", C_DESC_TXT)
	_desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Ширина = зоне (anchor 0..1), верх у зоны; высота заведомо большая — текст
	# рисуется с верха, лишнее клипует desc_zone. Скролл двигает offset_top/bottom.
	_desc.anchor_left = 0.0
	_desc.anchor_right = 1.0
	_desc.anchor_top = 0.0
	_desc.anchor_bottom = 0.0
	_desc.offset_left = 0.0
	_desc.offset_right = 0.0
	_desc.offset_top = 0.0
	_desc.offset_bottom = _DESC_LABEL_H
	desc_zone.add_child(_desc)

	# Карта-сообщение (chat): одна крупная центрированная фраза в плашке новой рамки.
	# Своей арт-зоны/заголовка нет — эмблема вшита в рамку, текст ложится в Z_MSG.
	var msg_zone := _zone("Msg", Z_MSG)
	_message = Label.new()
	_message.name = "MessageLabel"
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_message.add_theme_font_size_override("font_size", 15)
	_message.add_theme_color_override("font_color", C_MSG_TXT)
	_message.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_message.visible = false
	msg_zone.add_child(_message)

	mouse_entered.connect(_on_desc_hover_start)
	mouse_exited.connect(_on_desc_hover_end)
	set_process(false)  # покадровый скролл включается только под курсором


## Заполнить карту. Поля: cost, title, subtitle?, desc, art? (Texture2D),
## art_color? (Color заглушки), glyph? (символ-заглушка).
func set_card(d: Dictionary) -> void:
	# Карта-сообщение (chat): единственный текст — фраза по центру плашки; служебные
	# зоны (цена/заголовок/трейт/описание) прячем, всё остальное рисует рамка.
	var is_msg: bool = d.has("message")
	_message.visible = is_msg
	_message.text = String(d.get("message", ""))

	# Стоимость — герб-компас; для жетонов/карт без цены поле не задаём → герб скрыт.
	_cost.visible = (not is_msg) and d.has("cost")
	if _cost.visible:
		_cost.text = str(d["cost"])
	_title.text = String(d.get("title", ""))
	_title.visible = not is_msg
	_sub.text = String(d.get("subtitle", ""))
	_sub.visible = (not is_msg) and not _sub.text.is_empty()
	_desc.text = String(d.get("desc", ""))
	_desc.visible = not is_msg
	_on_desc_hover_end()  # новый текст — гасим скролл и возвращаем к началу

	# Кастомная рамка (frame): ПОЛНО-артовая карта (арт+рамка+пергамент единым
	# изображением, напр. карта Концентрации). Тогда своя арт-зона/глиф не нужны —
	# всё рисует рамка; текст ложится в зоны Title/Desc (совпадают по разметке).
	var frame_tex: Texture2D = d.get("frame", null)
	_frame.texture = frame_tex if frame_tex != null else FRAME_TEX

	var tex: Texture2D = d.get("art", null)
	if frame_tex != null:
		_art.visible = false
		_glyph.visible = false
		_art_fill.color = Color(0, 0, 0, 0)  # прозрачно — полно-артовая рамка сама всё рисует
	elif tex != null:
		_art.texture = tex
		_art.visible = true
		_glyph.visible = false
	else:
		_art.visible = false
		_art_fill.color = d.get("art_color", C_ART_FILL)
		_glyph.text = String(d.get("glyph", ""))
		_glyph.visible = not _glyph.text.is_empty()


# ── скролл описания курсором ───────────────────────────────────────────────────


# Наведение на карту — включаем покадровый скролл (если есть переполнение, оно
# проверяется в _process). Уход курсора / новый текст — выключаем и в начало.
func _on_desc_hover_start() -> void:
	set_process(true)


func _on_desc_hover_end() -> void:
	set_process(false)
	_desc_offset = 0.0
	_apply_desc_offset()


# Двигаем высокий лейбл вверх на _desc_offset px (desc_zone клипует низ/верх).
func _apply_desc_offset() -> void:
	if not is_instance_valid(_desc):
		return
	_desc.offset_top = -_desc_offset
	_desc.offset_bottom = _DESC_LABEL_H - _desc_offset


# Позиция курсора по вертикали в зоне (клампится к её высоте): t=0 (верх) → вверх,
# t=0.5 (центр) → стоп, t=1 (низ) → вниз. Скорость линейна по отклонению от центра.
# Высоту текста берём по числу перенесённых строк (ScrollContainer её не считал).
func _process(delta: float) -> void:
	if not is_instance_valid(_desc):
		return
	var zone: Control = _desc.get_parent()
	var zh: float = zone.size.y
	if zh <= 0.0:
		return
	# Высота текста: строки × (высота строки + межстрочный интервал) + нижний запас.
	# get_line_height() НЕ включает line_spacing — без него низ подрезался.
	var lines: int = _desc.get_line_count()
	var line_h: float = float(_desc.get_line_height())
	var spacing: float = float(_desc.get_theme_constant("line_spacing"))
	var content_h: float = float(lines) * (line_h + spacing) + _DESC_BOTTOM_PAD
	var overflow: float = content_h - zh
	if overflow <= 0.0:
		if _desc_offset != 0.0:
			_desc_offset = 0.0
			_apply_desc_offset()
		return  # текст влезает — скроллить нечего
	var t: float = clampf(zone.get_local_mouse_position().y / zh, 0.0, 1.0)
	var dir: float = (t - 0.5) * 2.0  # [-1..1]: <0 вверх, >0 вниз; линейно к краям
	if absf(dir) < _DESC_SCROLL_DEADZONE:
		return  # около центра — стоп
	_desc_offset = clampf(_desc_offset + dir * _DESC_SCROLL_MAX_SPEED * delta, 0.0, overflow)
	_apply_desc_offset()


# ── helpers ───────────────────────────────────────────────────────────────────


# Control, заякоренный на дробную зону рамки (доли 0..1).
func _zone(zname: String, r: Rect2) -> Control:
	var c := Control.new()
	c.name = zname
	c.anchor_left = r.position.x
	c.anchor_top = r.position.y
	c.anchor_right = r.position.x + r.size.x
	c.anchor_bottom = r.position.y + r.size.y
	c.offset_left = 0.0
	c.offset_top = 0.0
	c.offset_right = 0.0
	c.offset_bottom = 0.0
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(c)
	return c


func _centered_label(lname: String, font_px: int, color: Color) -> Label:
	var l := Label.new()
	l.name = lname
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	l.add_theme_font_size_override("font_size", font_px)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
