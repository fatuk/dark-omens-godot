## Фабричные методы для UI Dark Omens.
## Цвета — в UIColors. Используй UIColors.ACCENT, UIColors.DANGER и т.д.
class_name UIStyle

# ── Цвета фабрики кнопок (styling-детали, не тема; общие для style-функций) ─────
const _BTN_BG := Color(0.12, 0.10, 0.20)  # обычный фон кнопки
const _BTN_BG_HOVER := Color(0.20, 0.16, 0.30)  # фон при наведении
const _HOVER_BRIGHTEN := Color(1.20, 1.18, 1.10, 1.00)  # тёплый брайтенинг (modulate hover)
const _DISABLED_TINT := Color(0.45, 0.45, 0.48, 1.00)  # десатурация disabled

# ── Фон сцены ──────────────────────────────────────────────────────────────────

## Бесшовная фоновая текстура для всех экранов. PNG в @2× (734×790),
## отображается тайлами в половину натурального размера = 367×395 px.
## BG_MODULATE затемняет фон — компенсирует sepia из PostFx, который
## слегка подсвечивает тёмные пиксели. Без этого фон в игре заметно светлее
## референса в Photoshop (где он почти чёрный).
const BG_TEX: Texture2D = preload("res://assets/ui/bg-pattern.png")
const BG_SCALE: float = 0.5
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
	bg.name = "Background"
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
	mat.set_shader_parameter("rect_size_px", Vector2(1920, 1080))  # init guess
	rect.material = mat
	rect.resized.connect(func() -> void: mat.set_shader_parameter("rect_size_px", rect.size))


## Создаёт TextureRect с шейдером, тайлирующим texture с указанным scale'ом.
## Тайл = texture.get_size() * scale. Caller отвечает за добавление в дерево.
static func make_tiled_texture_rect(
	texture: Texture2D = BG_TEX, scale: float = BG_SCALE
) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = texture
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
	rect.modulate = BG_MODULATE  # затемнение чтобы соответствовать PS-референсу
	(rect.material as ShaderMaterial).set_shader_parameter("vignette_strength", 0.7)
	(rect.material as ShaderMaterial).set_shader_parameter("vignette_inner", 0.25)
	(rect.material as ShaderMaterial).set_shader_parameter("vignette_outer", 0.85)
	parent.add_child(rect)
	parent.move_child(rect, 0)
	return rect


# ── Текстурированная кнопка ──────────────────────────────────────────────────

## Ассеты кнопки нарисованы крупно (226 px высоты, @4×) — выводим в четверть,
## чтобы получить ~56 px высоту, как у обычной UI-кнопки.
const BTN_L_TEX: Texture2D = preload("res://assets/ui/button/L_button.png")
const BTN_C_TEX: Texture2D = preload("res://assets/ui/button/C_button.png")
const BTN_R_TEX: Texture2D = preload("res://assets/ui/button/R_button.png")
const BTN_ASSET_SCALE: float = 0.25


## Фабрика кнопки с фигурным L|C|R фоном (alias для Button.new() + style_button).
##   • L и R — фиксированные «шапки» по краям (ширина = ассет * scale)
##   • C — обрезается / горизонтально тайлируется через шейдер
##   • высота кнопки = высота ассета * scale
##   • ширина = текст + L + R (Button auto-измеряется по контенту)
static func textured_button(text: String) -> Button:
	var btn := Button.new()
	btn.name = "Button"
	btn.text = text
	style_button(btn)
	return btn


static func _btn_cap(tex: Texture2D, size_px: Vector2) -> TextureRect:
	var rect := TextureRect.new()
	rect.name = "Rect"
	rect.texture = tex
	rect.custom_minimum_size = size_px
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


static func _btn_center(tex: Texture2D, tile_size: Vector2) -> TextureRect:
	var rect := TextureRect.new()
	rect.name = "Rect"
	rect.texture = tex
	rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rect.custom_minimum_size.y = tile_size.y
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
		sb.set_content_margin(SIDE_LEFT, l_size.x)
		sb.set_content_margin(SIDE_RIGHT, r_size.x)
		sb.set_content_margin(SIDE_TOP, 0)
		sb.set_content_margin(SIDE_BOTTOM, 6)
		btn.add_theme_stylebox_override(state, sb)

	btn.add_theme_color_override("font_color", UIColors.ACCENT)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", UIColors.ACCENT)
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
const _PRESS_OFFSET_Y: float = 3.0
const _PRESS_ANIM_TIME: float = 0.08


