extends CanvasLayer

## Игровая консоль для отладки.
## Открывается/закрывается клавишей ~ (backtick/tilde).
##
## Использование из любого скрипта:
##   GameConsole.log("сообщение")
##   GameConsole.warn("предупреждение")
##   GameConsole.err("ошибка")

const MAX_ENTRIES  := 300
const FONT_SIZE    := 24
const HEADER_SIZE  := 20

var _shown:  bool              = false
var _root:   Control           = null
var _panel:  PanelContainer    = null
var _scroll: ScrollContainer   = null
var _log_box: VBoxContainer    = null
var _tween:  Tween             = null

# ── Публичный API ─────────────────────────────────────────────────────────────

func log(msg: String) -> void:
	_add_entry("[%s]  %s" % [_ts(), msg], Color(0.82, 0.82, 0.82))


func warn(msg: String) -> void:
	_add_entry("[%s]  ⚠ %s" % [_ts(), msg], Color(0.95, 0.82, 0.22))


func err(msg: String) -> void:
	_add_entry("[%s]  ✖ %s" % [_ts(), msg], Color(0.92, 0.28, 0.28))


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 100
	_build_ui()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed \
			and not (event as InputEventKey).echo:
		if (event as InputEventKey).keycode == KEY_QUOTELEFT:
			_toggle()
			get_viewport().set_input_as_handled()


# ── Построение UI ─────────────────────────────────────────────────────────────

func _build_ui() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	add_child(_root)

	# Панель: нижние 30% экрана, начальные смещения = 0
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.anchor_left   = 0.0
	_panel.anchor_right  = 1.0
	_panel.anchor_top    = 0.70
	_panel.anchor_bottom = 1.0
	_panel.offset_left   = 0
	_panel.offset_right  = 0
	_panel.offset_top    = 0
	_panel.offset_bottom = 0
	_panel.mouse_filter  = Control.MOUSE_FILTER_STOP

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.03, 0.08, 0.88)
	style.border_color = Color(0.30, 0.24, 0.50, 0.70)
	style.set_border_width_all(1)
	style.set_corner_radius_all(0)
	style.content_margin_left   = 14
	style.content_margin_right  = 14
	style.content_margin_top    = 8
	style.content_margin_bottom = 8
	_panel.add_theme_stylebox_override("panel", style)
	_root.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.name = "VBox"
	vbox.add_theme_constant_override("separation", 6)
	_panel.add_child(vbox)

	var header := Label.new()
	header.name = "Header"
	header.text = "CONSOLE_HEADER"
	header.add_theme_font_size_override("font_size", HEADER_SIZE)
	header.add_theme_color_override("font_color", Color(0.45, 0.40, 0.65))
	vbox.add_child(header)

	var sep := HSeparator.new()
	sep.name = "Sep"
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color(0.30, 0.24, 0.50, 0.35)
	sep_style.content_margin_top    = 0
	sep_style.content_margin_bottom = 0
	sep.add_theme_stylebox_override("separator", sep_style)
	vbox.add_child(sep)

	_scroll = ScrollContainer.new()
	_scroll.name = "Scroll"
	_scroll.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_AUTO
	vbox.add_child(_scroll)

	_log_box = VBoxContainer.new()
	_log_box.name = "LogBox"
	_log_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_box.add_theme_constant_override("separation", 2)
	_scroll.add_child(_log_box)


# ── Анимация ──────────────────────────────────────────────────────────────────

func _toggle() -> void:
	_shown = not _shown
	if _tween and _tween.is_valid():
		_tween.kill()

	var panel_h: float = get_viewport().get_visible_rect().size.y * 0.30

	if _shown:
		# Сдвигаем панель вниз за экран перед показом
		_panel.offset_top    = panel_h
		_panel.offset_bottom = panel_h
		_root.visible = true

		_tween = create_tween()
		_tween.set_ease(Tween.EASE_OUT)
		_tween.set_trans(Tween.TRANS_QUART)
		_tween.tween_property(_panel, "offset_top",    0.0, 0.28)
		_tween.parallel().tween_property(_panel, "offset_bottom", 0.0, 0.28)
		_scroll_bottom_deferred()
	else:
		_tween = create_tween()
		_tween.set_ease(Tween.EASE_IN)
		_tween.set_trans(Tween.TRANS_QUART)
		_tween.tween_property(_panel, "offset_top",    panel_h, 0.22)
		_tween.parallel().tween_property(_panel, "offset_bottom", panel_h, 0.22)
		_tween.tween_callback(func() -> void: _root.visible = false)


# ── Логика ────────────────────────────────────────────────────────────────────

func _add_entry(text: String, color: Color) -> void:
	if _log_box.get_child_count() >= MAX_ENTRIES:
		_log_box.get_child(0).free()

	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", FONT_SIZE)
	lbl.add_theme_color_override("font_color", color)
	lbl.autowrap_mode = TextServer.AUTOWRAP_OFF
	_log_box.add_child(lbl)

	if _shown:
		_scroll_bottom_deferred()


func _scroll_bottom_deferred() -> void:
	await get_tree().process_frame
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _ts() -> String:
	return Time.get_time_string_from_system()
