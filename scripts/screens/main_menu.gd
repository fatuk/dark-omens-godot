extends Control

## Главное меню: подключение к relay, создание/просмотр/вход в комнаты,
## модальное окно настроек.
##
## Разметка статичной части в scenes/main_menu.tscn, тут только поведение,
## стилизация, динамика (карточки комнат, попап настроек).

const _SETTINGS_DIALOG := preload("res://scenes/ui/settings_dialog.tscn")

# ── Узлы ──────────────────────────────────────────────────────────────────────
@onready var _bg:           ColorRect = $Bg
@onready var _player_label: Label     = %PlayerLabel
@onready var _server_label: Label     = %ServerLabel
@onready var _settings_btn: Button    = %SettingsBtn
@onready var _logout_btn:   Button    = %LogoutBtn

@onready var _rooms_panel:  HBoxContainer  = %RoomsPanel
@onready var _create_panel: PanelContainer = %CreatePanel
@onready var _list_panel:   PanelContainer = %ListPanel

@onready var _create_name_input: LineEdit = %CreateNameInput
@onready var _create_pass_input: LineEdit = %CreatePassInput
@onready var _create_btn:        Button   = %CreateBtn

@onready var _refresh_btn:   Button       = %RefreshBtn
@onready var _rooms_list:    VBoxContainer = %RoomsList
@onready var _join_pass_input: LineEdit   = %JoinPassInput
@onready var _join_btn:      Button       = %JoinBtn

@onready var _status_label:  Label        = %StatusLabel

# ── Состояние ─────────────────────────────────────────────────────────────────
var _nm:   Node
var _auth: Node
var _selected_room_id: String = ""
var _settings_dialog:  Control = null


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	MusicManager.play(MusicManager.TRACK_ELDER_SIGN)
	_apply_styles()

	_nm   = get_node("/root/NetworkManager")
	_auth = get_node("/root/AuthManager")
	_nm.connected_to_relay.connect(_on_connected)
	_nm.disconnected_from_relay.connect(_on_disconnected)
	_nm.rooms_updated.connect(_on_rooms_updated)
	_nm.joined_room.connect(_on_joined_room)
	_nm.relay_error.connect(_on_relay_error)
	_nm.rejoin_failed.connect(_on_rejoin_failed_in_menu)
	_nm.room_deleted.connect(_on_room_deleted_in_menu)

	# При смене URL в диалоге настроек — переподключаемся к новому relay.
	SettingsStore.relay_url_changed.connect(_on_relay_url_changed)

	_player_label.text = _auth.current_user.get("name", "")
	_server_label.text = SettingsStore.relay_url

	_wire_handlers()
	_auto_connect()


# ── Стили ─────────────────────────────────────────────────────────────────────

func _apply_styles() -> void:
	# Старый ColorRect фон заменяем на тайлированную main-gb.png.
	_bg.queue_free()
	UIStyle.apply_main_bg(self)

	var title := $Center/Root/Title as Label
	title.add_theme_color_override("font_color",        UIColors.ACCENT)
	title.add_theme_color_override("font_shadow_color", UIColors.DANGER)

	($Center/Root/Subtitle as Label).add_theme_color_override("font_color", UIColors.MUTED)

	_player_label.add_theme_color_override("font_color", UIColors.SUCCESS)
	_server_label.add_theme_color_override("font_color", UIColors.MUTED)
	($Center/Root/Header/DotSep as Label).add_theme_color_override("font_color", UIColors.MUTED)

	UIStyle.style_button(_settings_btn, UIColors.MUTED)
	UIStyle.style_button(_logout_btn,   UIColors.MUTED)

	UIStyle.style_panel(_create_panel)
	UIStyle.style_panel(_list_panel)

	# Заголовки панелей
	for path in [
		"Center/Root/RoomsPanel/CreatePanel/VBox/Header",
		"Center/Root/RoomsPanel/ListPanel/VBox/HeaderRow/Header",
	]:
		(get_node(path) as Label).add_theme_color_override("font_color", UIColors.ACCENT)

	# Лейблы строк ввода
	for path in [
		"Center/Root/RoomsPanel/CreatePanel/VBox/NameRow/NameLabel",
		"Center/Root/RoomsPanel/CreatePanel/VBox/PassRow/PassLabel",
		"Center/Root/RoomsPanel/ListPanel/VBox/JoinPassRow/JoinPassLabel",
	]:
		(get_node(path) as Label).add_theme_color_override("font_color", UIColors.TEXT)

	UIStyle.style_input(_create_name_input)
	UIStyle.style_input(_create_pass_input)
	UIStyle.style_input(_join_pass_input)

	UIStyle.style_button(_create_btn, UIColors.DANGER)
	UIStyle.style_button(_refresh_btn)
	UIStyle.style_button(_join_btn)

	_status_label.add_theme_color_override("font_color", UIColors.MUTED)


