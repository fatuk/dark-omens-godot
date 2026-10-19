extends ColorRect

## Единый диалог настроек — используется из main_menu и pause_menu.
##
## Содержит секции: Сервер (опционально), Дисплей, Звук, Язык.
## Save → пишет в SettingsStore + применяет PostFx/I18n → эмитит `saved`.
## Cancel/повторное закрытие → откатывает live-preview громкостей →
## эмитит `cancelled`.
##
## Использование:
##   var dlg := preload("res://scenes/ui/settings_dialog.tscn").instantiate()
##   dlg.show_server_url = false   # для pause_menu
##   parent.add_child(dlg)
##   dlg.saved.connect(_on_saved)
##
## Закрытие — `queue_free()` (диалог делает это сам после Save/Cancel).

signal saved
signal cancelled

# Размеры — ступени лесенки модалок UIStyle (как у прочих окон), а не россыпь 12–14 px.
const _FS: int = UIStyle.MODAL_FS_BODY  # подписи, галки, выпадающие списки
const _FS_SECTION: int = UIStyle.MODAL_FS_HINT  # шапки секций («ДИСПЛЕЙ», «ЗВУК»)
const _LABEL_W: float = 200.0  # колонка подписей «Разрешение:», «Язык:»
const _ROW_H: float = 44.0  # высота выпадающих списков

# Сервер не показываем в pause-меню — поменять relay'я в идущей игре нельзя.
var show_server_url: bool = true

# ── UI-узлы ───────────────────────────────────────────────────────────────────
@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

var _url_input: LineEdit
var _res_option: OptionButton
var _fs_check: CheckBox
var _fx_check: CheckBox
var _turn_check: CheckBox
var _fps_check: CheckBox
var _guide_check: CheckBox
var _music_slider: HSlider
var _sfx_slider: HSlider
var _lang_option: OptionButton

# ── Snapshot live-preview значений на момент открытия (для Cancel) ────────────
var _music_snap: float = 1.0
var _sfx_snap: float = 1.0


func _ready() -> void:
	# Чтобы работало в PauseMenu (tree.paused).
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP  # клики мимо панели не падают вниз
	UIStyle.style_modal_panel(_panel)
	_music_snap = MusicManager.volume
	_sfx_snap = SfxManager.volume
	_build()


# ── Сборка контента ───────────────────────────────────────────────────────────


func _build() -> void:
	_vbox.add_child(UIStyle.modal_header("SETTINGS_TITLE", _on_cancel))
	UIStyle.separator(_vbox)

	# Поле Relay URL — только в редакторе (дев-инструмент). В релизе сервер задаётся
	# сборкой, поэтому секцию SERVER не показываем (см. SettingsStore._build_default_url).
	if show_server_url and OS.has_feature("editor"):
		_build_server_section()
		UIStyle.separator(_vbox)

	_build_display_section()
	UIStyle.separator(_vbox)

	_build_audio_section()
	UIStyle.separator(_vbox)

	_build_language_section()
	UIStyle.separator(_vbox)

	_build_buttons()


func _build_server_section() -> void:
	_section_header("SECTION_SERVER", "ServerHeader")
	var row := UIStyle.labeled_input("Relay URL:", SettingsStore.DEFAULT_URL, 90)
	_url_input = row[1] as LineEdit
	_url_input.name = "RelayInput"
	_url_input.text = SettingsStore.relay_url
	var server_row: Control = row[0]
	server_row.name = "ServerRow"
	_vbox.add_child(server_row)


