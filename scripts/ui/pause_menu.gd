extends CanvasLayer

## Меню паузы — открывается/закрывается по Escape в игровых сценах.
## Autoload-синглтон: /root/PauseMenu (см. project.godot).
## Разметка в scenes/ui/pause_menu.tscn, тут только поведение и стилизация.

const SETTINGS_FILE := "user://settings.cfg"

const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280,  720),
	Vector2i(1600,  900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]

# ── Узлы (через unique_name_in_owner) ──────────────────────────────────────────
@onready var _backdrop:    ColorRect      = $Root/Backdrop
@onready var _main_panel:  PanelContainer = %MainPanel
@onready var _sett_panel:  PanelContainer = %SettPanel

@onready var _continue_btn: Button = %ContinueBtn
@onready var _settings_btn: Button = %SettingsBtn
@onready var _menu_btn:     Button = %MenuBtn
@onready var _quit_btn:     Button = %QuitBtn

@onready var _res_option: OptionButton = %ResOption
@onready var _fs_check:   CheckBox     = %FsCheck
@onready var _fx_check:   CheckBox     = %FxCheck
@onready var _save_btn:   Button       = %SaveBtn
@onready var _back_btn:   Button       = %BackBtn

# ── Состояние ─────────────────────────────────────────────────────────────────
var _open:       bool = false
var _fullscreen: bool = false
var _res_idx:    int  = 2     # индекс в RESOLUTIONS — дефолт 1920×1080


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_load_settings()
	_apply_styles()
	_populate_resolutions()
	_wire_handlers()


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


# ── Применение Dark Omens-стилей к нодам из .tscn ─────────────────────────────

func _apply_styles() -> void:
	UIStyle.style_panel(_main_panel, 28)
	UIStyle.style_panel(_sett_panel, 24)

	# Заголовки панелей
	for title_path in [
		"Root/Center/MainPanel/VBox/Title",
		"Root/Center/SettPanel/VBox/Title",
	]:
		(get_node(title_path) as Label).add_theme_color_override("font_color", UIColors.ACCENT)

	# Подзаголовок «ДИСПЛЕЙ»
	(get_node("Root/Center/SettPanel/VBox/DispLabel") as Label) \
		.add_theme_color_override("font_color", UIColors.MUTED)

	# Лейблы строк настроек
	for path in [
		"Root/Center/SettPanel/VBox/ResRow/ResLabel",
		"Root/Center/SettPanel/VBox/FsRow/FsLabel",
	]:
		(get_node(path) as Label).add_theme_color_override("font_color", UIColors.TEXT)

	_fs_check.add_theme_color_override("font_color", UIColors.TEXT)
	_fx_check.add_theme_color_override("font_color", UIColors.TEXT)
	(get_node("Root/Center/SettPanel/VBox/FxRow/FxLabel") as Label) \
		.add_theme_color_override("font_color", UIColors.TEXT)

	UIStyle.style_option_button(_res_option)

	UIStyle.style_button(_continue_btn)
	UIStyle.style_button(_settings_btn)
	UIStyle.style_button(_menu_btn,  UIColors.WARNING)
	UIStyle.style_button(_quit_btn,  UIColors.DANGER)
	UIStyle.style_button(_save_btn,  UIColors.ACCENT)
	UIStyle.style_button(_back_btn,  UIColors.MUTED)


func _populate_resolutions() -> void:
	_res_option.clear()
	for r: Vector2i in RESOLUTIONS:
		_res_option.add_item("%d × %d" % [r.x, r.y])
	_res_option.selected = _res_idx
	_res_option.disabled = _fullscreen
	_fs_check.button_pressed = _fullscreen
	_fx_check.button_pressed = PostFx.is_enabled()


func _wire_handlers() -> void:
	_continue_btn.pressed.connect(_toggle)
	_settings_btn.pressed.connect(_show_settings)
	_menu_btn.pressed.connect(_go_main_menu)
	_quit_btn.pressed.connect(_quit_game)
	_save_btn.pressed.connect(_save_and_back)
	_back_btn.pressed.connect(_show_main)
	_fs_check.toggled.connect(func(on: bool) -> void: _res_option.disabled = on)


# ── Логика переключения ───────────────────────────────────────────────────────

func _toggle() -> void:
	_open = not _open
	visible = _open
	get_tree().paused = _open
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
	PostFx.set_enabled(_fx_check.button_pressed)
	_show_main()


func _go_main_menu() -> void:
	_open   = false
	visible = false
	get_tree().paused = false
	var nm: Node = get_node_or_null("/root/NetworkManager")
	if nm:
		(nm as Node).call("leave_room")
	SceneManager.go("main_menu")


func _quit_game() -> void:
	get_tree().paused = false
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


@warning_ignore("integer_division")
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