# Привязывает визуальную реакцию на hover/press/disabled:
#   • hover     → лёгкий тёплый брайтенинг через modulate
#   • disabled  → приглушение
#   • press     → анимация «нажатия» (сдвиг bg вниз с возвратом)
static func _wire_button_hover(btn: Button, bg: Control) -> void:
	var c_normal := Color(1.00, 1.00, 1.00, 1.00)
	var c_hover := _HOVER_BRIGHTEN  # тёплый брайтенинг
	var c_disabled := _DISABLED_TINT  # десатурация без прозрачности

	var apply_color := func() -> void:
		if btn.disabled:
			bg.modulate = c_disabled
		elif Rect2(Vector2.ZERO, btn.size).has_point(btn.get_local_mouse_position()):
			bg.modulate = c_hover
		else:
			bg.modulate = c_normal

	btn.mouse_entered.connect(apply_color)
	btn.mouse_exited.connect(apply_color)
	btn.draw.connect(apply_color)  # cheap: ловит изменения .disabled извне

	btn.button_down.connect(func() -> void: _animate_press(btn, true))
	btn.button_up.connect(func() -> void: _animate_press(btn, false))
	attach_click_sfx(btn)


## Подключает звук клика к любой Button/TextureButton/BaseButton. Используется
## внутри style_button / style_icon_button / texture_icon_button — добавлять
## вручную нужно только для кастомных кнопок, которые не проходят через них.
## Idempotent — повторный вызов на той же кнопке игнорируется (иначе сигнал
## подключился бы дважды → двойной звук).
##
## Слушает button_down (а не pressed): звук играет сразу при нажатии, до
## release — это даёт тактильный отклик; pressed бы запустил его уже на
## отпускании, что ощущается заторможенно.
static func attach_click_sfx(btn: BaseButton) -> void:
	if btn.has_meta("__click_sfx_wired"):
		return
	btn.set_meta("__click_sfx_wired", true)
	btn.button_down.connect(func() -> void: SfxManager.play_random_btn_click())


# Press-анимация: двигаем сам Button (а с ним — и фон, и текст) по Y вниз
# на _PRESS_OFFSET_Y, на release возвращаем обратно. Базовая позиция
# запоминается на каждый press_down (актуальна, даже если layout пересчитал
# координаты между нажатиями), сбрасывается после возврата.
static func _animate_press(btn: BaseButton, down: bool) -> void:
	var meta_tw := "__press_tween"
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
	var tw := btn.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(btn, "position:y", target_y, _PRESS_ANIM_TIME)
	if not down:
		# После возврата забываем базу — следующий press её перечитает заново.
		tw.tween_callback(func() -> void: btn.remove_meta(meta_base))
	btn.set_meta(meta_tw, tw)


# ── Текстурная иконочная кнопка ─────────────────────────────────────────────


## Создаёт TextureButton (иконка без текста) с hover-брайтенингом и press-
## анимацией — аналог style_button для обычных Button'ов. По умолчанию scale=0.5
## — стандартный @2× коэффициент проекта. Для @4× ассетов (carousel/) ставь 0.25.
static func texture_icon_button(tex: Texture2D, scale: float = 0.5) -> TextureButton:
	var btn := TextureButton.new()
	btn.name = "Button"
	btn.texture_normal = tex
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	btn.custom_minimum_size = tex.get_size() * scale
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_wire_texture_button_hover(btn)
	return btn


# Hover/press feedback для TextureButton: modulate на наведении + press-tween.
# Аналогично _wire_button_hover для Button, но без отдельного __TexturedBg —
# для иконки modulate применяется прямо на саму кнопку.
static func _wire_texture_button_hover(btn: BaseButton) -> void:
	var c_normal := Color(1.00, 1.00, 1.00, 1.00)
	var c_hover := _HOVER_BRIGHTEN  # тёплый брайтенинг
	var c_disabled := _DISABLED_TINT

	var apply_color := func() -> void:
		if btn.disabled:
			btn.modulate = c_disabled
		elif Rect2(Vector2.ZERO, btn.size).has_point(btn.get_local_mouse_position()):
			btn.modulate = c_hover
		else:
			btn.modulate = c_normal

	btn.mouse_entered.connect(apply_color)
	btn.mouse_exited.connect(apply_color)
	btn.draw.connect(apply_color)
	btn.button_down.connect(func() -> void: _animate_press(btn, true))
	btn.button_up.connect(func() -> void: _animate_press(btn, false))
	attach_click_sfx(btn)