func _build_display_section() -> void:
	_section_header("SECTION_DISPLAY", "DisplayHeader")

	var res_row := HBoxContainer.new()
	res_row.name = "ResolutionRow"
	res_row.add_theme_constant_override("separation", 8)
	_vbox.add_child(res_row)

	var res_lbl := _form_label("FORM_RESOLUTION")
	res_lbl.name = "ResolutionLabel"
	res_row.add_child(res_lbl)

	var res_names: Array[String] = []
	for r: Vector2i in SettingsStore.RESOLUTIONS:
		res_names.append("%d × %d" % [r.x, r.y])
	_res_option = UIStyle.option_button(res_names)
	_res_option.name = "ResolutionOption"
	_size_option(_res_option)
	_res_option.selected = SettingsStore.resolution_idx
	_res_option.disabled = SettingsStore.fullscreen
	res_row.add_child(_res_option)

	var fs_row := HBoxContainer.new()
	fs_row.name = "FullscreenRow"
	fs_row.add_theme_constant_override("separation", 10)
	_vbox.add_child(fs_row)

	_fs_check = CheckBox.new()
	_fs_check.name = "FullscreenCheck"
	_fs_check.button_pressed = SettingsStore.fullscreen
	_fs_check.add_theme_color_override("font_color", UIColors.TEXT)
	_fs_check.add_theme_font_size_override("font_size", _FS)
	_fs_check.toggled.connect(func(on: bool) -> void: _res_option.disabled = on)
	fs_row.add_child(_fs_check)
	var fs_lbl := _plain_label("SETTINGS_FULLSCREEN")
	fs_lbl.name = "FullscreenLabel"
	fs_row.add_child(fs_lbl)

	var fx_row := HBoxContainer.new()
	fx_row.name = "FxRow"
	fx_row.add_theme_constant_override("separation", 10)
	_vbox.add_child(fx_row)

	_fx_check = CheckBox.new()
	_fx_check.name = "FxCheck"
	_fx_check.button_pressed = PostFx.is_enabled()
	_fx_check.add_theme_color_override("font_color", UIColors.TEXT)
	_fx_check.add_theme_font_size_override("font_size", _FS)
	fx_row.add_child(_fx_check)
	var fx_lbl := _plain_label("SETTINGS_FX_OLD_FILM")
	fx_lbl.name = "FxLabel"
	fx_row.add_child(fx_lbl)

	var turn_row := HBoxContainer.new()
	turn_row.name = "TurnRow"
	turn_row.add_theme_constant_override("separation", 10)
	_vbox.add_child(turn_row)

	_turn_check = CheckBox.new()
	_turn_check.name = "TurnNotifyCheck"
	_turn_check.button_pressed = SettingsStore.turn_notify
	_turn_check.add_theme_color_override("font_color", UIColors.TEXT)
	_turn_check.add_theme_font_size_override("font_size", _FS)
	turn_row.add_child(_turn_check)
	var turn_lbl := _plain_label("SETTINGS_TURN_NOTIFY")
	turn_lbl.name = "TurnNotifyLabel"
	turn_row.add_child(turn_lbl)

	var fps_row := HBoxContainer.new()
	fps_row.name = "FpsRow"
	fps_row.add_theme_constant_override("separation", 10)
	_vbox.add_child(fps_row)

	_fps_check = CheckBox.new()
	_fps_check.name = "ShowFpsCheck"
	_fps_check.button_pressed = SettingsStore.show_fps
	_fps_check.add_theme_color_override("font_color", UIColors.TEXT)
	_fps_check.add_theme_font_size_override("font_size", _FS)
	fps_row.add_child(_fps_check)
	var fps_lbl := _plain_label("SETTINGS_SHOW_FPS")
	fps_lbl.name = "ShowFpsLabel"
	fps_row.add_child(fps_lbl)

	# Подсказки профессора Армитеджа: вкл/выкл + «показать заново» (сразу, без Сохранить).
	var guide_row := HBoxContainer.new()
	guide_row.name = "GuideRow"
	guide_row.add_theme_constant_override("separation", 10)
	_vbox.add_child(guide_row)

	_guide_check = CheckBox.new()
	_guide_check.name = "GuideHintsCheck"
	_guide_check.button_pressed = SettingsStore.guide_hints
	_guide_check.add_theme_color_override("font_color", UIColors.TEXT)
	_guide_check.add_theme_font_size_override("font_size", _FS)
	guide_row.add_child(_guide_check)
	var guide_lbl := _plain_label("SETTINGS_GUIDE_HINTS")
	guide_lbl.name = "GuideHintsLabel"
	guide_row.add_child(guide_lbl)

	var reset := UIStyle.button("SETTINGS_GUIDE_RESET")
	reset.name = "GuideResetBtn"
	reset.disabled = SettingsStore.guide_seen.is_empty()
	reset.pressed.connect(
		func() -> void:
			SettingsStore.reset_guide()
			reset.text = "SETTINGS_GUIDE_RESET_DONE"
			reset.disabled = true
	)
	_vbox.add_child(reset)


