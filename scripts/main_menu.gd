extends Control

# ── Цвета ──────────────────────────────────────────────────────────────────────
const COLOR_BG           := Color(0.05, 0.04, 0.10)
const COLOR_PANEL        := Color(0.08, 0.07, 0.15)
const COLOR_PANEL_BORDER := Color(0.35, 0.25, 0.10)
const COLOR_GOLD         := Color(0.78, 0.66, 0.29)
const COLOR_RED          := Color(0.55, 0.10, 0.10)
const COLOR_TEXT         := Color(0.85, 0.82, 0.75)
const COLOR_DIM          := Color(0.55, 0.52, 0.45)
const COLOR_ERROR        := Color(0.90, 0.25, 0.20)
const COLOR_OK           := Color(0.30, 0.80, 0.40)
const COLOR_WARN         := Color(0.90, 0.75, 0.20)

# ── Узлы ───────────────────────────────────────────────────────────────────────
var _nm: Node
var _auth: Node

var _relay_url_input:    LineEdit
var _connect_button:     Button
var _player_label:       Label

var _connect_panel:      Control   # видим до подключения
var _rooms_panel:        Control   # видим после подключения

# Создать комнату
var _create_name_input:  LineEdit
var _create_pass_input:  LineEdit
var _create_btn:         Button

# Список комнат
var _rooms_list:         VBoxContainer
var _selected_room_id:   String = ""
var _join_pass_input:    LineEdit
var _join_btn:           Button
var _refresh_btn:        Button

var _status_label:       Label


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
	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

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
	title.add_theme_color_override("font_color", COLOR_GOLD)
	title.add_theme_color_override("font_shadow_color", COLOR_RED)
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	root_vbox.add_child(title)

	var sub := Label.new()
	sub.text = "по мотивам настольной игры «Древний Ужас»"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 14)
	sub.add_theme_color_override("font_color", COLOR_DIM)
	root_vbox.add_child(sub)

	_add_separator(root_vbox, COLOR_PANEL_BORDER)

	# ──  Панель подключения  ──────────────────────────────────────────────────
	_connect_panel = _build_connect_panel()
	root_vbox.add_child(_connect_panel)

	# ──  Панель комнат  ───────────────────────────────────────────────────────
	_rooms_panel = _build_rooms_panel()
	_rooms_panel.visible = false
	root_vbox.add_child(_rooms_panel)

	_add_separator(root_vbox, COLOR_PANEL_BORDER)

	# Статус
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.add_theme_color_override("font_color", COLOR_DIM)
	_status_label.text = "Введите имя и подключитесь к серверу"
	root_vbox.add_child(_status_label)


func _build_connect_panel() -> Control:
	var panel := _make_panel()

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	# Заголовок + кнопка выйти
	var hdr_row := HBoxContainer.new()
	hdr_row.add_theme_constant_override("separation", 8)
	vbox.add_child(hdr_row)

	var hdr := Label.new()
	hdr.text = "  ПОДКЛЮЧЕНИЕ К СЕРВЕРУ"
	hdr.add_theme_font_size_override("font_size", 16)
	hdr.add_theme_color_override("font_color", COLOR_GOLD)
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(hdr)

	var logout_btn := _make_button("Выйти", COLOR_DIM)
	logout_btn.custom_minimum_size = Vector2(80, 0)
	logout_btn.add_theme_font_size_override("font_size", 12)
	logout_btn.pressed.connect(_on_logout_pressed)
	hdr_row.add_child(logout_btn)

	_add_separator(vbox, COLOR_PANEL_BORDER)

	# Имя игрока (из AuthManager)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	vbox.add_child(name_row)

	var name_lbl := Label.new()
	name_lbl.text = "Игрок:"
	name_lbl.custom_minimum_size.x = 120
	name_lbl.add_theme_font_size_override("font_size", 14)
	name_lbl.add_theme_color_override("font_color", COLOR_TEXT)
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_row.add_child(name_lbl)

	_player_label = Label.new()
	_player_label.add_theme_font_size_override("font_size", 14)
	_player_label.add_theme_color_override("font_color", COLOR_OK)
	_player_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_player_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_row.add_child(_player_label)

	var url_row := _make_labeled_input("Сервер:", "ws://localhost:3030", 120)
	_relay_url_input = url_row[1] as LineEdit
	_relay_url_input.text = "ws://localhost:3030"
	_relay_url_input.custom_minimum_size.x = 300
	vbox.add_child(url_row[0])

	_connect_button = _make_button("ПОДКЛЮЧИТЬСЯ", COLOR_PANEL_BORDER)
	_connect_button.pressed.connect(_on_connect_pressed)
	vbox.add_child(_connect_button)

	return panel


