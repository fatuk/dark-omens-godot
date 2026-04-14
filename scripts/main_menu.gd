extends Control

# ── Узлы ───────────────────────────────────────────────────────────────────────
var _nm:   Node
var _auth: Node

var _relay_url_input: LineEdit
var _connect_button:  Button
var _player_label:    Label

var _connect_panel: Control
var _rooms_panel:   Control

var _create_name_input: LineEdit
var _create_pass_input: LineEdit
var _create_btn:        Button

var _rooms_list:       VBoxContainer
var _selected_room_id: String = ""
var _join_pass_input:  LineEdit
var _join_btn:         Button
var _refresh_btn:      Button

var _status_label: Label


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
	_build_ui()
	_restore_session_state()


# ── Построение UI ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	UIStyle.apply_bg(self)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var root_vbox := VBoxContainer.new()
	root_vbox.custom_minimum_size = Vector2(720, 0)
	root_vbox.add_theme_constant_override("separation", 14)
	center.add_child(root_vbox)

	# Заголовок
	var title := Label.new()
	title.text = "DARK OMENS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	title.add_theme_color_override("font_color",        UIStyle.GOLD)
	title.add_theme_color_override("font_shadow_color", UIStyle.RED)
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	root_vbox.add_child(title)

	var sub := Label.new()
	sub.text = "по мотивам настольной игры «Древний Ужас»"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", UIStyle.DIM)
	root_vbox.add_child(sub)

	UIStyle.separator(root_vbox)

	_connect_panel = _build_connect_panel()
	root_vbox.add_child(_connect_panel)

	_rooms_panel = _build_rooms_panel()
	_rooms_panel.visible = false
	root_vbox.add_child(_rooms_panel)

	UIStyle.separator(root_vbox)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", UIStyle.DIM)
	_status_label.text = "Введите имя и подключитесь к серверу"
	root_vbox.add_child(_status_label)


func _build_connect_panel() -> Control:
	var p := UIStyle.panel()

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	p.add_child(vbox)

	# Заголовок + кнопка выйти
	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", 8)
	vbox.add_child(hdr_row)

	var hdr := Label.new()
	hdr.text = "  ПОДКЛЮЧЕНИЕ К СЕРВЕРУ"
	hdr.add_theme_font_size_override("font_size", 16)
	hdr.add_theme_color_override("font_color", UIStyle.GOLD)
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(hdr)

	var logout_btn := UIStyle.button("Выйти", UIStyle.DIM)
	logout_btn.custom_minimum_size = Vector2(80, 0)
	logout_btn.add_theme_font_size_override("font_size", 12)
	logout_btn.pressed.connect(_on_logout_pressed)
	hdr_row.add_child(logout_btn)

	UIStyle.separator(vbox)

	# Имя игрока (из AuthManager)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	vbox.add_child(name_row)

	var name_lbl := Label.new()
	name_lbl.text = "Игрок:"
	name_lbl.custom_minimum_size.x = 120
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", UIStyle.TEXT)
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_row.add_child(name_lbl)

	_player_label = Label.new()
	_player_label.add_theme_font_size_override("font_size", 14)
	_player_label.add_theme_color_override("font_color", UIStyle.OK)
	_player_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_player_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_row.add_child(_player_label)

	var url_row := UIStyle.labeled_input("Сервер:", "ws://localhost:3030", 120)
	_relay_url_input = url_row[1] as LineEdit
	_relay_url_input.text = "ws://localhost:3030"
	_relay_url_input.custom_minimum_size.x = 300
	vbox.add_child(url_row[0])

	_connect_button = UIStyle.button("ПОДКЛЮЧИТЬСЯ")
	_connect_button.pressed.connect(_on_connect_pressed)
	vbox.add_child(_connect_button)

	return p


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

	_refresh_btn = UIStyle.button("↻")
	_refresh_btn.custom_minimum_size = Vector2(36, 0)
	_refresh_btn.pressed.connect(_on_refresh_pressed)
	lhdr_row.add_child(_refresh_btn)

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


