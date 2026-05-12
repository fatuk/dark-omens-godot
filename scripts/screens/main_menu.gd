extends Control

## Главное меню: подключение к relay, создание/просмотр/вход в комнаты,
## модальное окно настроек.
##
## Разметка статичной части в scenes/main_menu.tscn, тут только поведение,
## стилизация, динамика (карточки комнат, попап настроек).

const SETTINGS_FILE := "user://settings.cfg"
const DEFAULT_URL   := "ws://127.0.0.1:3030"

const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280,  720),
	Vector2i(1366,  768),
	Vector2i(1600,  900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]

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
var _relay_url: String = DEFAULT_URL
var _res_idx:    int   = 3      # 1920×1080
var _fullscreen: bool  = false
var _selected_room_id: String = ""

# Настроечный попап (создаётся динамически)
var _settings_popup: Control = null
var _url_input:      LineEdit
var _res_option:     OptionButton
var _fs_check:       CheckBox
var _fx_check:       CheckBox
var _lang_option:    OptionButton


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_load_settings()
	_apply_display()
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

	_player_label.text = _auth.current_user.get("name", "")
	_server_label.text = _relay_url

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
	if is_instance_valid(_settings_popup):
		_settings_popup.queue_free()
		_settings_popup = null
		return

	_settings_popup = UIStyle.modal(self, "SETTINGS_TITLE", func(vbox: VBoxContainer) -> void:
		# ── Сервер ────────────────────────────────────────────────────────────
		var srv_lbl := Label.new()
		srv_lbl.text = "SECTION_SERVER"
		srv_lbl.add_theme_font_size_override("font_size", 12)
		srv_lbl.add_theme_color_override("font_color", UIColors.MUTED)
		vbox.add_child(srv_lbl)

		var url_row := UIStyle.labeled_input("Relay URL:", DEFAULT_URL, 90)
		_url_input = url_row[1] as LineEdit
		_url_input.text = _relay_url
		vbox.add_child(url_row[0])

		UIStyle.separator(vbox)

		# ── Дисплей ───────────────────────────────────────────────────────────
		var disp_lbl := Label.new()
		disp_lbl.text = "SECTION_DISPLAY"
		disp_lbl.add_theme_font_size_override("font_size", 12)
		disp_lbl.add_theme_color_override("font_color", UIColors.MUTED)
		vbox.add_child(disp_lbl)

		var res_row := HBoxContainer.new()
		res_row.add_theme_constant_override("separation", 8)
		vbox.add_child(res_row)

		var res_lbl := Label.new()
		res_lbl.text = "FORM_RESOLUTION"
		res_lbl.custom_minimum_size.x = 100
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
		res_row.add_child(_res_option)

		var fs_row := HBoxContainer.new()
		fs_row.add_theme_constant_override("separation", 10)
		vbox.add_child(fs_row)

		_fs_check = CheckBox.new()
		_fs_check.button_pressed = _fullscreen
		_fs_check.add_theme_color_override("font_color", UIColors.TEXT)
		_fs_check.add_theme_font_size_override("font_size", 14)
		_fs_check.toggled.connect(func(on: bool) -> void:
			_res_option.disabled = on
		)
		fs_row.add_child(_fs_check)

		var fs_lbl := Label.new()
		fs_lbl.text = "SETTINGS_FULLSCREEN"
		fs_lbl.add_theme_font_size_override("font_size", 14)
		fs_lbl.add_theme_color_override("font_color", UIColors.TEXT)
		fs_row.add_child(fs_lbl)

		# Эффект «старой плёнки»
		var fx_row := HBoxContainer.new()
		fx_row.add_theme_constant_override("separation", 10)
		vbox.add_child(fx_row)

		_fx_check = CheckBox.new()
		_fx_check.button_pressed = PostFx.is_enabled()
		_fx_check.add_theme_color_override("font_color", UIColors.TEXT)
		_fx_check.add_theme_font_size_override("font_size", 14)
		fx_row.add_child(_fx_check)

		var fx_lbl := Label.new()
		fx_lbl.text = tr("SETTINGS_FX_OLD_FILM")
		fx_lbl.add_theme_font_size_override("font_size", 14)
		fx_lbl.add_theme_color_override("font_color", UIColors.TEXT)
		fx_row.add_child(fx_lbl)

		# Язык
		var lang_row := HBoxContainer.new()
		lang_row.add_theme_constant_override("separation", 8)
		vbox.add_child(lang_row)

		var lang_lbl := Label.new()
		lang_lbl.text = tr("SETTINGS_LANGUAGE") + ":"
		lang_lbl.custom_minimum_size.x = 100
		lang_lbl.add_theme_font_size_override("font_size", 14)
		lang_lbl.add_theme_color_override("font_color", UIColors.TEXT)
		lang_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lang_row.add_child(lang_lbl)

		var lang_names: Array[String] = []
		for code: String in I18n.SUPPORTED:
			lang_names.append(tr("LANG_" + code.to_upper()))
		_lang_option = UIStyle.option_button(lang_names)
		_lang_option.selected = I18n.SUPPORTED.find(I18n.get_locale())
		lang_row.add_child(_lang_option)

		UIStyle.separator(vbox)

		# ── Кнопки ────────────────────────────────────────────────────────────
		var btns := HBoxContainer.new()
		btns.add_theme_constant_override("separation", 8)
		vbox.add_child(btns)

		var save_btn := UIStyle.button("BTN_SAVE_BIG", UIColors.ACCENT)
		save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		save_btn.pressed.connect(_on_settings_save)
		btns.add_child(save_btn)

		var cancel_btn := UIStyle.button("BTN_CANCEL_BIG", UIColors.MUTED)
		cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cancel_btn.pressed.connect(func() -> void:
			_settings_popup.queue_free()
			_settings_popup = null
		)
		btns.add_child(cancel_btn)
	)


