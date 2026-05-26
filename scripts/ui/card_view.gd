class_name CardView
extends Control

## Карточка сыщика — слоистый UI, который picker рендерит в SubViewport
## и натягивает как текстуру на 3D-quad.
##
## Иерархия слоёв (снизу вверх):
##   1. портрет (TextureRect, COVER-stretch)
##   2. card-overlay (TextureRect + blend = multiply)
##   3. card-frame (TextureRect)
##   4. card-badge с именем + занятием (TextureRect + VBoxContainer)
##   5. цитата (Label, word-wrap)
##   6. taken-оверлей (ColorRect + Label, скрыт по умолчанию)
##
## Публичное API:
##   set_data(inv: Dictionary) — обновить портрет/имя/занятие/цитату
##   set_taken(taken: bool)    — показать/скрыть оверлей «занято»

const _OVERLAY_TEX: Texture2D = preload("res://assets/card-frame/card-overlay.png")
const _FRAME_TEX:   Texture2D = preload("res://assets/card-frame/card-frame.png")
const _BADGE_TEX:   Texture2D = preload("res://assets/card-frame/card-badge.png")

# Геометрия бейджа — подобрана под текущий card-badge.png. При смене ассета
# проверить, что текст и завитки не вылезают.
const _BADGE_TEX_SCALE: float = 0.25   # @4× ассет → отображаем в 1×
const _BADGE_BOTTOM_GAP: float = 70.0   # отступ от нижнего края, освобождает место под цитату
const _BADGE_TEXT_OFFSET_TOP:    int = 9
const _BADGE_TEXT_OFFSET_BOTTOM: int = -17
const _BADGE_TEXT_OFFSET_X:      int = 40

# Полоса цитаты под бейджем.
const _QUOTE_OFFSET_TOP:    int = -63
const _QUOTE_OFFSET_BOTTOM: int = -13
const _QUOTE_OFFSET_X:      int = 40
# Цитата — тем же цветом, что и имя сыщика (верхний текст).
const _QUOTE_COLOR := UIColors.TEXT
var _placeholder_tex: ImageTexture

var _portrait: TextureRect
var _name_lbl: Label
var _occ_lbl:  Label
var _quote_lbl: Label
var _taken_ov: Control


func _init(placeholder_tex: ImageTexture) -> void:
	_placeholder_tex = placeholder_tex


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


# ── Public API ────────────────────────────────────────────────────────────────

func set_data(inv: Dictionary) -> void:
	var inv_name: String = inv.get("name", "")
	_portrait.texture = _load_portrait(inv_name)
	_name_lbl.text = inv.get("displayName", inv_name)
	_occ_lbl.text  = inv.get("occupation", "")
	var quote_key: String = inv.get("quote", "")
	# Цитата — translation key; tr() явно, т.к. иначе rebuild при locale_changed
	# не догонит уже выставленный текст без перевода (Godot переводит автоматом
	# только если text имеет вид key, но тут возможна пустая строка).
	_quote_lbl.text = tr(quote_key) if not quote_key.is_empty() else ""


func set_taken(taken: bool) -> void:
	_taken_ov.visible = taken


# ── Build ─────────────────────────────────────────────────────────────────────

func _build() -> void:
	# Слой 1: портрет.
	_portrait = TextureRect.new()
	_portrait.name          = "Portrait"
	_portrait.texture       = _placeholder_tex
	_portrait.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode  = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_portrait.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	add_child(_portrait)

	# Слой 2: card-overlay, blend=multiply — тонирует портрет.
	var overlay := _make_full_rect_texture(_OVERLAY_TEX, _make_multiply_material())
	overlay.name = "Overlay"
	add_child(overlay)

	# Слой 3: декоративная рамка.
	var frame := _make_full_rect_texture(_FRAME_TEX, null)
	frame.name = "Frame"
	add_child(frame)

	# Слой 4: бейдж + имя + занятие.
	add_child(_build_badge())

	# Слой 4.5: цитата под бейджем.
	_quote_lbl = _build_quote_label()
	add_child(_quote_lbl)

	# Слой 5: оверлей «занято».
	_taken_ov = _build_taken_overlay()
	_taken_ov.visible = false
	add_child(_taken_ov)


