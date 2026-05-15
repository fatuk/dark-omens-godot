extends CanvasLayer

## Меню паузы — открывается/закрывается по Escape в игровых сценах.
## Autoload-синглтон: /root/PauseMenu (см. project.godot).
## Разметка в scenes/ui/pause_menu.tscn, тут только поведение и стилизация.
##
## Settings — переиспользует общий SettingsDialog (тот же, что в main_menu).

const _SETTINGS_DIALOG := preload("res://scenes/ui/settings_dialog.tscn")

# ── Узлы (через unique_name_in_owner) ──────────────────────────────────────────
@onready var _main_panel:  PanelContainer = %MainPanel
@onready var _continue_btn: Button = %ContinueBtn
@onready var _settings_btn: Button = %SettingsBtn
@onready var _menu_btn:     Button = %MenuBtn
@onready var _quit_btn:     Button = %QuitBtn

# ── Состояние ─────────────────────────────────────────────────────────────────
var _open:            bool    = false
var _settings_dialog: Control = null


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_apply_styles()
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


# ── Стили ─────────────────────────────────────────────────────────────────────

func _apply_styles() -> void:
	UIStyle.style_panel(_main_panel, 28)
	(get_node("Root/Center/MainPanel/VBox/Title") as Label) \
		.add_theme_color_override("font_color", UIColors.ACCENT)
	UIStyle.style_button(_continue_btn)
	UIStyle.style_button(_settings_btn)
	UIStyle.style_button(_menu_btn,  UIColors.WARNING)
	UIStyle.style_button(_quit_btn,  UIColors.DANGER)


func _wire_handlers() -> void:
	_continue_btn.pressed.connect(_toggle)
	_settings_btn.pressed.connect(_open_settings)
	_menu_btn.pressed.connect(_go_main_menu)
	_quit_btn.pressed.connect(_quit_game)


# ── Логика паузы ──────────────────────────────────────────────────────────────

func _toggle() -> void:
	_open = not _open
	visible = _open
	get_tree().paused = _open


# ── Settings (через общий SettingsDialog) ─────────────────────────────────────

func _open_settings() -> void:
	if is_instance_valid(_settings_dialog):
		return   # уже открыт
	_main_panel.visible = false
	_settings_dialog = _SETTINGS_DIALOG.instantiate()
	_settings_dialog.name = "SettingsDialog"
	_settings_dialog.show_server_url = false   # в идущей игре сервер не меняется
	$Root.add_child(_settings_dialog)
	# По обоим сигналам (saved + cancelled) поведение одно — вернуться к
	# главной панели паузы. Сам диалог делает queue_free.
	_settings_dialog.tree_exited.connect(func() -> void:
		_settings_dialog = null
		_main_panel.visible = true
	)


# ── Прочие кнопки ─────────────────────────────────────────────────────────────

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
