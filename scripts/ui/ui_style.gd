## Фабричные методы для UI Dark Omens.
## Цвета — в UIColors. Используй UIColors.ACCENT, UIColors.DANGER и т.д.
class_name UIStyle


# ── Фон сцены ──────────────────────────────────────────────────────────────────

## Бесшовная фоновая текстура для всех экранов. PNG в @2× (734×790),
## отображается тайлами в половину натурального размера = 367×395 px.
## BG_MODULATE затемняет фон — компенсирует sepia из PostFx, который
## слегка подсвечивает тёмные пиксели. Без этого фон в игре заметно светлее
## референса в Photoshop (где он почти чёрный).
const BG_TEX: Texture2D = preload("res://assets/main-gb.png")
const BG_SCALE: float   = 0.5
const BG_MODULATE: Color = Color(1.0, 1.0, 1.0, 1.0)

## Шейдер тайлинга canvas-item: пересчитывает UV так, чтобы тайл имел
## фиксированный размер `tile_size_px`. Modulate пробрасывается из vertex
## через varying — иначе нельзя:
##   • MODULATE доступен только в vertex, не в fragment.
##   • COLOR в fragment уже содержит texture × modulate, умножать на него
##     ещё раз = двойное умножение на текстуру (тёмный центр).
##
## Опциональная виньетка: радиальное затемнение к углам экрана через
## SCREEN_UV. vignette_strength = 0 отключает эффект. Применяется только
## к фону этого rect'а — не к UI поверх (в отличие от PostFx).
const _TILE_SHADER_CODE := """
shader_type canvas_item;
uniform vec2 tile_size_px;
uniform vec2 rect_size_px;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.0;
uniform float vignette_inner    : hint_range(0.0, 1.0) = 0.3;
uniform float vignette_outer    : hint_range(0.0, 1.0) = 0.85;

varying vec4 v_modulate;

void vertex() {
	// В canvas_item vertex стадии COLOR = caсcаdнный modulate × vertex_color.
	// Сохраняем в varying, чтобы применить к нашему texture-сэмплу в fragment.
	v_modulate = COLOR;
}

void fragment() {
	vec2 uv = fract(UV * rect_size_px / tile_size_px);
	vec4 base = texture(TEXTURE, uv) * v_modulate;

	// Виньетка: дистанция от центра экрана. На корнере ~0.71 (диагональ/2).
	float dist = length(SCREEN_UV - vec2(0.5));
	float vignette = smoothstep(vignette_inner, vignette_outer, dist);
	base.rgb = mix(base.rgb, vec3(0.0), vignette * vignette_strength);

	COLOR = base;
}
"""

## Добавляет тёмный фон на всю область родительского контрола.
static func apply_bg(control: Control) -> void:
	var bg := ColorRect.new()
	bg.color = UIColors.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	control.add_child(bg)


## Назначает на TextureRect шейдер тайлинга с фиксированным размером тайла.
## Подписывается на `resized`, чтобы пересчитать `rect_size_px` при ресайзе.
static func _apply_tile_shader(rect: TextureRect, tile_size_px: Vector2) -> void:
	rect.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	# EXPAND_IGNORE_SIZE — иначе TextureRect минимально равен размеру текстуры,
	# а UV нормализуется по min(rect, texture), что ломает наш UV*rect/tile.
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	var sh := Shader.new()
	sh.code = _TILE_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("tile_size_px", tile_size_px)
	mat.set_shader_parameter("rect_size_px", Vector2(1920, 1080))   # init guess
	rect.material = mat
	rect.resized.connect(func() -> void:
		mat.set_shader_parameter("rect_size_px", rect.size)
	)


## Создаёт TextureRect с шейдером, тайлирующим texture с указанным scale'ом.
## Тайл = texture.get_size() * scale. Caller отвечает за добавление в дерево.
static func make_tiled_texture_rect(
		texture: Texture2D = BG_TEX,
		scale:   float     = BG_SCALE
) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture      = texture
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_apply_tile_shader(rect, texture.get_size() * scale)
	return rect


## Convenience: применяет main-bg.png как тайлированный фон родителя.
## Добавляется первым ребёнком, чтобы оказаться за всем UI.
## Парент может быть Control (тогда занимает его size) или CanvasLayer/Node
## (тогда расстилается по всему viewport'у через PRESET_FULL_RECT).
## Включена виньетка — затемнение к углам экрана для атмосферы.
static func apply_main_bg(parent: Node) -> TextureRect:
	var rect := make_tiled_texture_rect()
	rect.modulate = BG_MODULATE   # затемнение чтобы соответствовать PS-референсу
	(rect.material as ShaderMaterial).set_shader_parameter("vignette_strength", 0.7)
	(rect.material as ShaderMaterial).set_shader_parameter("vignette_inner",    0.25)
	(rect.material as ShaderMaterial).set_shader_parameter("vignette_outer",    0.85)
	parent.add_child(rect)
	parent.move_child(rect, 0)
	return rect