func _on_settings_save() -> void:
	var new_url := _url_input.text.strip_edges()
	if new_url.is_empty():
		new_url = DEFAULT_URL
	var url_changed := new_url != _relay_url

	_relay_url   = new_url
	_res_idx     = _res_option.selected
	_fullscreen  = _fs_check.button_pressed

	_server_label.text = _relay_url
	_save_settings()
	_apply_display()
	PostFx.set_enabled(_fx_check.button_pressed)
	if _lang_option and _lang_option.selected >= 0:
		I18n.set_locale(I18n.SUPPORTED[_lang_option.selected])

	_settings_popup.queue_free()
	_settings_popup = null

	if url_changed:
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
	_show_status("Подключение к %s..." % _relay_url, UIColors.WARNING)
	_rooms_panel.modulate.a = 0.4
	var err: Error = _nm.connect_to_relay(pname, _relay_url)
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


# ── Настройки: загрузка / сохранение / применение ────────────────────────────

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) != OK:
		return
	_relay_url  = cfg.get_value("relay",   "url",        DEFAULT_URL)
	# Миграция: localhost резолвится в IPv6 ::1, а Docker Desktop на Windows
	# не пробрасывает IPv6 — соединение виснет. Переписываем на IPv4.
	if "://localhost:" in _relay_url:
		_relay_url = _relay_url.replace("://localhost:", "://127.0.0.1:")
	_fullscreen = cfg.get_value("display", "fullscreen",  false)
	var res_str: String = cfg.get_value("display", "resolution", "1920x1080")
	for i: int in range(RESOLUTIONS.size()):
		var r: Vector2i = RESOLUTIONS[i]
		if "%dx%d" % [r.x, r.y] == res_str:
			_res_idx = i
			return


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_FILE)
	cfg.set_value("relay",   "url",        _relay_url)
	cfg.set_value("display", "fullscreen",  _fullscreen)
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
