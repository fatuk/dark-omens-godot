extends ColorRect

## Модалка создания комнаты: название, пароль, число игроков, Древний.
## Контент строится кодом (паттерн settings_dialog).
##
## Использование:
##   var dlg := preload("res://scenes/ui/create_room_dialog.tscn").instantiate()
##   parent.add_child(dlg)
##   dlg.submitted.connect(func(rname, pass, max_players, ancient) -> void: ...)
##
## submitted — хост подтвердил создание; cancelled — закрыл без создания.
## Диалог сам делает queue_free() после submitted/cancelled.

signal submitted(room_name: String, password: String, max_players: int, ancient_one: String)
signal cancelled

const _AO_DATA         := "res://data/ancient_ones.json"
const _MIN_PLAYERS     := 2
const _MAX_PLAYERS     := 8
const _DEFAULT_PLAYERS := 4

@onready var _panel: PanelContainer = %Panel
@onready var _vbox:  VBoxContainer  = %VBox

var _name_input:   LineEdit
var _pass_input:   LineEdit
var _count_option: OptionButton
var _ao_option:    OptionButton
var _error_label:  Label
var _ao_entries:   Array = []   # [{id, nameKey}, ...] из ancient_ones.json


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP   # клики мимо панели не падают вниз
	UIStyle.style_panel(_panel, 24)
	_ao_entries = DataLoader.load_array(_AO_DATA)
	_build()
	_name_input.grab_focus()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_cancel()
		get_viewport().set_input_as_handled()


# ── Сборка контента ───────────────────────────────────────────────────────────

func _build() -> void:
	var title := Label.new()
	title.name = "Title"
	title.text = "MENU_BTN_CREATE_ROOM"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", UIColors.ACCENT)
	_vbox.add_child(title)
	UIStyle.separator(_vbox)

	# Название
	var name_row: Array = UIStyle.labeled_input("FORM_NAME", "", 110)
	_name_input = name_row[1] as LineEdit
	_name_input.name = "NameInput"
	_name_input.placeholder_text = "MENU_GAME_NAME_PLACEHOLDER"
	_name_input.text_submitted.connect(func(_t: String) -> void: _on_create())
	(name_row[0] as Control).name = "NameRow"
	_vbox.add_child(name_row[0])

	# Пароль
	var pass_row: Array = UIStyle.labeled_input("FORM_PASSWORD", "", 110)
	_pass_input = pass_row[1] as LineEdit
	_pass_input.name = "PassInput"
	_pass_input.secret = true
	_pass_input.placeholder_text = "FORM_OPTIONAL"
	_pass_input.text_submitted.connect(func(_t: String) -> void: _on_create())
	(pass_row[0] as Control).name = "PassRow"
	_vbox.add_child(pass_row[0])

	# Число игроков
	var counts: Array[String] = []
	for n in range(_MIN_PLAYERS, _MAX_PLAYERS + 1):
		counts.append(str(n))
	_count_option = UIStyle.option_button(counts)
	_count_option.name = "CountOption"
	_count_option.selected = _DEFAULT_PLAYERS - _MIN_PLAYERS
	_vbox.add_child(_labeled_row("FORM_PLAYER_COUNT", _count_option, "CountRow"))

	# Древний (первый пункт — «Случайный»)
	var ao_names: Array[String] = [tr("AO_RANDOM")]
	for i in range(_ao_entries.size()):
		var e: Dictionary = _ao_entries[i]
		ao_names.append(tr(String(e.get("nameKey", ""))))
	_ao_option = UIStyle.option_button(ao_names)
	_ao_option.name = "AncientOption"
	_ao_option.selected = 0
	_vbox.add_child(_labeled_row("FORM_ANCIENT_ONE", _ao_option, "AncientRow"))

	# Строка ошибки — скрыта, пока ввод корректен
	_error_label = Label.new()
	_error_label.name = "ErrorLabel"
	_error_label.add_theme_font_size_override("font_size", 13)
	_error_label.add_theme_color_override("font_color", UIColors.ERROR)
	_error_label.visible = false
	_vbox.add_child(_error_label)

	UIStyle.separator(_vbox)
	_build_buttons()


func _labeled_row(label_key: String, control: Control, node_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = node_name
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = label_key
	lbl.custom_minimum_size.x = 110
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", UIColors.TEXT)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


func _build_buttons() -> void:
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 8)
	_vbox.add_child(btns)

	var create_btn := UIStyle.button("BTN_CREATE_BIG", UIColors.DANGER)
	create_btn.name = "CreateBtn"
	create_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create_btn.pressed.connect(_on_create)
	btns.add_child(create_btn)

	var cancel_btn := UIStyle.button("BTN_CANCEL_BIG", UIColors.MUTED)
	cancel_btn.name = "CancelBtn"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(_on_cancel)
	btns.add_child(cancel_btn)


# ── Создать / Отмена ──────────────────────────────────────────────────────────

func _on_create() -> void:
	var rname := _name_input.text.strip_edges()
	if rname.is_empty():
		_error_label.text = "MENU_ERR_NEED_ROOM_NAME"
		_error_label.visible = true
		_name_input.grab_focus()
		return
	var max_players: int = _MIN_PLAYERS + _count_option.selected
	var ancient: String = ""
	var idx: int = _ao_option.selected
	if idx > 0 and idx - 1 < _ao_entries.size():
		var e: Dictionary = _ao_entries[idx - 1]
		ancient = tr(String(e.get("nameKey", "")))
	submitted.emit(rname, _pass_input.text, max_players, ancient)
	queue_free()


func _on_cancel() -> void:
	cancelled.emit()
	queue_free()