func _build_badge() -> Control:
	var badge_size: Vector2 = _BADGE_TEX.get_size() * _BADGE_TEX_SCALE

	var box := Control.new()
	box.name = "Badge"
	box.anchor_left   = 0.5
	box.anchor_right  = 0.5
	box.anchor_top    = 1.0
	box.anchor_bottom = 1.0
	box.offset_left   = -badge_size.x * 0.5
	box.offset_right  =  badge_size.x * 0.5
	box.offset_top    = -badge_size.y - _BADGE_BOTTOM_GAP
	box.offset_bottom = -_BADGE_BOTTOM_GAP
	box.mouse_filter  = Control.MOUSE_FILTER_IGNORE

	var bg := _make_full_rect_texture(_BADGE_TEX, null)
	bg.name = "BadgeBg"
	box.add_child(bg)

	var name_vb := VBoxContainer.new()
	name_vb.name = "Text"
	name_vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	name_vb.offset_left   =  _BADGE_TEXT_OFFSET_X
	name_vb.offset_right  = -_BADGE_TEXT_OFFSET_X
	name_vb.offset_top    =  _BADGE_TEXT_OFFSET_TOP
	name_vb.offset_bottom =  _BADGE_TEXT_OFFSET_BOTTOM
	name_vb.alignment = BoxContainer.ALIGNMENT_CENTER
	name_vb.add_theme_constant_override("separation", 0)
	name_vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_vb)

	_name_lbl = UIStyle.label("", 26, UIColors.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_name_lbl.name = "Name"
	_apply_card_text_shadow(_name_lbl)
	name_vb.add_child(_name_lbl)

	_occ_lbl = UIStyle.label("", 14, UIColors.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_occ_lbl.name = "Occupation"
	_apply_card_text_shadow(_occ_lbl)
	name_vb.add_child(_occ_lbl)

	return box


func _build_quote_label() -> Label:
	var lbl := UIStyle.label("", 14, _QUOTE_COLOR, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Quote"
	lbl.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	lbl.offset_left   =  _QUOTE_OFFSET_X
	lbl.offset_right  = -_QUOTE_OFFSET_X
	lbl.offset_top    =  _QUOTE_OFFSET_TOP
	lbl.offset_bottom =  _QUOTE_OFFSET_BOTTOM
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_apply_card_text_shadow(lbl)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


func _build_taken_overlay() -> Control:
	var ov := ColorRect.new()
	ov.name  = "TakenOverlay"
	ov.color = Color(0, 0, 0, 0.6)
	ov.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ov.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lbl := UIStyle.label("PICKER_TAKEN", 18, UIColors.DANGER, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "TakenLabel"
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ov.add_child(lbl)
	return ov


# ── Helpers ───────────────────────────────────────────────────────────────────

func _make_full_rect_texture(tex: Texture2D, mat: Material) -> TextureRect:
	var r := TextureRect.new()
	r.texture       = tex
	r.expand_mode   = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode  = TextureRect.STRETCH_SCALE
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	if mat:
		r.material = mat
	return r


func _make_multiply_material() -> CanvasItemMaterial:
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	return m


# Лёгкая чёрная тень — поднимает читаемость текста поверх неоднородного фона
# (бейдж + портрет). Значения подобраны под 512-px логический UI; supersampling
# в SubViewport'е (см. CARD_TEX_SIZE у picker'а) делает её мягкой.
func _apply_card_text_shadow(lbl: Label) -> void:
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.add_theme_constant_override("shadow_outline_size", 2)


func _load_portrait(inv_name: String) -> Texture2D:
	var path := "res://assets/investigators/%s.png" % inv_name
	if ResourceLoader.exists(path):
		return load(path)
	return _placeholder_tex
