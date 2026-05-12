extends CanvasLayer

## Многосекционная дебаг-панель шейдеров. Ctrl+M открывает/закрывает.
## Все слайдеры, секции, кнопка «Сбросить» строятся из массива _specs ниже —
## чтобы добавить новый параметр шейдера достаточно дописать одну запись.
## Изменения не сохраняются в settings.cfg — это инструмент тонкой настройки.
##
## Спека параметра:
##   {"section": "ИМЯ"}                              — заголовок новой секции
##   {"key": ..., "label": ..., "min": ..., "max": ...,
##    "step": ..., "default": ..., "set": Callable}  — слайдер

@onready var _root: Control       = $Root
@onready var _vbox: VBoxContainer = %VBox

# Кэш: key -> {slider: HSlider, val: Label, default: float, set: Callable}.
var _rows: Dictionary = {}


# ── Спеки параметров ──────────────────────────────────────────────────────────

func _build_specs() -> Array:
	return [
		{"section": "POST FX"},
		{"key": "sepia", "label": "Сепия",
			"min": 0.0, "max": 1.0, "step": 0.01, "default": 0.22,
			"set": _set_sepia},

		{"section": "ВЫДЕЛЕНИЕ ЛОКАЦИИ"},
		{"key": "ring_r", "label": "Радиус",
			"min": 20.0, "max": 100.0, "step": 1.0,
			"default": SelectionIndicator.RING_RADIUS,
			"set": _set_ring_r},
		{"key": "ring_w", "label": "Толщина",
			"min": 0.5, "max": 15.0, "step": 0.1,
			"default": SelectionIndicator.RING_THICKNESS,
			"set": _set_ring_w},
		{"key": "glow_in", "label": "Halo внутр.",
			"min": 20.0, "max": 120.0, "step": 1.0,
			"default": SelectionIndicator.GLOW_INNER,
			"set": _set_glow_in},
		{"key": "glow_out", "label": "Halo внеш.",
			"min": 30.0, "max": 200.0, "step": 1.0,
			"default": SelectionIndicator.GLOW_OUTER,
			"set": _set_glow_out},
		{"key": "glow_str", "label": "Сила halo",
			"min": 0.0, "max": 1.5, "step": 0.01,
			"default": SelectionIndicator.GLOW_STRENGTH,
			"set": _set_glow_str},
		{"key": "glow_fall", "label": "Спад halo",
			"min": 0.5, "max": 20.0, "step": 0.1,
			"default": SelectionIndicator.GLOW_FALLOFF,
			"set": _set_glow_fall},
		{"key": "off_x", "label": "Сдвиг X",
			"min": -50.0, "max": 50.0, "step": 0.5,
			"default": SelectionIndicator.OFFSET_X,
			"set": _set_off_x},
		{"key": "off_y", "label": "Сдвиг Y",
			"min": -50.0, "max": 50.0, "step": 0.5,
			"default": SelectionIndicator.OFFSET_Y,
			"set": _set_off_y},
		{"key": "pulse_spd", "label": "Пульс скор.",
			"min": 0.0, "max": 12.0, "step": 0.1,
			"default": SelectionIndicator.PULSE_SPEED,
			"set": _set_pulse_speed},
		{"key": "pulse_amt", "label": "Пульс размах",
			"min": 0.0, "max": 0.30, "step": 0.01,
			"default": SelectionIndicator.PULSE_AMOUNT,
			"set": _set_pulse_amount},
	]


# ── Жизненный цикл ────────────────────────────────────────────────────────────

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root.visible = false
	UIStyle.style_panel(%Panel, 12)
	_build_ui()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_M and k.ctrl_pressed:
			_root.visible = not _root.visible
			get_viewport().set_input_as_handled()


# ── Построение UI ─────────────────────────────────────────────────────────────

func _build_ui() -> void:
	_add_title("  SHADER DEBUG  ·  Ctrl+M")
	for spec: Dictionary in _build_specs():
		if spec.has("section"):
			_add_section(String(spec.section))
		else:
			_add_row(spec)
	_add_reset_button()


