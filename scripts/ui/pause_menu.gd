extends CanvasLayer

## Меню паузы — открывается/закрывается по Escape в игровых сценах.
## Autoload-синглтон: /root/PauseMenu

const SETTINGS_FILE := "user://settings.cfg"

const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280,  720),
	Vector2i(1600,  900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]

# ── Состояние ─────────────────────────────────────────────────────────────────

var _open:        bool = false
var _main_panel:  Control = null
var _sett_panel:  Control = null

var _fullscreen:  bool         = false
var _res_idx:     int          = 2        # 1920 × 1080
var _res_option:  OptionButton = null
var _fs_check:    CheckBox     = null


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer   = 100
	visible = false
	_load_settings()
	_build_ui()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	# Не открываем на экране логина и главного меню
	var scene := get_tree().current_scene
	if not is_instance_valid(scene):
		return
	var path: String = scene.scene_file_path
	if "login" in path or "main_menu" in path:
		return
	_toggle()
	get_viewport().set_input_as_handled()


# ── Построение UI ─────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Корневой Control — даёт якорную точку для всех дочерних нод
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Backdrop — блокирует клики к игровой сцене снизу
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.65)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(backdrop)

	# Единственный CenterContainer — брат backdrop, не его дочерний элемент.
	# Оба дочерних панели в нём: одна видима, другая скрыта.
	# mouse_filter = PASS чтобы клики доходили до кнопок внутри панелей.
	var cc := CenterContainer.new()
	cc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_PASS
	root.add_child(cc)

	_main_panel = _build_main_panel()
	_sett_panel = _build_sett_panel()
	cc.add_child(_main_panel)
	cc.add_child(_sett_panel)


func _build_main_panel() -> Control:
	var p := UIStyle.panel(28)
	p.custom_minimum_size = Vector2(320, 0)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	p.add_child(vbox)

	var title := Label.new()
	title.text = "  ПАУЗА"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", UIColors.ACCENT)
	vbox.add_child(title)

	UIStyle.separator(vbox)

	var continue_btn := UIStyle.button("▶   ПРОДОЛЖИТЬ")
	continue_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	continue_btn.pressed.connect(_toggle)
	vbox.add_child(continue_btn)

	var settings_btn := UIStyle.button("⚙   НАСТРОЙКИ")
	settings_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_btn.pressed.connect(_show_settings)
	vbox.add_child(settings_btn)

	UIStyle.separator(vbox)

	var menu_btn := UIStyle.button("⌂   ГЛАВНОЕ МЕНЮ", UIColors.WARNING)
	menu_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu_btn.pressed.connect(_go_main_menu)
	vbox.add_child(menu_btn)

	var quit_btn := UIStyle.button("✕   ВЫЙТИ ИЗ ИГРЫ", UIColors.DANGER)
	quit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quit_btn.pressed.connect(_quit_game)
	vbox.add_child(quit_btn)

	return p


func _build_sett_panel() -> Control:
	var p := UIStyle.panel(24)
	p.custom_minimum_size = Vector2(360, 0)
	p.visible = false

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	p.add_child(vbox)

	var title := Label.new()
	title.text = "  НАСТРОЙКИ"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", UIColors.ACCENT)
	vbox.add_child(title)

	UIStyle.separator(vbox)

	# ── Дисплей ──
	var disp_lbl := Label.new()
	disp_lbl.text = "ДИСПЛЕЙ"
	disp_lbl.add_theme_font_size_override("font_size", 11)
	disp_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	vbox.add_child(disp_lbl)

	var res_row := HBoxContainer.new()
	res_row.add_theme_constant_override("separation", 8)
	vbox.add_child(res_row)

	var res_lbl := Label.new()
	res_lbl.text = "Разрешение:"
	res_lbl.custom_minimum_size.x = 110
	res_lbl.add_theme_font_size_override("font_size", 14)
	res_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	res_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	res_row.add_child(res_lbl)

	var res_names: Array[String] = []
	for r: Vector2i in RESOLUTIONS:
		res_names.append("%d × %d" % [r.x, r.y])
	_res_option = UIStyle.option_button(res_names)
	_res_option.selected = _res_idx
	_res_option.disabled = _fullscreen
	_res_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	res_row.add_child(_res_option)

	var fs_row := HBoxContainer.new()
	fs_row.add_theme_constant_override("separation", 10)
	vbox.add_child(fs_row)

	_fs_check = CheckBox.new()
	_fs_check.button_pressed = _fullscreen
	_fs_check.add_theme_color_override("font_color", UIColors.TEXT)
	_fs_check.add_theme_font_size_override("font_size", 14)
	_fs_check.toggled.connect(func(on: bool) -> void: _res_option.disabled = on)
	fs_row.add_child(_fs_check)

	var fs_lbl := Label.new()
	fs_lbl.text = "Полный экран"
	fs_lbl.add_theme_font_size_override("font_size", 14)
	fs_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	fs_row.add_child(fs_lbl)

	UIStyle.separator(vbox)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	vbox.add_child(btns)

	var save_btn := UIStyle.button("СОХРАНИТЬ", UIColors.ACCENT)
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_save_and_back)
	btns.add_child(save_btn)

	var back_btn := UIStyle.button("ОТМЕНА", UIColors.MUTED)
	back_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back_btn.pressed.connect(_show_main)
	btns.add_child(back_btn)

	return p


# ── Логика переключения ───────────────────────────────────────────────────────

func _toggle() -> void:
	_open = not _open
	visible = _open
	if _open:
		_show_main()


func _show_main() -> void:
	_main_panel.visible = true
	_sett_panel.visible = false


func _show_settings() -> void:
	# Синхронизируем UI с текущими сохранёнными значениями
	_res_option.selected     = _res_idx
	_res_option.disabled     = _fullscreen
	_fs_check.button_pressed = _fullscreen
	_main_panel.visible = false
	_sett_panel.visible = true


func _save_and_back() -> void:
	_res_idx    = _res_option.selected
	_fullscreen = _fs_check.button_pressed
	_save_settings()
	_apply_display()
	_show_main()


func _go_main_menu() -> void:
	_open   = false
	visible = false
	var nm: Node = get_node_or_null("/root/NetworkManager")
	if nm:
		(nm as Node).call("leave_room")
	SceneManager.go("main_menu")


func _quit_game() -> void:
	get_tree().quit()


# ── Настройки: загрузка / сохранение / применение ────────────────────────────

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) != OK:
		return
	_fullscreen = cfg.get_value("display", "fullscreen", false)
	var res_str: String = cfg.get_value("display", "resolution", "1920x1080")
	for i: int in range(RESOLUTIONS.size()):
		var r: Vector2i = RESOLUTIONS[i]
		if "%dx%d" % [r.x, r.y] == res_str:
			_res_idx = i
			return


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_FILE)   # ок если файла нет
	cfg.set_value("display", "fullscreen", _fullscreen)
	var r: Vector2i = RESOLUTIONS[_res_idx]
	cfg.set_value("display", "resolution", "%dx%d" % [r.x, r.y])
	cfg.save(SETTINGS_FILE)


func _apply_display() -> void:
	if _fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(RESOLUTIONS[_res_idx])
		DisplayServer.window_set_position(
			DisplayServer.screen_get_position() +
			(DisplayServer.screen_get_size() - RESOLUTIONS[_res_idx]) / 2
		)
