extends CanvasLayer

## Меню паузы — открывается/закрывается по Escape на любой сцене (включая
## login и main_menu — иначе оттуда нельзя выйти из игры).
## Autoload-синглтон: /root/PauseMenu (см. project.godot).
## Разметка в scenes/ui/pause_menu.tscn, тут только поведение и стилизация.
##
## Settings — переиспользует общий SettingsDialog (тот же, что в main_menu).
##
## Если на сцене открыт диалог (settings_dialog / create_room_dialog), его
## _unhandled_key_input проглатывает Escape РАНЬШЕ нашего _unhandled_input
## (в Godot 4 _unhandled_key_input идёт первым) — так что pause-меню поверх
## модалок не выскакивает.

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
	if _open:
		_update_buttons_for_current_scene()
	visible = _open
	get_tree().paused = _open


# Прячет неприменимые кнопки: на login / main_menu / home игры ещё/уже нет —
# «Продолжить» и «В меню» бессмысленны, оставляем Settings + Quit. Закрыть
# меню на этих экранах можно повторным Escape. На lobby / world_map —
# показываем все четыре кнопки.
func _update_buttons_for_current_scene() -> void:
	var scene := get_tree().current_scene
	var path: String = scene.scene_file_path if is_instance_valid(scene) else ""
	var on_pre_game: bool = "login" in path \
		or "main_menu" in path or "home" in path
	_continue_btn.visible = not on_pre_game
	_menu_btn.visible     = not on_pre_game


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