func _build_rooms_panel() -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)

	# ── Левая: Создать комнату ─────────────────────────────────────────────────
	var create_panel := _make_panel()
	create_panel.custom_minimum_size = Vector2(260, 0)
	hbox.add_child(create_panel)

	var cvbox := VBoxContainer.new()
	cvbox.add_theme_constant_override("separation", 10)
	create_panel.add_child(cvbox)

	var chdr := Label.new()
	chdr.text = "  СОЗДАТЬ КОМНАТУ"
	chdr.add_theme_font_size_override("font_size", 16)
	chdr.add_theme_color_override("font_color", COLOR_GOLD)
	cvbox.add_child(chdr)

	_add_separator(cvbox, COLOR_PANEL_BORDER)

	var cname_row := _make_labeled_input("Название:", "Моя игра...", 100)
	_create_name_input = cname_row[1] as LineEdit
	cvbox.add_child(cname_row[0])

	var cpass_row := _make_labeled_input("Пароль:", "(необязательно)", 100)
	_create_pass_input = cpass_row[1] as LineEdit
	_create_pass_input.secret = true
	cvbox.add_child(cpass_row[0])

	_create_btn = _make_button("СОЗДАТЬ", COLOR_RED)
	_create_btn.pressed.connect(_on_create_pressed)
	cvbox.add_child(_create_btn)

	# ── Правая: Список комнат ──────────────────────────────────────────────────
	var list_panel := _make_panel()
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
	lhdr.add_theme_color_override("font_color", COLOR_GOLD)
	lhdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lhdr_row.add_child(lhdr)

	_refresh_btn = _make_button("↻", COLOR_PANEL_BORDER)
	_refresh_btn.custom_minimum_size = Vector2(36, 0)
	_refresh_btn.pressed.connect(_on_refresh_pressed)
	lhdr_row.add_child(_refresh_btn)

	_add_separator(lvbox, COLOR_PANEL_BORDER)

	# Скролл со списком
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 140)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lvbox.add_child(scroll)

	_rooms_list = VBoxContainer.new()
	_rooms_list.add_theme_constant_override("separation", 4)
	_rooms_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rooms_list)

	_add_separator(lvbox, COLOR_PANEL_BORDER)

	var jpass_row := _make_labeled_input("Пароль:", "(если требуется)", 90)
	_join_pass_input = jpass_row[1] as LineEdit
	_join_pass_input.secret = true
	lvbox.add_child(jpass_row[0])

	_join_btn = _make_button("ВОЙТИ В КОМНАТУ", COLOR_PANEL_BORDER)
	_join_btn.disabled = true
	_join_btn.pressed.connect(_on_join_pressed)
	lvbox.add_child(_join_btn)

	return hbox


# ── Обработчики кнопок ─────────────────────────────────────────────────────────

func _restore_session_state() -> void:
	# Обновляем плашку с именем
	var uname: String = _auth.current_user.get("name", "")
	if uname.is_empty():
		uname = _nm.my_name   # fallback при reconnect до загрузки профиля
	_player_label.text = uname

	if _nm.is_connected_to_relay():
		_connect_panel.visible = false
		_rooms_panel.visible = true
		_show_status("Подключено · %s" % _nm.my_name, COLOR_OK)
		_nm.list_rooms()
	elif _nm.has_session():
		_connect_panel.visible = false
		_rooms_panel.visible = true
		_show_status("Переподключение...", COLOR_WARN)
	# Иначе — остаётся форма подключения


func _on_connect_pressed() -> void:
	var pname: String = _auth.current_user.get("name", _nm.my_name)
	if pname.is_empty():
		pname = "Player"
	var url := _relay_url_input.text.strip_edges()
	if url.is_empty():
		url = "ws://localhost:3030"

	_connect_button.disabled = true
	_show_status("Подключение к %s..." % url, COLOR_WARN)
	var err: Error = _nm.connect_to_relay(pname, url)
	if err != OK:
		_connect_button.disabled = false
		_show_status("Ошибка: %s" % error_string(err), COLOR_ERROR)