## Применяет компактный stylebox-стиль к маленьким иконочным кнопкам
## (×-close, etc.) — там, где L|C|R фон не помещается.
static func style_icon_button(btn: Button, color: Color = UIColors.DANGER) -> void:
	btn.add_theme_stylebox_override("normal", _btn_style(_BTN_BG, color))
	btn.add_theme_stylebox_override("hover", _btn_style(_BTN_BG_HOVER, UIColors.ACCENT))
	btn.add_theme_stylebox_override("pressed", _btn_style(Color(0.08, 0.06, 0.14), color))
	btn.add_theme_stylebox_override("disabled", _btn_style(Color(0.08, 0.07, 0.12), UIColors.MUTED))
	btn.add_theme_color_override("font_color", color)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", UIColors.MUTED)
	attach_click_sfx(btn)


## Создаёт стилизованную кнопку (legacy API для динамического UI).
static func button(text: String, border_color: Color = UIColors.BORDER) -> Button:
	var btn := Button.new()
	btn.name = "Button"
	btn.text = text
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
	p.name = "Panel"
	style_panel(p, padding)
	return p


# ── Модальная рамка ──────────────────────────────────────────────────────────
# Единый ассет-скин для ВСЕХ модалок: орнаментная рамка modal-frame.png,
# скомпонованная поверх паттерна bg-pattern.png (см. assets/modal/modal-panel-bg.png),
# нарезанная 9-slice — углы фиксированы, центр тянется.

const _MODAL_BG_TEX: Texture2D = preload("res://assets/modal/modal-panel-bg.png")
const _MODAL_CLOSE_TEX: Texture2D = preload("res://assets/modal/modal-close-btn.png")
const _MODAL_FRAME_MARGIN: float = 80.0  # ассеты @2× (×0.5); угловой орнамент ~75px


## StyleBoxTexture с орнаментной рамкой. content_pad — отступ контента внутрь
## от рамки (по краям рамка ~14px + воздух).
static func make_modal_stylebox(content_pad: int = 26) -> StyleBoxTexture:
	var sb := StyleBoxTexture.new()
	sb.texture = _MODAL_BG_TEX
	sb.texture_margin_left = _MODAL_FRAME_MARGIN
	sb.texture_margin_right = _MODAL_FRAME_MARGIN
	sb.texture_margin_top = _MODAL_FRAME_MARGIN
	sb.texture_margin_bottom = _MODAL_FRAME_MARGIN
	sb.content_margin_left = float(content_pad)
	sb.content_margin_right = float(content_pad)
	sb.content_margin_top = float(content_pad)
	sb.content_margin_bottom = float(content_pad)
	return sb


## Применяет орнаментную модальную рамку к PanelContainer.
static func style_modal_panel(p: PanelContainer, content_pad: int = 22) -> void:
	p.add_theme_stylebox_override("panel", make_modal_stylebox(content_pad))


# ── Появление/исчезновение модалок ─────────────────────────────────────────────
#
# ЕДИНЫЙ эффект для ВСЕХ модалок (взят от окна встречи): вся модалка вместе с
# затемнением плавно проявляется, а панель мягко подрастает из 0.95 —
# «выплывает». Закрытие — то же в обратную сторону, но быстрее.

# Крутится в панели тюнинга (Ctrl+M, секция «МОДАЛКИ»); найденное значение
# запекается сюда же. static var, а не const — панель правит их на живой игре.
static var MODAL_FADE_IN: float = 0.2
static var MODAL_FADE_OUT: float = 0.15
static var MODAL_POP: float = 0.9  # с какого масштаба выплывает панель
static var MODAL_BACKDROP_ALPHA: float = 0.8  # затемнение экрана под панелью

const _MODAL_OWN_BACKDROP: StringName = &"modal_own_backdrop"
const _MODAL_TWEEN_META: StringName = &"modal_anim_tween"
const _MODAL_SHOWN_META: StringName = &"modal_anim_shown"
const _MODAL_PIVOT_META: StringName = &"modal_anim_pivot"