func _add_title(text: String) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 13)
	lbl.add_theme_color_override("font_color", UIColors.ACCENT)
	_vbox.add_child(lbl)


func _add_section(title: String) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	_vbox.add_child(spacer)
	var lbl := Label.new()
	lbl.text = title
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", UIColors.WARNING)
	_vbox.add_child(lbl)


func _add_row(spec: Dictionary) -> void:
	var key:     String   = String(spec.key)
	var min_v:   float    = float(spec.min)
	var max_v:   float    = float(spec.max)
	var step:   float     = float(spec.step)
	var init_v: float     = float(spec.default)
	var setter: Callable  = spec.set as Callable

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var lbl := Label.new()
	lbl.text = String(spec.label)
	lbl.custom_minimum_size = Vector2(86, 0)
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)

	var sl := HSlider.new()
	sl.min_value = min_v
	sl.max_value = max_v
	sl.step      = step
	sl.value     = init_v
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	row.add_child(sl)

	var val := Label.new()
	val.text = _fmt(init_v, step)
	val.custom_minimum_size = Vector2(44, 0)
	val.add_theme_font_size_override("font_size", 11)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val)

	_vbox.add_child(row)
	_rows[key] = {"slider": sl, "val": val, "default": init_v, "set": setter, "step": step}

	# Применяем дефолт сразу — на случай если константы расходятся с тем, что
	# уже выставлено в материале.
	setter.call(init_v)
	sl.value_changed.connect(func(v: float) -> void:
		setter.call(v)
		val.text = _fmt(v, step)
	)


func _add_reset_button() -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	_vbox.add_child(spacer)
	var btn := Button.new()
	btn.text = "BTN_RESET"
	UIStyle.style_button(btn, UIColors.WARNING)
	btn.pressed.connect(_on_reset)
	_vbox.add_child(btn)


func _on_reset() -> void:
	for key: String in _rows:
		var r: Dictionary = _rows[key]
		var sl: HSlider   = r.slider
		sl.value          = r.default   # триггерит value_changed → setter + val.text


func _fmt(v: float, step: float) -> String:
	if step >= 1.0:
		return "%d" % int(round(v))
	return "%.2f" % v


# ── Setters: один на параметр ─────────────────────────────────────────────────

func _post_fx_mat() -> ShaderMaterial:
	var overlay: ColorRect = PostFx.get_node("Overlay") as ColorRect
	return overlay.material as ShaderMaterial


func _sel_mat() -> ShaderMaterial:
	return SelectionIndicator.get_shared_material()


func _set_sepia(v: float) -> void:
	var m := _post_fx_mat()
	if m: m.set_shader_parameter("sepia_amount", v)


func _set_ring_r(v: float) -> void:
	_sel_mat().set_shader_parameter("ring_r", v)


func _set_ring_w(v: float) -> void:
	_sel_mat().set_shader_parameter("ring_w", v)


func _set_glow_in(v: float) -> void:
	_sel_mat().set_shader_parameter("glow_inner", v)


func _set_glow_out(v: float) -> void:
	_sel_mat().set_shader_parameter("glow_outer", v)


func _set_glow_str(v: float) -> void:
	_sel_mat().set_shader_parameter("glow_strength", v)


func _set_glow_fall(v: float) -> void:
	_sel_mat().set_shader_parameter("glow_falloff", v)


func _set_off_x(v: float) -> void:
	var off := SelectionIndicator.get_offset()
	SelectionIndicator.set_offset(v, off.y)


func _set_off_y(v: float) -> void:
	var off := SelectionIndicator.get_offset()
	SelectionIndicator.set_offset(off.x, v)


func _set_pulse_speed(v: float) -> void:
	SelectionIndicator.set_pulse(v, SelectionIndicator.get_pulse_amount())


func _set_pulse_amount(v: float) -> void:
	SelectionIndicator.set_pulse(SelectionIndicator.get_pulse_speed(), v)