# ── Текстурированная кнопка ──────────────────────────────────────────────────

## Ассеты кнопки нарисованы крупно (226 px высоты, @4×) — выводим в четверть,
## чтобы получить ~56 px высоту, как у обычной UI-кнопки.
const BTN_L_TEX: Texture2D = preload("res://assets/button/L_button.png")
const BTN_C_TEX: Texture2D = preload("res://assets/button/C_button.png")
const BTN_R_TEX: Texture2D = preload("res://assets/button/R_button.png")
const BTN_ASSET_SCALE: float = 0.25

## Фабрика кнопки с фигурным L|C|R фоном (alias для Button.new() + style_button).
##   • L и R — фиксированные «шапки» по краям (ширина = ассет * scale)
##   • C — обрезается / горизонтально тайлируется через шейдер
##   • высота кнопки = высота ассета * scale
##   • ширина = текст + L + R (Button auto-измеряется по контенту)
static func textured_button(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	style_button(btn)
	return btn


static func _btn_cap(tex: Texture2D, size_px: Vector2) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture            = tex
	rect.custom_minimum_size = size_px
	rect.expand_mode        = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode       = TextureRect.STRETCH_SCALE
	rect.mouse_filter       = Control.MOUSE_FILTER_IGNORE
	return rect


static func _btn_center(tex: Texture2D, tile_size: Vector2) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture                  = tex
	rect.size_flags_horizontal    = Control.SIZE_EXPAND_FILL
	rect.custom_minimum_size.y    = tile_size.y
	rect.expand_mode              = TextureRect.EXPAND_IGNORE_SIZE
	rect.mouse_filter             = Control.MOUSE_FILTER_IGNORE
	_apply_tile_shader(rect, tile_size)
	return rect


# ── Кнопка ─────────────────────────────────────────────────────────────────────

## Применяет основной (текстурированный) стиль ко всем «больших» кнопкам:
## L|C|R фон из ассетов button/, прозрачные styleboxes с content-margin'ами
## под шапки. Color-аргумент сохранён для обратной совместимости со старыми
## вызовами, но больше не влияет на внешний вид — стиль задаёт сам ассет.
## Для маленьких ×-кнопок используй style_icon_button.
static func style_button(btn: Button, _legacy_color: Color = UIColors.BORDER) -> void:
	var l_size: Vector2 = BTN_L_TEX.get_size() * BTN_ASSET_SCALE
	var r_size: Vector2 = BTN_R_TEX.get_size() * BTN_ASSET_SCALE
	var c_size: Vector2 = BTN_C_TEX.get_size() * BTN_ASSET_SCALE
	var h: float = l_size.y
	btn.custom_minimum_size.y = h

	# content_margin_bottom > top → текст центрируется в укороченной снизу
	# зоне = визуально сдвигается вверх. Сдвиг = (bottom - top) / 2 = 3 px.
	for state: String in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb := StyleBoxEmpty.new()
		sb.set_content_margin(SIDE_LEFT,  l_size.x)
		sb.set_content_margin(SIDE_RIGHT, r_size.x)
		sb.set_content_margin(SIDE_TOP,    0)
		sb.set_content_margin(SIDE_BOTTOM, 6)
		btn.add_theme_stylebox_override(state, sb)

	btn.add_theme_color_override("font_color",          UIColors.ACCENT)
	btn.add_theme_color_override("font_hover_color",    Color.WHITE)
	btn.add_theme_color_override("font_pressed_color",  UIColors.ACCENT)
	btn.add_theme_color_override("font_disabled_color", UIColors.MUTED)
	btn.add_theme_font_size_override("font_size", 16)

	# Защита от повторного вызова: если фон уже привинчен — не дублируем.
	if btn.get_node_or_null("__TexturedBg") == null:
		var bg := HBoxContainer.new()
		bg.name = "__TexturedBg"
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bg.add_theme_constant_override("separation", 0)
		# CanvasItem дети по умолчанию рисуются ПОСЛЕ родителя — то есть фон
		# перекрыл бы текст Button'а. show_behind_parent=true инвертирует:
		# bg → стилбокс/текст Button → готово.
		bg.show_behind_parent = true
		btn.add_child(bg)
		bg.add_child(_btn_cap(BTN_L_TEX, l_size))
		bg.add_child(_btn_center(BTN_C_TEX, c_size))
		bg.add_child(_btn_cap(BTN_R_TEX, r_size))
		_wire_button_hover(btn, bg)


# Сдвиг кнопки вниз при клике (px) + длительность анимации.
const _PRESS_OFFSET_Y: float  = 3.0
const _PRESS_ANIM_TIME: float = 0.08

# Привязывает визуальную реакцию на hover/press/disabled:
#   • hover     → лёгкий тёплый брайтенинг через modulate
#   • disabled  → приглушение
#   • press     → анимация «нажатия» (сдвиг bg вниз с возвратом)
static func _wire_button_hover(btn: Button, bg: Control) -> void:
	var c_normal   := Color(1.00, 1.00, 1.00, 1.00)
	var c_hover    := Color(1.20, 1.18, 1.10, 1.00)   # тёплый брайтенинг
	var c_disabled := Color(0.45, 0.45, 0.48, 1.00)   # десатурация без прозрачности

	var apply_color := func() -> void:
		if btn.disabled:
			bg.modulate = c_disabled
		elif Rect2(Vector2.ZERO, btn.size).has_point(btn.get_local_mouse_position()):
			bg.modulate = c_hover
		else:
			bg.modulate = c_normal

	btn.mouse_entered.connect(apply_color)
	btn.mouse_exited.connect(apply_color)
	btn.draw.connect(apply_color)   # cheap: ловит изменения .disabled извне

	btn.button_down.connect(func() -> void: _animate_press(btn, true))
	btn.button_up.connect(func() -> void: _animate_press(btn, false))


# Press-анимация: двигаем сам Button (а с ним — и фон, и текст) по Y вниз
# на _PRESS_OFFSET_Y, на release возвращаем обратно. Базовая позиция
# запоминается на каждый press_down (актуальна, даже если layout пересчитал
# координаты между нажатиями), сбрасывается после возврата.
static func _animate_press(btn: Button, down: bool) -> void:
	var meta_tw   := "__press_tween"
	var meta_base := "__base_pos_y"

	if down and not btn.has_meta(meta_base):
		btn.set_meta(meta_base, btn.position.y)
	var base_y: float = btn.get_meta(meta_base) if btn.has_meta(meta_base) else btn.position.y
	var target_y: float = base_y + _PRESS_OFFSET_Y if down else base_y

	# Гасим предыдущий tween, чтобы быстрые клики не накладывались.
	if btn.has_meta(meta_tw):
		var old: Tween = btn.get_meta(meta_tw)
		if old and old.is_valid():
			old.kill()
	var tw := btn.create_tween() \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(btn, "position:y", target_y, _PRESS_ANIM_TIME)
	if not down:
		# После возврата забываем базу — следующий press её перечитает заново.
		tw.tween_callback(func() -> void: btn.remove_meta(meta_base))
	btn.set_meta(meta_tw, tw)


## Применяет компактный stylebox-стиль к маленьким иконочным кнопкам
## (×-close, etc.) — там, где L|C|R фон не помещается.
static func style_icon_button(btn: Button, color: Color = UIColors.DANGER) -> void:
	btn.add_theme_stylebox_override("normal",   _btn_style(Color(0.12, 0.10, 0.20), color))
	btn.add_theme_stylebox_override("hover",    _btn_style(Color(0.20, 0.16, 0.30), UIColors.ACCENT))
	btn.add_theme_stylebox_override("pressed",  _btn_style(Color(0.08, 0.06, 0.14), color))
	btn.add_theme_stylebox_override("disabled", _btn_style(Color(0.08, 0.07, 0.12), UIColors.MUTED))
	btn.add_theme_color_override("font_color",          color)
	btn.add_theme_color_override("font_hover_color",    Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", UIColors.MUTED)


## Создаёт стилизованную кнопку (legacy API для динамического UI).
static func button(label: String, border_color: Color = UIColors.BORDER) -> Button:
	var btn := Button.new()
	btn.text = label
	style_button(btn, border_color)
	return btn


# ── Панель ─────────────────────────────────────────────────────────────────────

## Применяет стили Dark Omens к существующему PanelContainer.
static func style_panel(p: PanelContainer, padding: int = 16) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = UIColors.SURFACE
	style.border_color = UIColors.BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(padding)
	p.add_theme_stylebox_override("panel", style)

## Создаёт PanelContainer с тёмным фоном (legacy API).
static func panel(padding: int = 16) -> PanelContainer:
	var p := PanelContainer.new()
	style_panel(p, padding)
	return p


# ── Поле ввода ─────────────────────────────────────────────────────────────────

## Применяет стили Dark Omens к существующему LineEdit.
static func style_input(le: LineEdit) -> void:
	var style_n := StyleBoxFlat.new()
	style_n.bg_color = Color(0.10, 0.09, 0.18)
	style_n.border_color = UIColors.BORDER
	style_n.set_border_width_all(1)
	style_n.set_corner_radius_all(4)
	style_n.set_content_margin_all(8)

	var style_f := StyleBoxFlat.new()
	style_f.bg_color = Color(0.12, 0.11, 0.22)
	style_f.border_color = UIColors.ACCENT
	style_f.set_border_width_all(1)
	style_f.set_corner_radius_all(4)
	style_f.set_content_margin_all(8)

	le.add_theme_stylebox_override("normal", style_n)
	le.add_theme_stylebox_override("focus",  style_f)
	le.add_theme_color_override("font_color",             UIColors.TEXT)
	le.add_theme_color_override("font_placeholder_color", UIColors.MUTED)
	le.add_theme_font_size_override("font_size", 14)

## Создаёт стилизованный LineEdit (legacy API).
static func input(placeholder: String = "", secret: bool = false) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.secret = secret
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_input(le)
	return le


## Создаёт строку «Метка + LineEdit» и возвращает [HBoxContainer, LineEdit].
static func labeled_input(
	label_text:  String,
	placeholder: String,
	label_w:     int  = 100,
	secret:      bool = false,
) -> Array:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = label_w
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", UIColors.TEXT)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(lbl)

	var le := input(placeholder, secret)
	hbox.add_child(le)

	return [hbox, le]


# ── Выпадающий список ─────────────────────────────────────────────────────────

## Применяет стили Dark Omens к существующему OptionButton.
static func style_option_button(ob: OptionButton) -> void:
	var style_n := StyleBoxFlat.new()
	style_n.bg_color    = Color(0.12, 0.10, 0.20)
	style_n.border_color = UIColors.BORDER
	style_n.set_border_width_all(1)
	style_n.set_corner_radius_all(5)
	style_n.set_content_margin_all(10)

	var style_h := StyleBoxFlat.new()
	style_h.bg_color    = Color(0.20, 0.16, 0.30)
	style_h.border_color = UIColors.ACCENT
	style_h.set_border_width_all(1)
	style_h.set_corner_radius_all(5)
	style_h.set_content_margin_all(10)

	ob.add_theme_stylebox_override("normal",  style_n)
	ob.add_theme_stylebox_override("hover",   style_h)
	ob.add_theme_stylebox_override("pressed", style_h)
	ob.add_theme_stylebox_override("focus",   style_h)
	ob.add_theme_color_override("font_color",       UIColors.TEXT)
	ob.add_theme_color_override("font_hover_color", Color.WHITE)
	ob.add_theme_font_size_override("font_size", 14)

## Создаёт стилизованный OptionButton (legacy API).
static func option_button(items: Array[String] = []) -> OptionButton:
	var ob := OptionButton.new()
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_option_button(ob)
	for item in items:
		ob.add_item(item)
	return ob


# ── Разделитель ────────────────────────────────────────────────────────────────

## Создаёт горизонтальный разделитель и добавляет его в parent.
static func separator(parent: Control, color: Color = UIColors.BORDER) -> void:
	var sep := HSeparator.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_content_margin_all(0)
	sep.add_theme_stylebox_override("separator", style)
	parent.add_child(sep)


# ── Модальное окно ─────────────────────────────────────────────────────────────

## Создаёт модальное окно: затемнение + панель с заголовком.
## content_builder(vbox: VBoxContainer) вызывается для наполнения контента.
## Возвращает корневой ColorRect — вызови queue_free() чтобы закрыть.
static func modal(
	parent:          Control,
	title:           String,
	content_builder: Callable,
	min_width:       int = 440,
) -> ColorRect:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.6)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.add_child(center)

	var p := panel(20)
	p.custom_minimum_size.x = min_width
	center.add_child(p)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	p.add_child(vbox)

	var hdr := Label.new()
	hdr.text = title   # ожидается translation key — Godot переводит сам
	hdr.add_theme_font_size_override("font_size", 16)
	hdr.add_theme_color_override("font_color", UIColors.ACCENT)
	vbox.add_child(hdr)

	separator(vbox)

	content_builder.call(vbox)

	return backdrop


# ── Оверлей переподключения ────────────────────────────────────────────────────

## Создаёт полупрозрачный оверлей с текстом и добавляет его в parent.
## Возвращает ColorRect оверлея.
static func reconnect_overlay(parent: Control, text: String) -> ColorRect:
	var overlay := ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.75)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", UIColors.WARNING)
	overlay.add_child(lbl)

	parent.add_child(overlay)
	return overlay


# ── Внутренние ────────────────────────────────────────────────────────────────

static func _btn_style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(5)
	s.set_content_margin_all(10)
	return s
