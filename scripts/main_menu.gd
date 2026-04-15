extends Control

const SETTINGS_FILE := "user://settings.cfg"
const DEFAULT_URL   := "ws://localhost:3030"

const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280,  720),
	Vector2i(1366,  768),
	Vector2i(1600,  900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]

# ── Узлы ───────────────────────────────────────────────────────────────────────
var _nm:   Node
var _auth: Node

var _server_label:  Label
var _player_label:  Label
var _settings_popup: Control   # nil пока не открыт
var _url_input:      LineEdit
var _res_option:     OptionButton
var _fs_check:       CheckBox

var _rooms_panel:   Control

# ── Состояние настроек ────────────────────────────────────────────────────────
var _res_idx:     int  = 3      # 1920×1080 по умолчанию
var _fullscreen:  bool = false

var _create_name_input: LineEdit
var _create_pass_input: LineEdit
var _create_btn:        Button

var _rooms_list:       VBoxContainer
var _selected_room_id: String = ""
var _join_pass_input:  LineEdit
var _join_btn:         Button

var _status_label: Label

var _relay_url: String = DEFAULT_URL


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_nm   = get_node("/root/NetworkManager")
	_auth = get_node("/root/AuthManager")
	_nm.connected_to_relay.connect(_on_connected)
	_nm.disconnected_from_relay.connect(_on_disconnected)
	_nm.rooms_updated.connect(_on_rooms_updated)
	_nm.joined_room.connect(_on_joined_room)
	_nm.relay_error.connect(_on_relay_error)
	_nm.rejoin_failed.connect(_on_rejoin_failed_in_menu)
	_nm.room_deleted.connect(_on_room_deleted_in_menu)

	_load_settings()
	_apply_display()
	_build_ui()
	_auto_connect()


# ── Построение UI ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	UIStyle.apply_bg(self)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var root := VBoxContainer.new()
	root.custom_minimum_size = Vector2(720, 0)
	root.add_theme_constant_override("separation", 14)
	center.add_child(root)

	# Заголовок
	var title := Label.new()
	title.text = "DARK OMENS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color",        UIColors.ACCENT)
	title.add_theme_color_override("font_shadow_color", UIColors.DANGER)
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	root.add_child(title)

	var sub := Label.new()
	sub.text = "по мотивам настольной игры «Древний Ужас»"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", UIColors.MUTED)
	root.add_child(sub)

	UIStyle.separator(root)

	# ── Хедер: игрок · сервер · кнопки ───────────────────────────────────────
	root.add_child(_build_header())

	UIStyle.separator(root)

	# ── Панель комнат ─────────────────────────────────────────────────────────
	_rooms_panel = _build_rooms_panel()
	root.add_child(_rooms_panel)

	UIStyle.separator(root)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", UIColors.MUTED)
	_status_label.text = "Подключение..."
	root.add_child(_status_label)


func _build_header() -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 10)

	# Имя игрока
	var user_icon := Label.new()
	user_icon.text = "👤"
	user_icon.add_theme_font_size_override("font_size", 14)
	hbox.add_child(user_icon)

	_player_label = Label.new()
	_player_label.add_theme_font_size_override("font_size", 14)
	_player_label.add_theme_color_override("font_color", UIColors.SUCCESS)
	_player_label.text = _auth.current_user.get("name", "")
	hbox.add_child(_player_label)

	# Разделитель
	var sep_lbl := Label.new()
	sep_lbl.text = "·"
	sep_lbl.add_theme_color_override("font_color", UIColors.MUTED)
	sep_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sep_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hbox.add_child(sep_lbl)

	# Сервер
	var srv_icon := Label.new()
	srv_icon.text = "🌐"
	srv_icon.add_theme_font_size_override("font_size", 14)
	hbox.add_child(srv_icon)

	_server_label = Label.new()
	_server_label.text = _relay_url
	_server_label.add_theme_font_size_override("font_size", 13)
	_server_label.add_theme_color_override("font_color", UIColors.MUTED)
	hbox.add_child(_server_label)

	# Кнопка настроек
	var settings_btn := UIStyle.button("⚙", UIColors.MUTED)
	settings_btn.custom_minimum_size = Vector2(34, 0)
	settings_btn.add_theme_font_size_override("font_size", 14)
	settings_btn.pressed.connect(_on_settings_pressed)
	hbox.add_child(settings_btn)

	# Кнопка выйти
	var logout_btn := UIStyle.button("Выйти", UIColors.MUTED)
	logout_btn.custom_minimum_size = Vector2(80, 0)
	logout_btn.add_theme_font_size_override("font_size", 12)
	logout_btn.pressed.connect(_on_logout_pressed)
	hbox.add_child(logout_btn)

	return hbox


