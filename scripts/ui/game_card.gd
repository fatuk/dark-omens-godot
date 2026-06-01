class_name GameCard
extends Control

## Единый компонент игровой карты на рамке asset-card.png — для карт товаров
## (магазин) и карт руки (веер). Рисует рамку и раскладывает контент по её зонам
## (стоимость / арт / заголовок / описание). Когда зоны/рамка поменяются — правка
## в одном месте, и обе колоды обновятся.
##
## API: set_card({cost, title, subtitle?, desc, art? : Texture2D, art_color?, glyph?})

const FRAME_TEX: Texture2D = preload("res://assets/asset-card/asset-card.png")

## Аспект рамки (ширина/высота). Карту задавать в этих пропорциях, иначе рамка
## растянется. 1768×2796.
const ASPECT: float = 1768.0 / 2796.0

# Зоны контента — доли рамки (x, y, w, h ∈ 0..1). Подобраны под asset-card.png.
const Z_COST := Rect2(0.040, 0.035, 0.160, 0.100)  # центр ≈ (0.12, 0.085) — герб-компас
const Z_ART := Rect2(0.284, 0.138, 0.464, 0.259)
const Z_TITLE := Rect2(0.110, 0.555, 0.780, 0.092)
const Z_DESC := Rect2(0.120, 0.695, 0.760, 0.235)

const C_COST_TXT := UIColors.ACCENT  # янтарь — как заголовок
const C_TITLE_TXT := UIColors.ACCENT  # янтарь на синей плашке
const C_SUB_TXT := Color(0.62, 0.72, 0.82)  # приглушённый голубой — трейт
const C_DESC_TXT := Color(0.18, 0.14, 0.09)  # тёмный — на пергаменте
const C_ART_FILL := Color(0.10, 0.08, 0.14)  # заглушка арт-слота (закрывает белый бокс)
const C_GLYPH := Color(0.55, 0.48, 0.35)

var _cost: Label
var _title: Label
var _sub: Label
var _desc: Label
var _art: TextureRect
var _art_fill: ColorRect
var _glyph: Label


func _init() -> void:
	_build()


func _build() -> void:
	# Рамка — на всю карту.
	var frame := TextureRect.new()
	frame.name = "Frame"
	frame.texture = FRAME_TEX
	frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	frame.stretch_mode = TextureRect.STRETCH_SCALE
	frame.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)

	# Арт-слот: заглушка-заливка (закрывает белый бокс рамки) + опц. текстура + глиф.
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

	# Описание — на пергаменте.
	var desc_zone := _zone("Desc", Z_DESC)
	_desc = _centered_label("DescLabel", 12, C_DESC_TXT)
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	desc_zone.add_child(_desc)


## Заполнить карту. Поля: cost, title, subtitle?, desc, art? (Texture2D),
## art_color? (Color заглушки), glyph? (символ-заглушка).
func set_card(d: Dictionary) -> void:
	_cost.text = str(d.get("cost", 0))
	_title.text = String(d.get("title", ""))
	_sub.text = String(d.get("subtitle", ""))
	_sub.visible = not _sub.text.is_empty()
	_desc.text = String(d.get("desc", ""))

	var tex: Texture2D = d.get("art", null)
	if tex != null:
		_art.texture = tex
		_art.visible = true
		_glyph.visible = false
	else:
		_art.visible = false
		_art_fill.color = d.get("art_color", C_ART_FILL)
		_glyph.text = String(d.get("glyph", ""))
		_glyph.visible = not _glyph.text.is_empty()


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