# Реестр ОТКРЫТЫХ модалок: id инстанса → узел. Ведётся здесь, потому что через
# modal_transition проходят все окна проекта. Нужен тем, кто не должен лезть
# поверх открытого окна (баннер «Ваш ход» ждёт, пока экран освободится) и карте:
# под открытым окном она не зумится и не таскается.
static var _open_modals: Dictionary = {}


## Открыта ли сейчас хоть одна модалка. Запись считается открытой, только пока узел
## жив И виден: так в реестре может постоянно жить окно, которое само себя прячет
## (магазин, галерея), — оно «закрыто», пока невидимо. Мёртвые записи чистим.
static func any_modal_open() -> bool:
	var open: bool = false
	for id_v: Variant in _open_modals.keys():
		var n: Variant = _open_modals[id_v]
		if not is_instance_valid(n):
			_open_modals.erase(id_v)
			continue
		# visible читаем через get: в реестре бывают и Control, и CanvasLayer.
		if bool((n as Object).get("visible")):
			open = true
	return open


## Внести окно в реестр открытых. Для тех, кто НЕ пользуется общим эффектом
## (магазин, галерея): зовётся один раз при создании, дальше учитывается по
## собственной видимости узла. Иначе карта под таким окном осталась бы живой —
## Control с MOUSE_FILTER_STOP съедает клик, но колесо пропускает сквозь себя.
static func mark_modal(node: Node, open: bool) -> void:
	if open:
		_open_modals[node.get_instance_id()] = node
	else:
		_open_modals.erase(node.get_instance_id())


## Пометить окно, у которого затемнение СВОЁ (крупный просмотр карты темнее прочих),
## — общий ползунок его не трогает.
static func keep_own_backdrop(root: Control) -> void:
	root.set_meta(_MODAL_OWN_BACKDROP, true)


## Проставить окну общее затемнение. Подложка — сам root, если он ColorRect (так у
## большинства окон), иначе ColorRect среди его ПРЯМЫХ детей (у ModalDialog это
## Backdrop). Глубже не лезем: там уже декоративные заливки внутри панели.
static func apply_backdrop_alpha(root: Control) -> void:
	if root.has_meta(_MODAL_OWN_BACKDROP):
		return
	var backdrop: ColorRect = root as ColorRect
	if backdrop == null:
		for c: Node in root.get_children():
			if c is ColorRect:
				backdrop = c
				break
	if backdrop != null:
		backdrop.color.a = MODAL_BACKDROP_ALPHA


## Перекрасить подложки всех ОТКРЫТЫХ окон (панель тюнинга — видно сразу).
static func refresh_backdrops() -> void:
	for id_v: Variant in _open_modals.keys():
		var n: Variant = _open_modals[id_v]
		if is_instance_valid(n) and n is Control:
			apply_backdrop_alpha(n as Control)


## Проигрывает переход модалки. root — слой целиком (вместе с затемнением),
## card — панель, которая «выплывает» (можно null: тогда только проявление).
## Возвращает tween, чтобы вызывающий дочепил свои шаги (скрытие, queue_free).
static func modal_transition(root: Control, card: Control, showing: bool) -> Tween:
	if root.has_meta(_MODAL_TWEEN_META):
		var prev: Variant = root.get_meta(_MODAL_TWEEN_META)
		if prev is Tween and (prev as Tween).is_valid():
			(prev as Tween).kill()

	var small := Vector2(MODAL_POP, MODAL_POP)
	if card != null:
		_track_modal_pivot(card)
		if showing:
			card.scale = small
	if showing:
		root.modulate.a = 0.0
		apply_backdrop_alpha(root)

	if showing:
		_open_modals[root.get_instance_id()] = root
	else:
		_open_modals.erase(root.get_instance_id())

	var dur: float = MODAL_FADE_IN if showing else MODAL_FADE_OUT
	var tw: Tween = root.create_tween().set_parallel(true)
	tw.tween_property(root, "modulate:a", 1.0 if showing else 0.0, dur)
	if card != null:
		(
			tw
			. tween_property(card, "scale", Vector2.ONE if showing else small, dur * 1.45)
			. set_trans(Tween.TRANS_CUBIC)
			. set_ease(Tween.EASE_OUT)
		)
	root.set_meta(_MODAL_TWEEN_META, tw)
	return tw