func _build_rooms_panel() -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)

	# ── Левая: Создать комнату ─────────────────────────────────────────────────
	var create_panel := UIStyle.panel()
	create_panel.custom_minimum_size = Vector2(260, 0)
	hbox.add_child(create_panel)

	var cvbox := VBoxContainer.new()
	cvbox.add_theme_constant_override("separation", 10)
	create_panel.add_child(cvbox)

	var chdr := Label.new()
	chdr.text = "  СОЗДАТЬ КОМНАТУ"
	chdr.add_theme_font_size_override("font_size", 16)
	chdr.add_theme_color_override("font_color", UIColors.ACCENT)
	cvbox.add_child(chdr)

	UIStyle.separator(cvbox)

	var cname_row := UIStyle.labeled_input("Название:", "Моя игра...", 100)
	_create_name_input = cname_row[1] as LineEdit
	cvbox.add_child(cname_row[0])

	var cpass_row := UIStyle.labeled_input("Пароль:", "(необязательно)", 100, true)
	_create_pass_input = cpass_row[1] as LineEdit
	cvbox.add_child(cpass_row[0])

	_create_btn = UIStyle.button("СОЗДАТЬ", UIColors.DANGER)
	_create_btn.pressed.connect(_on_create_pressed)
	cvbox.add_child(_create_btn)

	# ── Правая: Список комнат ──────────────────────────────────────────────────
	var list_panel := UIStyle.panel()
	list_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(list_panel)

	var lvbox := VBoxContainer.new()
	lvbox.add_theme_constant_override("separation", 8)
	list_panel.add_child(lvbox)

	var lhdr_row := HBoxContainer.new()
	lhdr_row.add_theme_constant_override("separation", 10)
	lvbox.add_child(lhdr_row)

	var lhdr := Label.new()
	lhdr.text = "  ОТКРЫТЫЕ КОМНАТЫ"
	lhdr.add_theme_font_size_override("font_size", 16)
	lhdr.add_theme_color_override("font_color", UIColors.ACCENT)
	lhdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lhdr_row.add_child(lhdr)

	var refresh_btn := UIStyle.button("↻")
	refresh_btn.custom_minimum_size = Vector2(36, 0)
	refresh_btn.pressed.connect(_on_refresh_pressed)
	lhdr_row.add_child(refresh_btn)

	UIStyle.separator(lvbox)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 140)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lvbox.add_child(scroll)

	_rooms_list = VBoxContainer.new()
	_rooms_list.add_theme_constant_override("separation", 4)
	_rooms_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rooms_list)

	UIStyle.separator(lvbox)

	var jpass_row := UIStyle.labeled_input("Пароль:", "(если требуется)", 90, true)
	_join_pass_input = jpass_row[1] as LineEdit
	lvbox.add_child(jpass_row[0])

	_join_btn = UIStyle.button("ВОЙТИ В КОМНАТУ")
	_join_btn.disabled = true
	_join_btn.pressed.connect(_on_join_pressed)
	lvbox.add_child(_join_btn)

	return hbox


# ── Попап настроек (смена URL сервера) ────────────────────────────────────────