func _wire_handlers() -> void:
	_settings_btn.pressed.connect(_on_settings_pressed)
	_logout_btn.pressed.connect(_on_logout_pressed)
	_create_btn.pressed.connect(_on_create_pressed)
	_refresh_btn.pressed.connect(_on_refresh_pressed)
	_join_btn.pressed.connect(_on_join_pressed)


# ── Попап настроек ────────────────────────────────────────────────────────────

func _on_settings_pressed() -> void:
	if is_instance_valid(_settings_dialog):
		# Повторный клик по «⚙» — симулируем Cancel (откат live-preview + close).
		_settings_dialog.call("_on_cancel")
		return
	_settings_dialog = _SETTINGS_DIALOG.instantiate()
	_settings_dialog.show_server_url = true
	add_child(_settings_dialog)
	_settings_dialog.tree_exited.connect(func() -> void: _settings_dialog = null)
	# SettingsStore сам обновит relay_url + эмитит relay_url_changed →
	# _on_relay_url_changed подхватит и переподключится.


func _on_relay_url_changed(new_url: String) -> void:
	_server_label.text = new_url
	if _nm.is_connected_to_relay():
		_nm.disconnect_from_relay()
	_auto_connect()


# ── Авто-подключение ──────────────────────────────────────────────────────────

func _auto_connect() -> void:
	if _nm.is_connected_to_relay():
		_show_status("Подключено · %s" % _nm.my_name, UIColors.SUCCESS)
		_nm.list_rooms()
		return
	if _nm.is_reconnecting():
		# NetworkManager уже активно пытается переподключиться — ждём сигнала
		_show_status("STATUS_RECONNECTING", UIColors.WARNING)
		_rooms_panel.modulate.a = 0.4
		return
	# Либо первый заход, либо все попытки исчерпаны — стартуем заново
	var pname: String = _auth.current_user.get("name", "Player")
	_show_status("Подключение к %s..." % SettingsStore.relay_url, UIColors.WARNING)
	_rooms_panel.modulate.a = 0.4
	var err: Error = _nm.connect_to_relay(pname, SettingsStore.relay_url)
	if err != OK:
		_show_status("Ошибка подключения: %s" % error_string(err), UIColors.ERROR)
		_rooms_panel.modulate.a = 1.0


# ── Обработчики кнопок ─────────────────────────────────────────────────────────

func _on_logout_pressed() -> void:
	_nm.disconnect_from_relay()
	_auth.logout()
	SceneManager.go("login")


func _on_refresh_pressed() -> void:
	if not _nm.is_connected_to_relay():
		_show_status("STATUS_NO_CONNECTION", UIColors.WARNING)
		_auto_connect()
		return
	_nm.list_rooms()
	_show_status("STATUS_UPDATING", UIColors.MUTED)


func _on_create_pressed() -> void:
	var rname := _create_name_input.text.strip_edges()
	if rname.is_empty():
		_show_status("MENU_ERR_NEED_ROOM_NAME", UIColors.ERROR)
		return
	_create_btn.disabled = true
	_nm.create_room(rname, _create_pass_input.text)
	_show_status("Создание комнаты \"%s\"..." % rname, UIColors.WARNING)


func _on_join_pressed() -> void:
	if _selected_room_id.is_empty():
		_show_status("MENU_STATUS_PICK_ROOM", UIColors.ERROR)
		return
	_join_btn.disabled = true
	_nm.join_room(_selected_room_id, _join_pass_input.text)
	_show_status("STATUS_CONNECTING_TO_ROOM", UIColors.WARNING)


# ── Обработчики сигналов NetworkManager ───────────────────────────────────────

func _on_connected() -> void:
	_rooms_panel.modulate.a = 1.0
	_show_status("Подключено · %s" % _nm.my_name, UIColors.SUCCESS)
	_nm.list_rooms()


func _on_disconnected() -> void:
	_rooms_panel.modulate.a = 0.4
	_show_status("STATUS_DISCONNECTED", UIColors.ERROR)


func _on_rooms_updated(rooms: Array) -> void:
	_selected_room_id = ""
	_join_btn.disabled = true

	for child in _rooms_list.get_children():
		child.queue_free()

	if rooms.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.name = "EmptyLabel"
		empty_lbl.text = "MENU_STATUS_NO_ROOMS"
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_color_override("font_color", UIColors.MUTED)
		empty_lbl.add_theme_font_size_override("font_size", 13)
		_rooms_list.add_child(empty_lbl)
		_show_status("MENU_STATUS_NO_ROOMS_HINT", UIColors.MUTED)
		return

	for i in range(rooms.size()):
		var room: Dictionary = rooms[i]
		var rid: String = room.get("id", "")
		var row := _make_room_row(room)
		row.name = "Room_" + rid
		# pressed уже подключён внутри _make_room_row
		_rooms_list.add_child(row)

	_show_status(tr("MENU_STATUS_FOUND_ROOMS_FMT") % rooms.size(), UIColors.SUCCESS)