func _on_logout_pressed() -> void:
	_nm.disconnect_from_relay()
	_auth.logout()
	get_tree().change_scene_to_file("res://scenes/login.tscn")


func _on_refresh_pressed() -> void:
	_nm.list_rooms()
	_show_status("Обновление списка комнат...", COLOR_DIM)


func _on_create_pressed() -> void:
	var rname := _create_name_input.text.strip_edges()
	if rname.is_empty():
		_show_status("Введите название комнаты!", COLOR_ERROR)
		return
	var rpass := _create_pass_input.text
	_create_btn.disabled = true
	_nm.create_room(rname, rpass)
	_show_status("Создание комнаты \"%s\"..." % rname, COLOR_WARN)


func _on_join_pressed() -> void:
	if _selected_room_id.is_empty():
		_show_status("Выберите комнату из списка", COLOR_ERROR)
		return
	var jpass := _join_pass_input.text
	_join_btn.disabled = true
	_nm.join_room(_selected_room_id, jpass)
	_show_status("Подключение к комнате...", COLOR_WARN)


# ── Обработчики сигналов NetworkManager ───────────────────────────────────────

func _on_connected() -> void:
	_connect_panel.visible = false
	_rooms_panel.visible = true
	_show_status("Подключено · Имя: %s" % _nm.my_name, COLOR_OK)
	_nm.list_rooms()


func _on_disconnected() -> void:
	_connect_panel.visible = true
	_rooms_panel.visible = false
	_connect_button.disabled = false
	_show_status("Отключено от сервера", COLOR_ERROR)


func _on_rooms_updated(rooms: Array) -> void:
	_selected_room_id = ""
	_join_btn.disabled = true

	for child in _rooms_list.get_children():
		child.queue_free()

	if rooms.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "Нет активных комнат"
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_color_override("font_color", COLOR_DIM)
		empty_lbl.add_theme_font_size_override("font_size", 13)
		_rooms_list.add_child(empty_lbl)
		_show_status("Активных комнат нет — создайте свою!", COLOR_DIM)
		return

	for i in range(rooms.size()):
		var room: Dictionary = rooms[i]
		var rid: String = room.get("id", "")
		var row := _make_room_row(room)
		row.pressed.connect(_on_room_selected.bind(rid, row))
		_rooms_list.add_child(row)

	_show_status("Найдено комнат: %d" % rooms.size(), COLOR_OK)


func _on_room_selected(room_id: String, row: Button) -> void:
	_selected_room_id = room_id
	_join_btn.disabled = false
	# Подсветить выбранную строку
	for child in _rooms_list.get_children():
		if child is Button:
			var btn := child as Button
			var style := StyleBoxFlat.new()
			if child == row:
				style.bg_color = Color(0.15, 0.12, 0.28)
				style.border_color = COLOR_GOLD
			else:
				style.bg_color = Color(0.10, 0.09, 0.18)
				style.border_color = COLOR_PANEL_BORDER
			style.set_border_width_all(1)
			style.set_corner_radius_all(4)
			style.set_content_margin_all(8)
			btn.add_theme_stylebox_override("normal", style)


func _on_joined_room(_rid: String, _rname: String, _is_host: bool, _players: Array) -> void:
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")


func _on_rejoin_failed_in_menu() -> void:
	_connect_panel.visible = false
	_rooms_panel.visible = true
	_show_status("Комната не найдена — возможно, сервер перезапускался", COLOR_WARN)
	_nm.list_rooms()


func _on_room_deleted_in_menu(reason: String) -> void:
	_connect_panel.visible = false
	_rooms_panel.visible = true
	_show_status("Комната закрыта: %s" % reason, COLOR_WARN)
	_nm.list_rooms()


func _on_relay_error(message: String) -> void:
	_create_btn.disabled = false
	_join_btn.disabled = _selected_room_id.is_empty()
	_show_status("Ошибка: %s" % message, COLOR_ERROR)


# ── Вспомогательные ───────────────────────────────────────────────────────────