## Показать/скрыть модалку общим эффектом. Идемпотентно: модалки дёргают это из
## _refresh на КАЖДОМ синке, повторный вызов с тем же состоянием ничего не
## перезапускает. Скрытие снимает visible только после анимации.
static func modal_set_visible(root: Control, card: Control, want: bool) -> void:
	var shown: bool = (
		bool(root.get_meta(_MODAL_SHOWN_META)) if root.has_meta(_MODAL_SHOWN_META) else root.visible
	)
	if shown == want:
		return
	root.set_meta(_MODAL_SHOWN_META, want)
	if want:
		root.visible = true
		modal_transition(root, card, true)
		return
	modal_transition(root, card, false).chain().tween_callback(
		func() -> void:
			# Скрываем, только если за время анимации модалку не открыли заново.
			if not bool(root.get_meta(_MODAL_SHOWN_META)):
				root.visible = false
	)


# Панель растёт из центра, а не из левого верхнего угла. Размер контейнерных
# панелей считается позже, поэтому подписываемся на resized и держим pivot
# актуальным (первый показ до раскладки — по custom_minimum_size).
static func _track_modal_pivot(card: Control) -> void:
	if not card.has_meta(_MODAL_PIVOT_META):
		card.set_meta(_MODAL_PIVOT_META, true)
		card.resized.connect(func() -> void: card.pivot_offset = card.size * 0.5)
	var base: Vector2 = card.size if card.size != Vector2.ZERO else card.custom_minimum_size
	card.pivot_offset = base * 0.5


## Делает кнопку закрытия модалки из арта modal-close-btn.png (без фона/рамок).
static func style_modal_close_button(btn: Button) -> void:
	btn.text = ""
	btn.icon = _MODAL_CLOSE_TEX
	btn.expand_icon = true
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if btn.custom_minimum_size == Vector2.ZERO:
		btn.custom_minimum_size = Vector2(32, 32)
	var empty := StyleBoxEmpty.new()
	for s: String in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(s, empty)
	# Тот же hover-эффект, что у кнопки Info на карусели: тёплый брайтенинг
	# иконки на наведении + press-анимация вниз (фон прозрачный → красится иконка).
	_wire_texture_button_hover(btn)


# ── Поле ввода ─────────────────────────────────────────────────────────────────


## Применяет стили Dark Omens к существующему LineEdit.
static func style_input(le: LineEdit) -> void:
	var style_n := StyleBoxFlat.new()
	style_n.bg_color = UIColors.CONTROL
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
	le.add_theme_stylebox_override("focus", style_f)
	le.add_theme_color_override("font_color", UIColors.TEXT)
	le.add_theme_color_override("font_placeholder_color", UIColors.MUTED)
	le.add_theme_font_size_override("font_size", 14)


## Создаёт стилизованный LineEdit (legacy API).
static func input(placeholder: String = "", secret: bool = false) -> LineEdit:
	var le := LineEdit.new()
	le.name = "LineEdit"
	le.placeholder_text = placeholder
	le.secret = secret
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_input(le)
	return le


## Создаёт строку «Метка + LineEdit» и возвращает [HBoxContainer, LineEdit].
static func labeled_input(
	label_text: String,
	placeholder: String,
	label_w: int = 100,
	secret: bool = false,
) -> Array:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var lbl := Label.new()
	lbl.name = "Label"
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
	style_n.bg_color = _BTN_BG
	style_n.border_color = UIColors.BORDER
	style_n.set_border_width_all(1)
	style_n.set_corner_radius_all(5)
	style_n.set_content_margin_all(10)

	var style_h := StyleBoxFlat.new()
	style_h.bg_color = _BTN_BG_HOVER
	style_h.border_color = UIColors.ACCENT
	style_h.set_border_width_all(1)
	style_h.set_corner_radius_all(5)
	style_h.set_content_margin_all(10)

	ob.add_theme_stylebox_override("normal", style_n)
	ob.add_theme_stylebox_override("hover", style_h)
	ob.add_theme_stylebox_override("pressed", style_h)
	ob.add_theme_stylebox_override("focus", style_h)
	ob.add_theme_color_override("font_color", UIColors.TEXT)
	ob.add_theme_color_override("font_hover_color", Color.WHITE)
	ob.add_theme_font_size_override("font_size", 14)


