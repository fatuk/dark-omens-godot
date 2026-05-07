## Фабричные методы для UI Dark Omens.
## Цвета — в UIColors. Используй UIColors.ACCENT, UIColors.DANGER и т.д.
class_name UIStyle


# ── Фон сцены ──────────────────────────────────────────────────────────────────

## Добавляет тёмный фон на всю область родительского контрола.
static func apply_bg(control: Control) -> void:
	var bg := ColorRect.new()
	bg.color = UIColors.BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	control.add_child(bg)


# ── Кнопка ─────────────────────────────────────────────────────────────────────

## Применяет стили Dark Omens к существующей кнопке (например из .tscn).
static func style_button(btn: Button, border_color: Color = UIColors.BORDER) -> void:
	btn.add_theme_stylebox_override("normal",   _btn_style(Color(0.12, 0.10, 0.20), border_color))
	btn.add_theme_stylebox_override("hover",    _btn_style(Color(0.20, 0.16, 0.30), UIColors.ACCENT))
	btn.add_theme_stylebox_override("pressed",  _btn_style(Color(0.08, 0.06, 0.14), UIColors.DANGER))
	btn.add_theme_stylebox_override("disabled", _btn_style(Color(0.08, 0.07, 0.12), UIColors.MUTED))
	btn.add_theme_color_override("font_color",          UIColors.ACCENT)
	btn.add_theme_color_override("font_hover_color",    Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", UIColors.MUTED)
	btn.add_theme_font_size_override("font_size", 15)

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
	hdr.text = "  " + title
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
