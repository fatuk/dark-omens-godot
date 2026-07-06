class_name ActionButton
extends Control

## Кнопка действия панели: медальон-иконка + тянущаяся плашка-название (nine-patch,
## текст рисуется сверху — вписывается под любой перевод) + опц. бейдж-число (текущее
## кол-во ресурса) + опц. оверлей (песочные часы паса, умеют крутиться).
##
## Строится в НАТУРАЛЬНОМ 2× (ассеты @2×); родитель (ActionPanel) ужимает весь блок
## scale 0.5 — так кант плашки/иконки рисуется крупно = чётко.
##
## API: new(icon, title, key, overlay=null, with_badge=false) → эмитит `pressed`;
##      set_disabled(b), set_badge(n), spin_overlay(), pop_token().

signal pressed

const _ICON_BOX: float = 230.0  # медальон-иконка (2×)
const _OVERLAY: Vector2 = Vector2(96, 132)  # часы внутри медальона (2×) — с воздухом до рамки
const _PLAQUE_FONT: int = 34
const _BADGE_FONT: int = 40
const _GAP: int = 4  # иконка ↔ плашка
## Смещение верха медальона-иконки от верха виджета (2×): высота бейдж-строки + gap.
## ActionPanel выравнивает по нему сторонние элементы (индикатор улик).
const ICON_TOP_2X := _BADGE_FONT + 8 + _GAP

# Плашка-название: nine-patch. Кант/самоцветы (texture_margin) не тянутся, плоский
# центр — да. Значения замерены по плашке (плоский центр X 64..349, Y 8..90): если
# кап больше — тянет/режет ornate-конец и самоцвет (перекос).
const _T_MARGIN_L: int = 64
const _T_MARGIN_R: int = 61
const _T_MARGIN_T: int = 8
const _T_MARGIN_B: int = 10
const _T_PAD_LR: int = 80  # воздух слева/справа от текста (текст держим от самоцветов)
const _T_PAD_T: int = 24
const _T_PAD_B: int = 24

const _C_TEXT := Color(0.91, 0.86, 0.75)  # тёплый пергамент — текст плашки
const _DISABLED_MOD := UIColors.DISABLED

const _SPIN_DUR: float = 0.5  # длительность проворота часов
const _SPIN_BLUR: float = 0.9  # пиковый угол смаза (рад)

const _POP_DUR: float = 0.5  # длительность полёта жетона «в камеру»
const _POP_SCALE: float = 2.6  # во сколько раз вырастает летящий жетон

# Угловой мотион-блюр: сэмплим текстуру по дуге вокруг центра (± blur_rad/2), даёт
# смаз вращения. blur_rad=0 → резко. Крутим во время проворота часов при пасе.
const _SPIN_BLUR_SHADER := """
shader_type canvas_item;
uniform float blur_rad = 0.0;
const int SAMPLES = 12;
void fragment() {
	vec4 mod_color = COLOR;  // входной MODULATE (напр. затемнение disabled) — иначе часы не гаснут
	vec2 c = vec2(0.5);
	vec2 d = UV - c;
	float r = length(d);
	float a0 = atan(d.y, d.x);
	vec4 acc = vec4(0.0);
	for (int i = 0; i < SAMPLES; i++) {
		float t = float(i) / float(SAMPLES - 1) - 0.5;
		float a = a0 + t * blur_rad;
		acc += texture(TEXTURE, c + r * vec2(cos(a), sin(a)));
	}
	COLOR = (acc / float(SAMPLES)) * mod_color;
}
"""

var _icon: TextureRect
var _overlay: TextureRect
var _badge: Label
var _plaque_lbl: Label
var _key: String = ""
var _disabled: bool = false
var _hover: bool = false


