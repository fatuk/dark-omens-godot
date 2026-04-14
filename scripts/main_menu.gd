extends Control

const SETTINGS_FILE := "user://settings.cfg"
const DEFAULT_URL   := "ws://localhost:3030"

# ── Узлы ───────────────────────────────────────────────────────────────────────
var _nm:   Node
var _auth: Node

var _server_label:  Label
var _player_label:  Label
var _settings_popup: Control   # nil пока не открыт
var _url_input:     LineEdit

var _rooms_panel:   Control

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

	_relay_url = _load_url()
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
	title.add_theme_color_override("font_color",        UIStyle.GOLD)
	title.add_theme_color_override("font_shadow_color", UIStyle.RED)
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	root.add_child(title)

	var sub := Label.new()
	sub.text = "по мотивам настольной игры «Древний Ужас»"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", UIStyle.DIM)
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
	_status_label.add_theme_color_override("font_color", UIStyle.DIM)
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
	_player_label.add_theme_color_override("font_color", UIStyle.OK)
	_player_label.text = _auth.current_user.get("name", "")
	hbox.add_child(_player_label)

	# Разделитель
	var sep_lbl := Label.new()
	sep_lbl.text = "·"
	sep_lbl.add_theme_color_override("font_color", UIStyle.DIM)
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
	_server_label.add_theme_color_override("font_color", UIStyle.DIM)
	hbox.add_child(_server_label)

	# Кнопка настроек
	var settings_btn := UIStyle.button("⚙", UIStyle.DIM)
	settings_btn.custom_minimum_size = Vector2(34, 0)
	settings_btn.add_theme_font_size_override("font_size", 14)
	settings_btn.pressed.connect(_on_settings_pressed)
	hbox.add_child(settings_btn)

	# Кнопка выйти
	var logout_btn := UIStyle.button("Выйти", UIStyle.DIM)
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
	chdr.add_theme_color_override("font_color", UIStyle.GOLD)
	cvbox.add_child(chdr)

	UIStyle.separator(cvbox)

	var cname_row := UIStyle.labeled_input("Название:", "Моя игра...", 100)
	_create_name_input = cname_row[1] as LineEdit
	cvbox.add_child(cname_row[0])

	var cpass_row := UIStyle.labeled_input("Пароль:", "(необязательно)", 100, true)
	_create_pass_input = cpass_row[1] as LineEdit
	cvbox.add_child(cpass_row[0])

	_create_btn = UIStyle.button("СОЗДАТЬ", UIStyle.RED)
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
	lhdr.add_theme_color_override("font_color", UIStyle.GOLD)
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

	# Затемнение
	_settings_popup = ColorRect.new()
	(_settings_popup as ColorRect).color = Color(0, 0, 0, 0.6)
	_settings_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_popup.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_settings_popup)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_popup.add_child(center)

	var p := UIStyle.panel(20)
	p.custom_minimum_size = Vector2(440, 0)
	center.add_child(p)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	p.add_child(vbox)

	var hdr := Label.new()
	hdr.text = "  НАСТРОЙКИ СЕРВЕРА"
	hdr.add_theme_font_size_override("font_size", 16)
	hdr.add_theme_color_override("font_color", UIStyle.GOLD)
	vbox.add_child(hdr)

	UIStyle.separator(vbox)

	var url_row := UIStyle.labeled_input("Relay URL:", DEFAULT_URL, 100)
	_url_input = url_row[1] as LineEdit
	_url_input.text = _relay_url
	vbox.add_child(url_row[0])

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 8)
	vbox.add_child(btns)

	var save_btn := UIStyle.button("СОХРАНИТЬ", UIStyle.GOLD)
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(_on_settings_save)
	btns.add_child(save_btn)

	var cancel_btn := UIStyle.button("ОТМЕНА", UIStyle.DIM)
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(func() -> void:
		_settings_popup.queue_free()
		_settings_popup = null
	)
	btns.add_child(cancel_btn)


func _on_settings_save() -> void:
	var new_url := _url_input.text.strip_edges()
	if new_url.is_empty():
		new_url = DEFAULT_URL
	_relay_url = new_url
	_server_label.text = _relay_url
	_save_url(_relay_url)
	_settings_popup.queue_free()
	_settings_popup = null
	# Переподключаемся если URL изменился
	if _nm.is_connected_to_relay():
		_nm.disconnect_from_relay()
	_auto_connect()


# ── Авто-подключение ──────────────────────────────────────────────────────────

func _auto_connect() -> void:
	if _nm.is_connected_to_relay():
		_show_status("Подключено · %s" % _nm.my_name, UIStyle.OK)
		_nm.list_rooms()
		return
	if _nm.is_reconnecting():
		# NetworkManager уже активно пытается переподключиться — ждём сигнала
		_show_status("Переподключение...", UIStyle.WARN)
		_rooms_panel.modulate.a = 0.4
		return
	# Либо первый заход, либо все попытки исчерпаны — стартуем заново
	var pname: String = _auth.current_user.get("name", "Player")
	_show_status("Подключение к %s..." % _relay_url, UIStyle.WARN)
	_rooms_panel.modulate.a = 0.4
	var err: Error = _nm.connect_to_relay(pname, _relay_url)
	if err != OK:
		_show_status("Ошибка подключения: %s" % error_string(err), UIStyle.ERROR)
		_rooms_panel.modulate.a = 1.0