# ── Восстановление состояния ───────────────────────────────────────────────────

func _restore_session_state() -> void:
	var uname: String = _auth.current_user.get("name", _nm.my_name)
	_player_label.text = uname if not uname.is_empty() else "—"

	if _nm.is_connected_to_relay():
		_connect_panel.visible = false
		_rooms_panel.visible = true
		_show_status("Подключено · %s" % _nm.my_name, UIStyle.OK)
		_nm.list_rooms()
	elif _nm.has_session():
		_connect_panel.visible = false
		_rooms_panel.visible = true
		_show_status("Переподключение...", UIStyle.WARN)


# ── Обработчики кнопок ─────────────────────────────────────────────────────────

func _on_connect_pressed() -> void:
	var pname: String = _auth.current_user.get("name", _nm.my_name)
	if pname.is_empty():
		pname = "Player"
	var url := _relay_url_input.text.strip_edges()
	if url.is_empty():
		url = "ws://localhost:3030"

	_connect_button.disabled = true
	_show_status("Подключение к %s..." % url, UIStyle.WARN)
	var err: Error = _nm.connect_to_relay(pname, url)
	if err != OK:
		_connect_button.disabled = false
		_show_status("Ошибка: %s" % error_string(err), UIStyle.ERROR)


func _on_logout_pressed() -> void:
	_nm.disconnect_from_relay()
	_auth.logout()
	get_tree().change_scene_to_file("res://scenes/login.tscn")


func _on_refresh_pressed() -> void:
	_nm.list_rooms()
	_show_status("Обновление списка комнат...", UIStyle.DIM)


func _on_create_pressed() -> void:
	var rname := _create_name_input.text.strip_edges()
	if rname.is_empty():
		_show_status("Введите название комнаты!", UIStyle.ERROR)
		return
	var rpass := _create_pass_input.text
	_create_btn.disabled = true
	_nm.create_room(rname, rpass)
	_show_status("Создание комнаты \"%s\"..." % rname, UIStyle.WARN)


func _on_join_pressed() -> void:
	if _selected_room_id.is_empty():
		_show_status("Выберите комнату из списка", UIStyle.ERROR)
		return
	var jpass := _join_pass_input.text
	_join_btn.disabled = true
	_nm.join_room(_selected_room_id, jpass)
	_show_status("Подключение к комнате...", UIStyle.WARN)


# ── Обработчики сигналов NetworkManager ───────────────────────────────────────

func _on_connected() -> void:
	_connect_panel.visible = false
	_rooms_panel.visible = true
	_show_status("Подключено · Имя: %s" % _nm.my_name, UIStyle.OK)
	_nm.list_rooms()


func _on_disconnected() -> void:
	_connect_panel.visible = true
	_rooms_panel.visible = false
	_connect_button.disabled = false
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
	_connect_panel.visible = false
	_rooms_panel.visible = true
	_show_status("Комната не найдена — возможно, сервер перезапускался", UIStyle.WARN)
	_nm.list_rooms()


func _on_room_deleted_in_menu(reason: String) -> void:
	_connect_panel.visible = false
	_rooms_panel.visible = true
	_show_status("Комната закрыта: %s" % reason, UIStyle.WARN)
	_nm.list_rooms()


func _on_relay_error(message: String) -> void:
	_create_btn.disabled = false
	_join_btn.disabled = _selected_room_id.is_empty()
	_show_status("Ошибка: %s" % message, UIStyle.ERROR)


# ── Вспомогательные ───────────────────────────────────────────────────────────

func _make_room_row(room: Dictionary) -> Button:
	var rname: String  = room.get("name", "???")
	var count: int     = room.get("playerCount", 0)
	var max_p: int     = room.get("maxPlayers", 8)
	var locked: bool   = room.get("locked", false)
	var lock_icon: String = " 🔒" if locked else ""

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
	btn.text = "%s%s   [%d/%d]" % [rname, lock_icon, count, max_p]
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