## Создаёт стилизованный OptionButton (legacy API).
static func option_button(items: Array[String] = []) -> OptionButton:
	var ob := OptionButton.new()
	ob.name = "OptionButton"
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_option_button(ob)
	for item in items:
		ob.add_item(item)
	return ob


# ── Слайдер громкости ──────────────────────────────────────────────────────────


## Строка «Метка + HSlider + 0-100%». Слайдер 0..1 со step=0.01; при движении
## вызывает `apply_fn.call(value)` для live-preview. Возвращает HSlider —
## вызывающая сторона читает финальное значение при «Save».
static func volume_slider_row(
	parent: Control,
	label_key: String,
	initial: float,
	apply_fn: Callable,
) -> HSlider:
	var row := HBoxContainer.new()
	row.name = "VolumeRow_%s" % label_key
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.name = "Label"
	lbl.text = label_key
	lbl.custom_minimum_size.x = 110
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", UIColors.TEXT)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var slider := HSlider.new()
	slider.name = "Slider"
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size = Vector2(0, 22)
	row.add_child(slider)

	var pct := Label.new()
	pct.name = "Percent"
	pct.text = "%d%%" % roundi(initial * 100.0)
	pct.custom_minimum_size.x = 44
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pct.add_theme_font_size_override("font_size", 13)
	pct.add_theme_color_override("font_color", UIColors.MUTED)
	pct.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(pct)

	slider.value_changed.connect(
		func(v: float) -> void:
			apply_fn.call(v)
			pct.text = "%d%%" % roundi(v * 100.0)
	)
	return slider


# ── Лейбл ──────────────────────────────────────────────────────────────────────


## Однострочная фабрика стилизованного Label'а — заменяет 4-строчный паттерн
## (Label.new + text + font_size + font_color) на один вызов.
static func label(
	text: String,
	size: int,
	color: Color = UIColors.TEXT,
	align: int = HORIZONTAL_ALIGNMENT_LEFT,
) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = align as HorizontalAlignment
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	return lbl