func _build_audio_section() -> void:
	_section_header("SECTION_AUDIO", "AudioHeader")
	_music_slider = UIStyle.volume_slider_row(
		_vbox, "SETTINGS_VOLUME_MUSIC", MusicManager.volume, MusicManager.set_volume
	)
	_music_slider.name = "MusicSlider"
	_sfx_slider = UIStyle.volume_slider_row(
		_vbox, "SETTINGS_VOLUME_SFX", SfxManager.volume, SfxManager.set_volume
	)
	_sfx_slider.name = "SfxSlider"


func _build_language_section() -> void:
	var row := HBoxContainer.new()
	row.name = "LanguageRow"
	row.add_theme_constant_override("separation", 8)
	_vbox.add_child(row)
	var lang_lbl := _form_label(tr("SETTINGS_LANGUAGE") + ":")
	lang_lbl.name = "LanguageLabel"
	row.add_child(lang_lbl)

	var lang_names: Array[String] = []
	for code: String in I18n.SUPPORTED:
		lang_names.append(tr("LANG_" + code.to_upper()))
	_lang_option = UIStyle.option_button(lang_names)
	_lang_option.name = "LanguageOption"
	_size_option(_lang_option)
	_lang_option.selected = I18n.SUPPORTED.find(I18n.get_locale())
	row.add_child(_lang_option)


func _build_buttons() -> void:
	# Cancel убран — закрытие через крестик в шапке (тоже откатывает live-preview).
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 8)
	_vbox.add_child(btns)

	var save_btn := UIStyle.button("BTN_SAVE_BIG", UIColors.ACCENT)
	save_btn.name = "SaveBtn"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_save)
	btns.add_child(save_btn)


# ── Save/Cancel ───────────────────────────────────────────────────────────────


func _on_save() -> void:
	if show_server_url and is_instance_valid(_url_input):
		SettingsStore.set_relay_url(_url_input.text)
	SettingsStore.resolution_idx = _res_option.selected
	SettingsStore.fullscreen = _fs_check.button_pressed
	SettingsStore.apply_display()

	# Громкости уже применены через live-preview; фиксируем финальное значение.
	MusicManager.set_volume(_music_slider.value)
	SfxManager.set_volume(_sfx_slider.value)

	PostFx.set_enabled(_fx_check.button_pressed)
	SettingsStore.turn_notify = _turn_check.button_pressed
	SettingsStore.show_fps = _fps_check.button_pressed
	SettingsStore.guide_hints = _guide_check.button_pressed
	FpsOverlay.set_shown(SettingsStore.show_fps)
	if _lang_option.selected >= 0:
		I18n.set_locale(I18n.SUPPORTED[_lang_option.selected])

	SettingsStore.save()
	saved.emit()
	queue_free()


func _on_cancel() -> void:
	# Откатываем live-preview громкостей. Display/lang/fx ещё не были применены.
	MusicManager.set_volume(_music_snap)
	SfxManager.set_volume(_sfx_snap)
	cancelled.emit()
	queue_free()


# ── Хелперы ───────────────────────────────────────────────────────────────────


func _section_header(key: String, node_name: String = "") -> void:
	var lbl := Label.new()
	if not node_name.is_empty():
		lbl.name = node_name
	lbl.text = key
	lbl.add_theme_font_size_override("font_size", _FS_SECTION)
	lbl.add_theme_color_override("font_color", UIColors.MUTED)
	_vbox.add_child(lbl)


func _form_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.name = "Label"
	lbl.text = text
	lbl.custom_minimum_size.x = _LABEL_W
	lbl.add_theme_font_size_override("font_size", _FS)
	lbl.add_theme_color_override("font_color", UIColors.TEXT)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return lbl


# Выпадающий список под общий размер текста: и сама кнопка, и раскрытый список.
func _size_option(ob: OptionButton) -> void:
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.custom_minimum_size.y = _ROW_H
	ob.add_theme_font_size_override("font_size", _FS)
	ob.get_popup().add_theme_font_size_override("font_size", _FS)


func _plain_label(key: String) -> Label:
	var lbl := Label.new()
	lbl.name = "Label"
	lbl.text = key
	lbl.add_theme_font_size_override("font_size", _FS)
	lbl.add_theme_color_override("font_color", UIColors.TEXT)
	return lbl
