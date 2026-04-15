## Общие стили и фабричные методы для UI Dark Omens.
## Используется как UIStyle.button(...), UIStyle.GOLD и т.д. — без autoload.
class_name UIStyle

# ── Палитра ────────────────────────────────────────────────────────────────────
const BG     := Color(0.05, 0.04, 0.10)
const PANEL  := Color(0.08, 0.07, 0.15)
const BORDER := Color(0.35, 0.25, 0.10)
const GOLD   := Color(0.78, 0.66, 0.29)
const RED    := Color(0.55, 0.10, 0.10)
const TEXT   := Color(0.85, 0.82, 0.75)
const DIM    := Color(0.55, 0.52, 0.45)
const ERROR  := Color(0.90, 0.25, 0.20)
const OK     := Color(0.30, 0.80, 0.40)
const WARN   := Color(0.90, 0.75, 0.20)
const GREEN  := Color(0.20, 0.70, 0.35)


# ── Фон сцены ──────────────────────────────────────────────────────────────────

## Добавляет тёмный фон на всю область родительского контрола.
static func apply_bg(control: Control) -> void:
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	control.add_child(bg)


# ── Кнопка ─────────────────────────────────────────────────────────────────────

## Создаёт стилизованную кнопку.
## border_color задаёт цвет рамки в нормальном состоянии.
static func button(label: String, border_color: Color = BORDER) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.add_theme_stylebox_override("normal",   _btn_style(Color(0.12, 0.10, 0.20), border_color))
	btn.add_theme_stylebox_override("hover",    _btn_style(Color(0.20, 0.16, 0.30), GOLD))
	btn.add_theme_stylebox_override("pressed",  _btn_style(Color(0.08, 0.06, 0.14), RED))
	btn.add_theme_stylebox_override("disabled", _btn_style(Color(0.08, 0.07, 0.12), DIM))
	btn.add_theme_color_override("font_color",          GOLD)
	btn.add_theme_color_override("font_hover_color",    Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", DIM)
	btn.add_theme_font_size_override("font_size", 15)
	return btn


# ── Панель ─────────────────────────────────────────────────────────────────────

## Создаёт PanelContainer с тёмным фоном и золотой рамкой.
static func panel(padding: int = 16) -> PanelContainer:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(padding)
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", style)
	return p


# ── Поле ввода ─────────────────────────────────────────────────────────────────

## Создаёт стилизованный LineEdit.
static func input(placeholder: String = "", secret: bool = false) -> LineEdit:
	var style_n := StyleBoxFlat.new()
	style_n.bg_color = Color(0.10, 0.09, 0.18)
	style_n.border_color = BORDER
	style_n.set_border_width_all(1)
	style_n.set_corner_radius_all(4)
	style_n.set_content_margin_all(8)

	var style_f := StyleBoxFlat.new()
	style_f.bg_color = Color(0.12, 0.11, 0.22)
	style_f.border_color = GOLD
	style_f.set_border_width_all(1)
	style_f.set_corner_radius_all(4)
	style_f.set_content_margin_all(8)

	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.secret = secret
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.add_theme_stylebox_override("normal", style_n)
	le.add_theme_stylebox_override("focus",  style_f)
	le.add_theme_color_override("font_color",             TEXT)
	le.add_theme_color_override("font_placeholder_color", DIM)
	le.add_theme_font_size_override("font_size", 14)
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
	lbl.add_theme_color_override("font_color", TEXT)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(lbl)

	var le := input(placeholder, secret)
	hbox.add_child(le)

	return [hbox, le]


# ── Разделитель ────────────────────────────────────────────────────────────────

## Создаёт горизонтальный разделитель и добавляет его в parent.
static func separator(parent: Control, color: Color = BORDER) -> void:
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
	hdr.add_theme_color_override("font_color", GOLD)
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
	lbl.add_theme_color_override("font_color", WARN)
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