func _on_room_selected(room_id: String, row_btn: Button) -> void:
	_selected_room_id = room_id
	_join_btn.disabled = false
	for child in _rooms_list.get_children():
		var room_btn: Button = child.get_node_or_null("RoomBtn") as Button
		if room_btn == null:
			continue
		var style := StyleBoxFlat.new()
		if room_btn == row_btn:
			style.bg_color = Color(0.15, 0.12, 0.28)
			style.border_color = UIColors.ACCENT
		else:
			style.bg_color = Color(0.10, 0.09, 0.18)
			style.border_color = UIColors.BORDER
		style.set_border_width_all(1)
		style.set_corner_radius_all(4)
		style.set_content_margin_all(8)
		room_btn.add_theme_stylebox_override("normal", style)


func _on_delete_room_btn(room_id: String) -> void:
	_nm.delete_any_room(room_id)
	# Список обновится автоматом — сервер пришлёт rooms_list инициатору
	# (плюс relay_error если что-то не так).


func _on_joined_room(_rid: String, _rname: String, _is_host: bool, _players: Array) -> void:
	SceneManager.go("lobby")


func _on_rejoin_failed_in_menu() -> void:
	_rooms_panel.modulate.a = 1.0
	_show_status("MENU_ERR_ROOM_NOT_FOUND", UIColors.WARNING)
	_nm.list_rooms()


func _on_room_deleted_in_menu(reason: String) -> void:
	_rooms_panel.modulate.a = 1.0
	_show_status("Комната закрыта: %s" % reason, UIColors.WARNING)
	_nm.list_rooms()


func _on_relay_error(message: String) -> void:
	_create_btn.disabled = false
	_join_btn.disabled = _selected_room_id.is_empty()
	_show_status("Ошибка: %s" % message, UIColors.ERROR)


# ── Вспомогательные ───────────────────────────────────────────────────────────

func _make_room_row(room: Dictionary) -> Control:
	var rname:  String = room.get("name", "???")
	var count:  int    = int(room.get("playerCount", 0))
	var max_p:  int    = int(room.get("maxPlayers", 8))
	var locked: bool   = room.get("locked", false)
	var empty:  bool   = room.get("empty", false)
	var rid:    String = room.get("id", "")

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var style_n := StyleBoxFlat.new()
	style_n.bg_color = Color(0.10, 0.09, 0.18)
	style_n.border_color = UIColors.BORDER
	style_n.set_border_width_all(1)
	style_n.set_corner_radius_all(4)
	style_n.set_content_margin_all(8)

	var style_h := StyleBoxFlat.new()
	style_h.bg_color = Color(0.15, 0.12, 0.25)
	style_h.border_color = UIColors.ACCENT
	style_h.set_border_width_all(1)
	style_h.set_corner_radius_all(4)
	style_h.set_content_margin_all(8)

	var room_btn := Button.new()
	room_btn.name = "RoomBtn"
	room_btn.text = "%s%s   [%d/%d]" % [rname, " 🔒" if locked else "", count, max_p]
	room_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	room_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room_btn.add_theme_stylebox_override("normal",  style_n)
	room_btn.add_theme_stylebox_override("hover",   style_h)
	room_btn.add_theme_stylebox_override("pressed", style_h)
	room_btn.add_theme_color_override("font_color", UIColors.TEXT)
	room_btn.add_theme_font_size_override("font_size", 14)
	room_btn.pressed.connect(_on_room_selected.bind(rid, room_btn))
	UIStyle.attach_click_sfx(room_btn)
	row.add_child(room_btn)

	# ✕ только для пустых комнат — не пустые удаляются хостом из лобби.
	if empty:
		var del_btn := Button.new()
		del_btn.name = "DeleteBtn"
		del_btn.text = "✕"
		del_btn.tooltip_text = "TOOLTIP_DELETE_EMPTY_ROOM"
		del_btn.custom_minimum_size = Vector2(36, 0)
		del_btn.focus_mode = Control.FOCUS_NONE
		UIStyle.style_button(del_btn, UIColors.DANGER)
		del_btn.pressed.connect(_on_delete_room_btn.bind(rid))
		row.add_child(del_btn)

	return row


func _show_status(msg: String, color: Color = UIColors.TEXT) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = msg
		_status_label.modulate = color