## Единый заголовок модалки: размер 22, по центру, перенос по словам.
## color — обычно ACCENT (янтарь), у мифа DANGER (красный).
static func modal_title(text: String, color: Color = UIColors.ACCENT) -> Label:
	var lbl := label(text, 22, color, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Title"
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return lbl


const _ORNATE_CHEVRON_L: Texture2D = preload("res://assets/ui/nav/L_chevron.png")
const _ORNATE_CHEVRON_R: Texture2D = preload("res://assets/ui/nav/R_chevron.png")


## Орнаментальный заголовок секции: декор-шеврон · подпись · шеврон (как «ВЫБЕРИТЕ
## СЫЩИКА» в пикере). text — i18n-ключ (Label авто-переводит). Тянется по ширине,
## подпись по центру. Переиспользуемо на любом экране/секции.
static func ornate_title(
	text: String, size: int = 28, color: Color = UIColors.ACCENT
) -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.name = "OrnateTitle"
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_theme_constant_override("separation", 14)
	hb.add_child(_ornate_chevron(_ORNATE_CHEVRON_L))
	var lbl := label(text, size, color, HORIZONTAL_ALIGNMENT_CENTER)
	lbl.name = "Title"
	hb.add_child(lbl)
	hb.add_child(_ornate_chevron(_ORNATE_CHEVRON_R))
	return hb


# Декоративный шеврон сбоку от орнаментального заголовка (PNG @≈4× → скейл 0.25).
static func _ornate_chevron(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.name = "Chevron"
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = tex.get_size() * 0.25
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## Шапка модалки: центрированный заголовок + крестик закрытия в правом верхнем
## углу (как у ModalDialog). on_close вызывается по нажатию крестика; если
## Callable пустой — крестик не добавляется. Добавляй первым ребёнком в VBox
## панели — крестик выезжает за край контента на орнаментную рамку.
static func modal_header(
	title_text: String, on_close: Callable = Callable(), color: Color = UIColors.ACCENT
) -> Control:
	var header := Control.new()
	header.name = "Header"
	header.custom_minimum_size = Vector2(0, 40)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var title := modal_title(title_text, color)
	title.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(title)

	if on_close.is_valid():
		var close := Button.new()
		close.name = "CloseBtn"
		style_modal_close_button(close)
		close.anchor_left = 1.0
		close.anchor_right = 1.0
		close.offset_left = -10.0
		close.offset_top = -38.0
		close.offset_right = 38.0
		close.offset_bottom = 10.0
		close.pressed.connect(on_close)
		header.add_child(close)

	return header


## Множитель размера шрифта в модалках.
const MODAL_FONT_SCALE: float = 1.5


## Рекурсивно увеличивает размер шрифта текстовых контролов поддерева в factor раз.
## КНОПКИ НЕ трогаем (Button/OptionButton) — у них свой стиль и размер; масштабируем
## только текст (Label) и поля ввода (LineEdit). Вызывать ОДИН раз после построения
## контента модалки (повторный вызов на тех же узлах удвоит масштаб — для
## перестраиваемых модалок звать после каждой пересборки, узлы создаются заново).
static func scale_modal_text(node: Node, factor: float = MODAL_FONT_SCALE) -> void:
	if node is Label or node is LineEdit:
		var c := node as Control
		var cur: int = c.get_theme_font_size("font_size")
		if cur > 0:
			c.add_theme_font_size_override("font_size", roundi(float(cur) * factor))
	for ch in node.get_children():
		scale_modal_text(ch, factor)


# ── Разделитель ────────────────────────────────────────────────────────────────

## Цвет разделителей в модалках — почти чёрный, под тёмную рамку.
const MODAL_LINE_COLOR: Color = Color("#0b0b09")


## Создаёт горизонтальный разделитель и добавляет его в parent.
## Строка-степпер «метка [−] N [+]» для распределения величины. Мутирует state[key]
## и зовёт upd_ref.fn после каждого изменения (вызывающий пересчитывает подписи и
## доступность кнопок). Возвращает {count, plus, minus} — узлы для этого пересчёта.
## Общая для модалки отдыха и способностей сыщика.
static func stepper_row(
	box: VBoxContainer, label_key: String, state: Dictionary, key: String, upd_ref: Dictionary
) -> Dictionary:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % key
	row.add_theme_constant_override("separation", 10)
	var lbl := label(label_key, 15)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var minus := button("−")
	minus.name = "Minus"
	var count := label("0", 17, UIColors.VALUE, HORIZONTAL_ALIGNMENT_CENTER)
	count.name = "Count"
	count.custom_minimum_size.x = 32
	var plus := button("+")
	plus.name = "Plus"
	minus.pressed.connect(
		func() -> void:
			state[key] = maxi(0, int(state[key]) - 1)
			(upd_ref["fn"] as Callable).call()
	)
	plus.pressed.connect(
		func() -> void:
			state[key] = int(state[key]) + 1
			(upd_ref["fn"] as Callable).call()
	)
	row.add_child(minus)
	row.add_child(count)
	row.add_child(plus)
	box.add_child(row)
	return {"count": count, "plus": plus, "minus": minus}


static func separator(parent: Control, color: Color = MODAL_LINE_COLOR) -> void:
	var sep := HSeparator.new()
	sep.name = "Separator"
	style_separator(sep, color)
	parent.add_child(sep)


## Применяет цвет к существующему HSeparator (например, объявленному в .tscn).
static func style_separator(sep: HSeparator, color: Color = MODAL_LINE_COLOR) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_content_margin_all(0)
	sep.add_theme_stylebox_override("separator", style)


# ── Модальное окно ─────────────────────────────────────────────────────────────


## Создаёт модальное окно: затемнение + панель с заголовком.
## content_builder(vbox: VBoxContainer) вызывается для наполнения контента.
## Возвращает корневой ColorRect — вызови queue_free() чтобы закрыть.
static func modal(
	parent: Control,
	title: String,
	content_builder: Callable,
	min_width: int = 440,
) -> ColorRect:
	var backdrop := ColorRect.new()
	backdrop.name = "ModalBackdrop"
	backdrop.color = Color(0, 0, 0, 0.6)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(backdrop)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.add_child(center)

	var p := PanelContainer.new()
	style_modal_panel(p)
	p.name = "Panel"
	p.custom_minimum_size.x = min_width
	center.add_child(p)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 12)
	p.add_child(vbox)

	# Шапка с центрированным заголовком и крестиком, который закрывает окно.
	vbox.add_child(modal_header(title, backdrop.queue_free))
	separator(vbox)

	content_builder.call(vbox)
	scale_modal_text(vbox)  # текст модалок крупнее (×1.5)

	return backdrop


# ── Оверлей переподключения ────────────────────────────────────────────────────


## Создаёт полупрозрачный оверлей с текстом и добавляет его в parent.
## Возвращает ColorRect оверлея.
static func reconnect_overlay(parent: Control, text: String) -> ColorRect:
	var overlay := ColorRect.new()
	overlay.name = "ReconnectOverlay"
	overlay.color = Color(0.0, 0.0, 0.0, 0.75)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	var lbl := Label.new()
	lbl.name = "Message"
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", UIColors.WARNING)
	overlay.add_child(lbl)

	parent.add_child(overlay)
	return overlay


# ── Рунный «скрэмбл» (эффект дешифровки при смене значения) ────────────────────

## Эффект «дешифровки»: на месте текста пробегает несколько кадров случайных
## ктулху-рун (шрифт CTHUR), затем проявляется final_text. Используется при смене
## сыщика в лобби (атрибуты) и при смене номера раунда в орбе на карте.
const RUNE_FONT: Font = preload("res://assets/fonts/CTHUR___.TTF")
const _SCRAMBLE_STEPS: int = 8  # сколько кадров мелькнёт
const _SCRAMBLE_STEP_TIME: float = 0.08  # базовая длительность одного кадра
# ± доля к длительности кадра, СВОЯ на каждый кадр. Разбивает такт, чтобы одновременные
# скрэмблы (напр. фаза + имя в game panel) мигали вразнобой, а не синхронно. Держим
# max total (_STEPS × _STEP_TIME × (1+jitter)) ниже, чем тест ждёт завершения (1.2с).
const _SCRAMBLE_JITTER: float = 0.4


## Запускает скрэмбл на лейбле к final_text (rune_count рун в кадре). Прерываем:
## повторный вызов убивает старый tween. Шрифт рун накладывается временным
## override "font"; в финале ВОССТАНАВЛИВАЕМ исходный override (если был — напр.
## жирный FontVariation), иначе просто снимаем — поэтому эффект не ломает жирность.
static func rune_scramble(lbl: Label, final_text: String, rune_count: int = 1) -> void:
	if not is_instance_valid(lbl):
		return
	var interrupted: bool = false
	if lbl.has_meta("__scramble_tw"):
		var prev: Variant = lbl.get_meta("__scramble_tw")
		if prev and (prev as Tween).is_valid():
			(prev as Tween).kill()
			interrupted = true
	# Исходный font-override (Font или null) — вернём его в финале. ВАЖНО: если прошлый
	# скрэмбл прерван, на лейбле СЕЙЧАС рунный шрифт — захватывать его нельзя, иначе
	# финал «восстановит» руны (значение так и не проявится). Поэтому при прерывании
	# берём сохранённый base из меты; иначе (settled) фиксируем текущий override.
	# Оборачиваем в массив — чтобы null-override не путался с отсутствием меты.
	var base_font: Variant
	if interrupted and lbl.has_meta("__scramble_base"):
		base_font = (lbl.get_meta("__scramble_base") as Array)[0]
	else:
		base_font = lbl.get("theme_override_fonts/font")
		lbl.set_meta("__scramble_base", [base_font])
	var tw := lbl.create_tween()
	for i in range(_SCRAMBLE_STEPS):
		tw.tween_callback(
			func() -> void:
				lbl.add_theme_font_override("font", RUNE_FONT)
				lbl.text = _random_runes(rune_count)
		)
		tw.tween_interval(
			_SCRAMBLE_STEP_TIME * randf_range(1.0 - _SCRAMBLE_JITTER, 1.0 + _SCRAMBLE_JITTER)
		)
	tw.tween_callback(
		func() -> void:
			if base_font != null:
				lbl.add_theme_font_override("font", base_font)
			else:
				lbl.remove_theme_font_override("font")
			lbl.text = final_text
	)
	lbl.set_meta("__scramble_tw", tw)


## Строка из count случайных строчных букв a–z → в шрифте CTHUR это глифы рун.
## (Глифы рун там только на строчных; заглавные A–Z в шрифте отсутствуют.)
static func _random_runes(count: int) -> String:
	var s := ""
	for i in range(count):
		s += char(randi_range(97, 122))
	return s


# ── Внутренние ────────────────────────────────────────────────────────────────


static func _btn_style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(5)
	s.set_content_margin_all(10)
	return s