func _make_room_row(room: Dictionary) -> Button:
	var rname: String = room.get("name", "???")
	var count: int = room.get("playerCount", 0)
	var max_p: int = room.get("maxPlayers", 8)
	var locked: bool = room.get("locked", false)

	var lock_icon: String = " 🔒" if locked else ""
	var label_text: String = "%s%s   [%d/%d]" % [rname, lock_icon, count, max_p]

	var style_n := StyleBoxFlat.new()
	style_n.bg_color = Color(0.10, 0.09, 0.18)
	style_n.border_color = COLOR_PANEL_BORDER
	style_n.set_border_width_all(1)
	style_n.set_corner_radius_all(4)
	style_n.set_content_margin_all(8)

	var style_h := StyleBoxFlat.new()
	style_h.bg_color = Color(0.15, 0.12, 0.25)
	style_h.border_color = COLOR_GOLD
	style_h.set_border_width_all(1)
	style_h.set_corner_radius_all(4)
	style_h.set_content_margin_all(8)

	var btn := Button.new()
	btn.text = label_text
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.add_theme_stylebox_override("normal", style_n)
	btn.add_theme_stylebox_override("hover", style_h)
	btn.add_theme_stylebox_override("pressed", style_h)
	btn.add_theme_color_override("font_color", COLOR_TEXT)
	btn.add_theme_font_size_override("font_size", 14)
	return btn


func _make_panel() -> PanelContainer:
	var style := StyleBoxFlat.new()
	style.bg_color = COLOR_PANEL
	style.border_color = COLOR_PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(16)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _make_labeled_input(label_text: String, placeholder: String, label_w: int = 100) -> Array:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size.x = label_w
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", COLOR_TEXT)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hbox.add_child(lbl)

	var style_n := StyleBoxFlat.new()
	style_n.bg_color = Color(0.10, 0.09, 0.18)
	style_n.border_color = COLOR_PANEL_BORDER
	style_n.set_border_width_all(1)
	style_n.set_corner_radius_all(4)
	style_n.set_content_margin_all(8)

	var style_f := StyleBoxFlat.new()
	style_f.bg_color = Color(0.12, 0.11, 0.22)
	style_f.border_color = COLOR_GOLD
	style_f.set_border_width_all(1)
	style_f.set_corner_radius_all(4)
	style_f.set_content_margin_all(8)

	var input := LineEdit.new()
	input.placeholder_text = placeholder
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.add_theme_stylebox_override("normal", style_n)
	input.add_theme_stylebox_override("focus", style_f)
	input.add_theme_color_override("font_color", COLOR_TEXT)
	input.add_theme_color_override("font_placeholder_color", COLOR_DIM)
	input.add_theme_font_size_override("font_size", 14)
	hbox.add_child(input)

	return [hbox, input]


func _make_button(text: String, border_color: Color) -> Button:
	var style_n := StyleBoxFlat.new()
	style_n.bg_color = Color(0.12, 0.10, 0.20)
	style_n.border_color = border_color
	style_n.set_border_width_all(1)
	style_n.set_corner_radius_all(5)
	style_n.set_content_margin_all(10)

	var style_h := StyleBoxFlat.new()
	style_h.bg_color = Color(0.20, 0.16, 0.30)
	style_h.border_color = COLOR_GOLD
	style_h.set_border_width_all(1)
	style_h.set_corner_radius_all(5)
	style_h.set_content_margin_all(10)

	var style_p := StyleBoxFlat.new()
	style_p.bg_color = Color(0.08, 0.06, 0.14)
	style_p.border_color = COLOR_RED
	style_p.set_border_width_all(1)
	style_p.set_corner_radius_all(5)
	style_p.set_content_margin_all(10)

	var style_d := StyleBoxFlat.new()
	style_d.bg_color = Color(0.08, 0.07, 0.12)
	style_d.border_color = COLOR_DIM
	style_d.set_border_width_all(1)
	style_d.set_corner_radius_all(5)
	style_d.set_content_margin_all(10)

	var btn := Button.new()
	btn.text = text
	btn.add_theme_stylebox_override("normal", style_n)
	btn.add_theme_stylebox_override("hover", style_h)
	btn.add_theme_stylebox_override("pressed", style_p)
	btn.add_theme_stylebox_override("disabled", style_d)
	btn.add_theme_color_override("font_color", COLOR_GOLD)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", COLOR_DIM)
	btn.add_theme_font_size_override("font_size", 15)
	return btn


func _add_separator(parent: Control, color: Color = COLOR_PANEL_BORDER) -> void:
	var sep := HSeparator.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_content_margin_all(0)
	sep.add_theme_stylebox_override("separator", style)
	parent.add_child(sep)


func _show_status(msg: String, color: Color = COLOR_TEXT) -> void:
	if is_instance_valid(_status_label):
		_status_label.text = msg
		_status_label.modulate = color