func _on_settings_pressed() -> void:
	if is_instance_valid(_settings_popup):
		_settings_popup.queue_free()
		_settings_popup = null
		return

	_settings_popup = UIStyle.modal(self, "НАСТРОЙКИ", func(vbox: VBoxContainer) -> void:

		# ── Сервер ────────────────────────────────────────────────────────────
		var srv_lbl := Label.new()
		srv_lbl.text = "СЕРВЕР"
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
		disp_lbl.text = "ДИСПЛЕЙ"
		disp_lbl.add_theme_font_size_override("font_size", 12)
		disp_lbl.add_theme_color_override("font_color", UIColors.MUTED)
		vbox.add_child(disp_lbl)

		var res_row := HBoxContainer.new()
		res_row.add_theme_constant_override("separation", 8)
		vbox.add_child(res_row)

		var res_lbl := Label.new()
		res_lbl.text = "Разрешение:"
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
		fs_lbl.text = "Полный экран"
		fs_lbl.add_theme_font_size_override("font_size", 14)
		fs_lbl.add_theme_color_override("font_color", UIColors.TEXT)
		fs_row.add_child(fs_lbl)

		UIStyle.separator(vbox)

		# ── Кнопки ────────────────────────────────────────────────────────────
		var btns := HBoxContainer.new()
		btns.add_theme_constant_override("separation", 8)
		vbox.add_child(btns)

		var save_btn := UIStyle.button("СОХРАНИТЬ", UIColors.ACCENT)
		save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		save_btn.pressed.connect(_on_settings_save)
		btns.add_child(save_btn)

		var cancel_btn := UIStyle.button("ОТМЕНА", UIColors.MUTED)
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
		_show_status("Переподключение...", UIColors.WARNING)
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
		_show_status("Нет соединения — переподключение...", UIColors.WARNING)
		_auto_connect()
		return
	_nm.list_rooms()
	_show_status("Обновление...", UIColors.MUTED)


func _on_create_pressed() -> void:
	var rname := _create_name_input.text.strip_edges()
	if rname.is_empty():
		_show_status("Введите название комнаты!", UIColors.ERROR)
		return
	_create_btn.disabled = true
	_nm.create_room(rname, _create_pass_input.text)
	_show_status("Создание комнаты \"%s\"..." % rname, UIColors.WARNING)


func _on_join_pressed() -> void:
	if _selected_room_id.is_empty():
		_show_status("Выберите комнату из списка", UIColors.ERROR)
		return
	_join_btn.disabled = true
	_nm.join_room(_selected_room_id, _join_pass_input.text)
	_show_status("Подключение к комнате...", UIColors.WARNING)


# ── Обработчики сигналов NetworkManager ───────────────────────────────────────

func _on_connected() -> void:
	_rooms_panel.modulate.a = 1.0
	_show_status("Подключено · %s" % _nm.my_name, UIColors.SUCCESS)
	_nm.list_rooms()


func _on_disconnected() -> void:
	_rooms_panel.modulate.a = 0.4
	_show_status("Отключено от сервера", UIColors.ERROR)


func _on_rooms_updated(rooms: Array) -> void:
	_selected_room_id = ""
	_join_btn.disabled = true

	for child in _rooms_list.get_children():
		child.queue_free()

	if rooms.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "Нет активных комнат"
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_color_override("font_color", UIColors.MUTED)
		empty_lbl.add_theme_font_size_override("font_size", 13)
		_rooms_list.add_child(empty_lbl)
		_show_status("Активных комнат нет — создайте свою!", UIColors.MUTED)
		return

	for i in range(rooms.size()):
		var room: Dictionary = rooms[i]
		var rid: String = room.get("id", "")
		var row := _make_room_row(room)
		row.pressed.connect(_on_room_selected.bind(rid, row))
		_rooms_list.add_child(row)

	_show_status("Найдено комнат: %d" % rooms.size(), UIColors.SUCCESS)


func _on_room_selected(room_id: String, row: Button) -> void:
	_selected_room_id = room_id
	_join_btn.disabled = false
	for child in _rooms_list.get_children():
		if child is Button:
			var btn := child as Button
			var style := StyleBoxFlat.new()
			if child == row:
				style.bg_color = Color(0.15, 0.12, 0.28)
				style.border_color = UIColors.ACCENT
			else:
				style.bg_color = Color(0.10, 0.09, 0.18)
				style.border_color = UIColors.BORDER
			style.set_border_width_all(1)
			style.set_corner_radius_all(4)
			style.set_content_margin_all(8)
			btn.add_theme_stylebox_override("normal", style)


func _on_joined_room(_rid: String, _rname: String, _is_host: bool, _players: Array) -> void:
	SceneManager.go("world_map")


func _on_rejoin_failed_in_menu() -> void:
	_rooms_panel.modulate.a = 1.0
	_show_status("Комната не найдена — возможно, сервер перезапускался", UIColors.WARNING)
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

func _make_room_row(room: Dictionary) -> Button:
	var rname: String = room.get("name", "???")
	var count: int    = room.get("playerCount", 0)
	var max_p: int    = room.get("maxPlayers", 8)
	var locked: bool  = room.get("locked", false)

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

	var btn := Button.new()
	btn.text = "%s%s   [%d/%d]" % [rname, " 🔒" if locked else "", count, max_p]
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_stylebox_override("normal",  style_n)
	btn.add_theme_stylebox_override("hover",   style_h)
	btn.add_theme_stylebox_override("pressed", style_h)
	btn.add_theme_color_override("font_color", UIColors.TEXT)
	btn.add_theme_font_size_override("font_size", 14)
	return btn


func _show_status(msg: String, color: Color = UIColors.TEXT) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = msg
		_status_label.modulate = color