func _init(
	icon_tex: Texture2D,
	title_tex: Texture2D,
	text_key: String,
	overlay_tex: Texture2D = null,
	_with_badge: bool = false
) -> void:
	_key = text_key
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var vb := VBoxContainer.new()
	vb.name = "VB"
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", _GAP)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	add_child(vb)

	# ── счётчик токенов НАД кнопкой (пустой у действий без счётчика — держит
	# вертикальное выравнивание иконок в ряду) ──
	_badge = Label.new()
	_badge.name = "Badge"
	_badge.add_theme_font_size_override("font_size", _BADGE_FONT)
	_badge.add_theme_color_override("font_color", UIColors.VALUE)
	_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_badge.custom_minimum_size = Vector2(0, _BADGE_FONT + 8)
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_badge)

	# ── медальон + (часы) ──
	var box := Control.new()
	box.name = "IconBox"
	box.custom_minimum_size = Vector2(_ICON_BOX, _ICON_BOX)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(box)
	_icon = _make_tex(icon_tex)
	_icon.name = "Icon"
	_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_child(_icon)
	if overlay_tex != null:
		var cc := CenterContainer.new()
		cc.name = "OverlayCenter"
		cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(cc)
		_overlay = _make_tex(overlay_tex)
		_overlay.name = "Overlay"
		_overlay.custom_minimum_size = _OVERLAY
		_overlay.pivot_offset = _OVERLAY * 0.5
		var sm := ShaderMaterial.new()
		var sh := Shader.new()
		sh.code = _SPIN_BLUR_SHADER
		sm.shader = sh
		_overlay.material = sm  # угловой блюр во время проворота
		cc.add_child(_overlay)

	# ── тянущаяся плашка-название ──
	var sb := StyleBoxTexture.new()
	sb.texture = title_tex
	sb.texture_margin_left = _T_MARGIN_L
	sb.texture_margin_right = _T_MARGIN_R
	sb.texture_margin_top = _T_MARGIN_T
	sb.texture_margin_bottom = _T_MARGIN_B
	sb.content_margin_left = _T_PAD_LR
	sb.content_margin_right = _T_PAD_LR
	sb.content_margin_top = _T_PAD_T
	sb.content_margin_bottom = _T_PAD_B
	var pc := PanelContainer.new()
	pc.name = "Plaque"
	pc.add_theme_stylebox_override("panel", sb)
	pc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS  # мипмапы плашки
	vb.add_child(pc)
	_plaque_lbl = Label.new()
	_plaque_lbl.name = "Title"
	_plaque_lbl.add_theme_font_size_override("font_size", _PLAQUE_FONT)
	_plaque_lbl.add_theme_color_override("font_color", _C_TEXT)
	_plaque_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_plaque_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_child(_plaque_lbl)

	# Размер виджета = обёртке (VBox). Переводы меняют ширину плашки → следим.
	vb.resized.connect(func() -> void: custom_minimum_size = vb.size)
	mouse_entered.connect(func() -> void: _set_hover(true))
	mouse_exited.connect(func() -> void: _set_hover(false))
	# Перевод — через LocaleBinder (пересчитает tr() при смене локали).
	LocaleBinder.bind(_plaque_lbl, func() -> String: return tr(_key))


func _make_tex(t: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.name = "Tex"  # вызывающий переопределяет (Icon/Overlay)
	r.texture = t
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _gui_input(event: InputEvent) -> void:
	if _disabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit()
			accept_event()


func set_disabled(v: bool) -> void:
	_disabled = v
	mouse_default_cursor_shape = (Control.CURSOR_ARROW if v else Control.CURSOR_POINTING_HAND)
	_apply_mod()


func set_badge(n: int) -> void:
	if _badge != null:
		_badge.text = str(n)


func _set_hover(v: bool) -> void:
	_hover = v
	_apply_mod()


func _apply_mod() -> void:
	if _disabled:
		modulate = _DISABLED_MOD
	elif _hover:
		modulate = UIColors.HIGHLIGHT
	else:
		modulate = Color.WHITE


# Быстрый проворот оверлея (часов) на 360° с угловым мотион-блюром — для паса.
# Блюр нарастает к середине проворота и спадает к концу (пик угловой скорости).
func spin_overlay() -> void:
	if _overlay == null:
		return
	var mat := _overlay.material as ShaderMaterial
	_overlay.rotation = 0.0
	if mat != null:
		mat.set_shader_parameter("blur_rad", 0.0)
	var spin := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	spin.tween_property(_overlay, "rotation", TAU, _SPIN_DUR)
	spin.tween_callback(func() -> void: _overlay.rotation = 0.0)
	if mat != null:
		var blur := create_tween().set_trans(Tween.TRANS_SINE)
		(
			blur
			. tween_method(
				func(v: float) -> void: mat.set_shader_parameter("blur_rad", v),
				0.0,
				_SPIN_BLUR,
				_SPIN_DUR * 0.5
			)
			. set_ease(Tween.EASE_OUT)
		)
		(
			blur
			. tween_method(
				func(v: float) -> void: mat.set_shader_parameter("blur_rad", v),
				_SPIN_BLUR,
				0.0,
				_SPIN_DUR * 0.5
			)
			. set_ease(Tween.EASE_IN)
		)
	await spin.finished  # awaitable: вызывающий может дождаться конца проворота


# Взятый жетон летит «в камеру»: копия медальона растёт от центра и растворяется.
# Awaitable — вызывающий держит флоу игры, пока не доиграет (как spin_overlay).
func pop_token() -> void:
	if _icon == null or _icon.texture == null:
		return
	var box: Control = _icon.get_parent()  # IconBox — стартовый размер/позиция жетона
	var tok := TextureRect.new()
	tok.name = "TokenPop"
	tok.texture = _icon.texture
	tok.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tok.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tok.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	tok.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tok.size = box.size
	tok.pivot_offset = box.size * 0.5  # рост от центра медальона
	tok.z_index = 4096  # поверх остальной панели
	add_child(tok)
	tok.global_position = box.global_position
	var tw := create_tween().set_parallel(true)
	(
		tw
		. tween_property(tok, "scale", Vector2(_POP_SCALE, _POP_SCALE), _POP_DUR)
		. set_trans(Tween.TRANS_CUBIC)
		. set_ease(Tween.EASE_OUT)
	)
	tw.tween_property(tok, "modulate:a", 0.0, _POP_DUR).set_trans(Tween.TRANS_QUAD).set_ease(
		Tween.EASE_IN
	)
	await tw.finished
	tok.queue_free()
