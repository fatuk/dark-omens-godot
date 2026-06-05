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

const _AO_DATA := "res://data/ancient_ones.json"
const _MIN_PLAYERS := 1
const _MAX_PLAYERS := 8
const _DEFAULT_PLAYERS := 4

@onready var _panel: PanelContainer = %Panel
@onready var _vbox: VBoxContainer = %VBox

var _name_input: LineEdit
var _pass_input: LineEdit
var _count_option: OptionButton
var _ao_option: OptionButton
var _error_label: Label
var _ao_entries: Array = []  # [{id, name}, ...] — name уже локализован для показа


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP  # клики мимо панели не падают вниз
	UIStyle.style_modal_panel(_panel)
	_ao_entries = _fallback_entries()  # статичный список — пока не пришёл актуальный
	_build()
	_name_input.grab_focus()
	_load_ancients()  # подтянуть актуальный список из relay (async)


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_cancel()
		get_viewport().set_input_as_handled()


# ── Сборка контента ───────────────────────────────────────────────────────────


func _build() -> void:
	_vbox.add_child(UIStyle.modal_header("MENU_BTN_CREATE_ROOM", _on_cancel))
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

	# Древний — актуальный список (CMS + конфиг), без «Случайного»
	_ao_option = UIStyle.option_button(_ao_names())
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
	UIStyle.scale_modal_text(_vbox)  # текст модалок крупнее (×1.5)


func _labeled_row(label_key: String, control: Control, node_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = node_name
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.name = "Label"
	lbl.text = label_key
	lbl.custom_minimum_size.x = 110
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", UIColors.TEXT)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lbl)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


# ── Список Древних ────────────────────────────────────────────────────────────


## Запасной список из статичного ancient_ones.json (если relay недоступен).
func _fallback_entries() -> Array:
	var out: Array = []
	for e in DataLoader.load_array(_AO_DATA):
		var d: Dictionary = e
		out.append({"id": String(d.get("id", "")), "name": tr(String(d.get("nameKey", "")))})
	return out


## Имена для дропдауна из текущих _ao_entries.
func _ao_names() -> Array[String]:
	var names: Array[String] = []
	for e in _ao_entries:
		var d: Dictionary = e
		names.append(String(d.get("name", "")))
	return names


## Подтянуть актуальный список Древних из relay и перезаполнить дропдаун.
func _load_ancients() -> void:
	var api: Node = get_node_or_null("/root/ContentApi")
	if api == null:
		return
	var list: Array = await api.get_ancients(TranslationServer.get_locale())
	if list.is_empty():
		return  # relay недоступен/пусто — остаётся запасной список
	var entries: Array = []
	for a in list:
		var d: Dictionary = a
		entries.append({"id": String(d.get("id", "")), "name": String(d.get("name", ""))})
	_ao_entries = entries
	if not is_instance_valid(_ao_option):
		return  # диалог закрыли, пока шёл запрос
	_ao_option.clear()
	for e in _ao_entries:
		var ed: Dictionary = e
		_ao_option.add_item(String(ed.get("name", "")))
	if _ao_option.item_count > 0:
		_ao_option.selected = 0


func _build_buttons() -> void:
	var btns := HBoxContainer.new()
	btns.name = "Buttons"
	btns.add_theme_constant_override("separation", 8)
	_vbox.add_child(btns)

	# Cancel убран — закрытие через крестик в шапке (_on_cancel).
	var create_btn := UIStyle.button("BTN_CREATE_BIG", UIColors.DANGER)
	create_btn.name = "CreateBtn"
	create_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create_btn.pressed.connect(_on_create)
	btns.add_child(create_btn)


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
	if idx >= 0 and idx < _ao_entries.size():
		var e: Dictionary = _ao_entries[idx]
		ancient = String(e.get("name", ""))
	submitted.emit(rname, _pass_input.text, max_players, ancient)
	queue_free()


func _on_cancel() -> void:
	cancelled.emit()
	queue_free()