# ── Обработчики кнопок ─────────────────────────────────────────────────────────

func _on_logout_pressed() -> void:
	_nm.disconnect_from_relay()
	_auth.logout()
	get_tree().change_scene_to_file("res://scenes/login.tscn")


func _on_refresh_pressed() -> void:
	if not _nm.is_connected_to_relay():
		_show_status("Нет соединения — переподключение...", UIStyle.WARN)
		_auto_connect()
		return
	_nm.list_rooms()
	_show_status("Обновление...", UIStyle.DIM)


func _on_create_pressed() -> void:
	var rname := _create_name_input.text.strip_edges()
	if rname.is_empty():
		_show_status("Введите название комнаты!", UIStyle.ERROR)
		return
	_create_btn.disabled = true
	_nm.create_room(rname, _create_pass_input.text)
	_show_status("Создание комнаты \"%s\"..." % rname, UIStyle.WARN)


func _on_join_pressed() -> void:
	if _selected_room_id.is_empty():
		_show_status("Выберите комнату из списка", UIStyle.ERROR)
		return
	_join_btn.disabled = true
	_nm.join_room(_selected_room_id, _join_pass_input.text)
	_show_status("Подключение к комнате...", UIStyle.WARN)


# ── Обработчики сигналов NetworkManager ───────────────────────────────────────

func _on_connected() -> void:
	_rooms_panel.modulate.a = 1.0
	_show_status("Подключено · %s" % _nm.my_name, UIStyle.OK)
	_nm.list_rooms()


func _on_disconnected() -> void:
	_rooms_panel.modulate.a = 0.4
	_show_status("Отключено от сервера", UIStyle.ERROR)


func _on_rooms_updated(rooms: Array) -> void:
	_selected_room_id = ""
	_join_btn.disabled = true

	for child in _rooms_list.get_children():
		child.queue_free()

	if rooms.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "Нет активных комнат"
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_color_override("font_color", UIStyle.DIM)
		empty_lbl.add_theme_font_size_override("font_size", 13)
		_rooms_list.add_child(empty_lbl)
		_show_status("Активных комнат нет — создайте свою!", UIStyle.DIM)
		return

	for i in range(rooms.size()):
		var room: Dictionary = rooms[i]
		var rid: String = room.get("id", "")
		var row := _make_room_row(room)
		row.pressed.connect(_on_room_selected.bind(rid, row))
		_rooms_list.add_child(row)

	_show_status("Найдено комнат: %d" % rooms.size(), UIStyle.OK)


func _on_room_selected(room_id: String, row: Button) -> void:
	_selected_room_id = room_id
	_join_btn.disabled = false
	for child in _rooms_list.get_children():
		if child is Button:
			var btn := child as Button
			var style := StyleBoxFlat.new()
			if child == row:
				style.bg_color = Color(0.15, 0.12, 0.28)
				style.border_color = UIStyle.GOLD
			else:
				style.bg_color = Color(0.10, 0.09, 0.18)
				style.border_color = UIStyle.BORDER
			style.set_border_width_all(1)
			style.set_corner_radius_all(4)
			style.set_content_margin_all(8)
			btn.add_theme_stylebox_override("normal", style)


func _on_joined_room(_rid: String, _rname: String, _is_host: bool, _players: Array) -> void:
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")


func _on_rejoin_failed_in_menu() -> void:
	_rooms_panel.modulate.a = 1.0
	_show_status("Комната не найдена — возможно, сервер перезапускался", UIStyle.WARN)
	_nm.list_rooms()


func _on_room_deleted_in_menu(reason: String) -> void:
	_rooms_panel.modulate.a = 1.0
	_show_status("Комната закрыта: %s" % reason, UIStyle.WARN)
	_nm.list_rooms()


func _on_relay_error(message: String) -> void:
	_create_btn.disabled = false
	_join_btn.disabled = _selected_room_id.is_empty()
	_show_status("Ошибка: %s" % message, UIStyle.ERROR)


# ── Сохранение URL ────────────────────────────────────────────────────────────

func _load_url() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_FILE) == OK:
		return cfg.get_value("relay", "url", DEFAULT_URL)
	return DEFAULT_URL


func _save_url(url: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_FILE)   # не критично если нет файла
	cfg.set_value("relay", "url", url)
	cfg.save(SETTINGS_FILE)


# ── Вспомогательные ───────────────────────────────────────────────────────────

func _make_room_row(room: Dictionary) -> Button:
	var rname: String = room.get("name", "???")
	var count: int    = room.get("playerCount", 0)
	var max_p: int    = room.get("maxPlayers", 8)
	var locked: bool  = room.get("locked", false)

	var style_n := StyleBoxFlat.new()
	style_n.bg_color = Color(0.10, 0.09, 0.18)
	style_n.border_color = UIStyle.BORDER
	style_n.set_border_width_all(1)
	style_n.set_corner_radius_all(4)
	style_n.set_content_margin_all(8)

	var style_h := StyleBoxFlat.new()
	style_h.bg_color = Color(0.15, 0.12, 0.25)
	style_h.border_color = UIStyle.GOLD
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
	btn.add_theme_color_override("font_color", UIStyle.TEXT)
	btn.add_theme_font_size_override("font_size", 14)
	return btn


func _show_status(msg: String, color: Color = UIStyle.TEXT) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = msg
		_status_label.modulate = color
