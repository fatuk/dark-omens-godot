extends Control

## Титульный экран Dark Omens — стартовая сцена игры (main_scene).
##
## Фон main-bg.png, логотип сверху по центру, меню Play/Authors/Settings/Quit,
## версия игры мелким шрифтом внизу слева.
##
## Разметка статики — в scenes/home.tscn, здесь поведение и стилизация.

const _SETTINGS_DIALOG := preload("res://scenes/ui/settings_dialog.tscn")

# ── Узлы ──────────────────────────────────────────────────────────────────────
@onready var _play_btn:     Button = %PlayBtn
@onready var _authors_btn:  Button = %AuthorsBtn
@onready var _settings_btn: Button = %SettingsBtn
@onready var _quit_btn:     Button = %QuitBtn
@onready var _version_lbl:  Label  = %VersionLabel

# ── Состояние ─────────────────────────────────────────────────────────────────
var _settings_dialog: Control = null
var _authors_modal:   Control = null


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	MusicManager.play(MusicManager.TRACK_ELDER_SIGN)
	_apply_styles()

	_play_btn.pressed.connect(_on_play_pressed)
	_authors_btn.pressed.connect(_on_authors_pressed)
	_settings_btn.pressed.connect(_on_settings_pressed)
	_quit_btn.pressed.connect(_on_quit_pressed)

	_play_btn.grab_focus()


# ── Стили ─────────────────────────────────────────────────────────────────────

func _apply_styles() -> void:
	UIStyle.style_button(_play_btn)
	UIStyle.style_button(_authors_btn)
	UIStyle.style_button(_settings_btn)
	UIStyle.style_button(_quit_btn)

	_version_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	_version_lbl.text = _version_text()


## Версия берётся из настроек проекта (application/config/version).
func _version_text() -> String:
	var v: String = str(ProjectSettings.get_setting("application/config/version", ""))
	return "v%s" % v if not v.is_empty() else ""


# ── Обработчики кнопок ─────────────────────────────────────────────────────────

func _on_play_pressed() -> void:
	# login сам проверит сохранённую сессию и перекинет к экрану комнат.
	SceneManager.go("login")


func _on_settings_pressed() -> void:
	if is_instance_valid(_settings_dialog):
		# Повторный клик по «Настройки» — отмена (откат live-preview + закрытие).
		_settings_dialog.call("_on_cancel")
		return
	_settings_dialog = _SETTINGS_DIALOG.instantiate()
	_settings_dialog.show_server_url = true
	add_child(_settings_dialog)
	_settings_dialog.tree_exited.connect(func() -> void: _settings_dialog = null)


func _on_quit_pressed() -> void:
	get_tree().quit()


# ── Модальное окно «Авторы» ───────────────────────────────────────────────────

func _on_authors_pressed() -> void:
	if is_instance_valid(_authors_modal):
		return
	_authors_modal = UIStyle.modal(self, "HOME_AUTHORS_TITLE", _build_authors_content)


func _build_authors_content(vbox: VBoxContainer) -> void:
	var body := Label.new()
	body.name = "Body"
	body.text = "HOME_AUTHORS_BODY"
	body.custom_minimum_size.x = 400
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 14)
	body.add_theme_color_override("font_color", UIColors.TEXT)
	vbox.add_child(body)
	# Закрытие — крестиком в шапке (см. UIStyle.modal).
