extends Control

# ── Ссылки ─────────────────────────────────────────────────────────────────────
var _nm: Node
var _player_list:      VBoxContainer
var _start_button:     Button
var _ready_button:     Button
var _status_label:     Label
var _room_label:       Label
var _player_rows:      Dictionary = {}   # String -> HBoxContainer
var _reconnect_overlay: Control


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_nm = get_node("/root/NetworkManager")
	_nm.player_connected.connect(_on_player_connected)
	_nm.player_disconnected.connect(_on_player_disconnected)
	_nm.server_disconnected.connect(_on_server_disconnected)
	_nm.player_left.connect(_on_player_left_relay)
	_nm.relay_received.connect(_on_relay_received)
	_nm.reconnecting.connect(_on_reconnecting)
	_nm.reconnected.connect(_on_reconnected)
	_nm.rejoin_failed.connect(_on_rejoin_failed)
	_nm.connection_lost.connect(_on_connection_lost)
	_nm.room_deleted.connect(_on_room_deleted)
	_build_ui()
	_populate_players()


# ── Построение UI ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	UIStyle.apply_bg(self)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var root_vbox := VBoxContainer.new()
	root_vbox.custom_minimum_size = Vector2(560, 0)
	root_vbox.add_theme_constant_override("separation", 16)
	center.add_child(root_vbox)

	# Заголовок
	var title := Label.new()
	title.text = "ТЁМНЫЕ ЗНАМЕНИЯ"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", UIColors.ACCENT)
	root_vbox.add_child(title)

	_room_label = Label.new()
	_room_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_room_label.add_theme_font_size_override("font_size", 14)
	_room_label.add_theme_color_override("font_color", UIColors.MUTED)
	_update_room_label()
	root_vbox.add_child(_room_label)

	UIStyle.separator(root_vbox)

	# Панель игроков
	var p := UIStyle.panel(18)
	root_vbox.add_child(p)

	var panel_vbox := VBoxContainer.new()
	panel_vbox.add_theme_constant_override("separation", 8)
	p.add_child(panel_vbox)

	var list_header := Label.new()
	list_header.text = "ИГРОКИ В ЛОББИ"
	list_header.add_theme_font_size_override("font_size", 14)
	list_header.add_theme_color_override("font_color", UIColors.MUTED)
	panel_vbox.add_child(list_header)

	UIStyle.separator(panel_vbox)

	_player_list = VBoxContainer.new()
	_player_list.add_theme_constant_override("separation", 6)
	panel_vbox.add_child(_player_list)

	UIStyle.separator(root_vbox)

	# Кнопки
	var buttons_row := HBoxContainer.new()
	buttons_row.add_theme_constant_override("separation", 12)
	buttons_row.alignment = BoxContainer.ALIGNMENT_CENTER
	root_vbox.add_child(buttons_row)

	var back_btn := UIStyle.button("  ПОКИНУТЬ", UIColors.DANGER)
	back_btn.pressed.connect(_on_back_pressed)
	buttons_row.add_child(back_btn)

	if _nm.is_host():
		var delete_btn := UIStyle.button("  ЗАКРЫТЬ КОМНАТУ", UIColors.DANGER)
		delete_btn.pressed.connect(_on_delete_room_pressed)
		buttons_row.add_child(delete_btn)

	_ready_button = UIStyle.button("  ГОТОВ")
	_ready_button.pressed.connect(_on_ready_pressed)
	if _nm.is_host():
		_ready_button.visible = false
	buttons_row.add_child(_ready_button)

	if _nm.is_host():
		_start_button = UIStyle.button("  НАЧАТЬ ИГРУ", UIColors.ACCENT)
		_start_button.pressed.connect(_on_start_pressed)
		_start_button.disabled = true
		buttons_row.add_child(_start_button)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", UIColors.MUTED)
	root_vbox.add_child(_status_label)

	_refresh_start_button()


func _update_room_label() -> void:
	if not is_instance_valid(_room_label):
		return
	if _nm.is_host():
		_room_label.text = "Комната: %s  •  Вы — ведущий игры  •  Ожидание участников..." % _nm.room_name
	else:
		_room_label.text = "Комната: %s  •  Ожидайте начала игры" % _nm.room_name


# ── Список игроков ─────────────────────────────────────────────────────────────

func _populate_players() -> void:
	for pid in _nm.players:
		_add_player_row(pid, _nm.players[pid])
	_refresh_start_button()


func _add_player_row(id: String, info: Dictionary) -> void:
	if _player_rows.has(id):
		return

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var is_me_host: bool = id == _nm.my_id and _nm.is_host()
	var crown := Label.new()
	crown.text = "♛" if is_me_host else "◆"
	crown.add_theme_font_size_override("font_size", 14)
	crown.add_theme_color_override("font_color", UIColors.ACCENT if is_me_host else UIColors.MUTED)
	crown.custom_minimum_size.x = 24
	row.add_child(crown)

	var name_lbl := Label.new()
	name_lbl.text = info.get("name", "???")
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	row.add_child(name_lbl)

	var tag := Label.new()
	tag.add_theme_font_size_override("font_size", 13)
	tag.custom_minimum_size.x = 90
	if is_me_host:
		tag.text = "Ведущий"
		tag.add_theme_color_override("font_color", UIColors.ACCENT)
	elif info.get("ready", false):
		tag.text = "Готов"
		tag.add_theme_color_override("font_color", UIColors.READY)
	else:
		tag.text = "Ожидает..."
		tag.add_theme_color_override("font_color", UIColors.MUTED)
	row.add_child(tag)

	_player_list.add_child(row)
	_player_rows[id] = row


func _remove_player_row(id: String) -> void:
	if _player_rows.has(id):
		(_player_rows[id] as Node).queue_free()
		_player_rows.erase(id)


func _update_row_ready(id: String, is_ready: bool) -> void:
	if not _player_rows.has(id):
		return
	var row := _player_rows[id] as HBoxContainer
	var tag  := row.get_child(2) as Label
	if is_ready:
		tag.text = "Готов"
		tag.add_theme_color_override("font_color", UIColors.READY)
	else:
		tag.text = "Ожидает..."
		tag.add_theme_color_override("font_color", UIColors.MUTED)


func _refresh_start_button() -> void:
	if not _nm.is_host() or not is_instance_valid(_start_button):
		if is_instance_valid(_status_label) and not _nm.is_host():
			_status_label.text = "Ожидайте решения ведущего"
			_status_label.modulate = UIColors.MUTED
		return
	var non_host: int = _nm.players.size() - 1
	_start_button.disabled = non_host < 1
	if non_host < 1:
		_status_label.text = "Для начала игры нужен хотя бы 1 игрок"
		_status_label.modulate = UIColors.WARNING
	else:
		_status_label.text = "Игроков: %d  •  Можно начинать!" % _nm.players.size()
		_status_label.modulate = UIColors.READY


# ── Обработчики сигналов ──────────────────────────────────────────────────────

func _on_player_connected(id: String, info: Dictionary) -> void:
	_add_player_row(id, info)
	_refresh_start_button()


func _on_player_disconnected(id: String) -> void:
	_remove_player_row(id)
	_refresh_start_button()


func _on_player_left_relay(player_id: String, new_host_id: String) -> void:
	_remove_player_row(player_id)
	if new_host_id == _nm.my_id:
		_update_room_label()
		if is_instance_valid(_ready_button):
			_ready_button.visible = false
	_refresh_start_button()


func _on_reconnecting(attempt: int) -> void:
	_show_reconnect_overlay("Соединение потеряно\nПереподключение... (попытка %d)" % attempt)


func _on_reconnected() -> void:
	_hide_reconnect_overlay()
	for pid in _player_rows.keys():
		if not _nm.players.has(pid):
			_remove_player_row(pid)
	for pid in _nm.players:
		if not _player_rows.has(pid):
			_add_player_row(pid, _nm.players[pid])
	_refresh_start_button()


func _on_rejoin_failed() -> void:
	_show_reconnect_overlay("Комната не найдена\nВозврат в главное меню...")
	await get_tree().create_timer(2.0).timeout
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_connection_lost() -> void:
	_show_reconnect_overlay("Нет связи с сервером\nВозврат в главное меню...")
	await get_tree().create_timer(3.0).timeout
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_server_disconnected() -> void:
	pass  # ждём reconnecting/reconnected/rejoin_failed/connection_lost


func _on_relay_received(_from_id: String, data: Dictionary) -> void:
	match data.get("action", ""):
		"set_ready":
			var pid: String = data.get("player_id", "")
			_update_row_ready(pid, true)
			_refresh_start_button()
		"start_game":
			get_tree().change_scene_to_file("res://board.tscn")


# ── Обработчики кнопок ────────────────────────────────────────────────────────

func _on_back_pressed() -> void:
	_nm.leave_room()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_delete_room_pressed() -> void:
	_nm.delete_room()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_room_deleted(reason: String) -> void:
	_show_reconnect_overlay("Комната закрыта: %s\nВозврат в меню..." % reason)
	await get_tree().create_timer(1.5).timeout
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_ready_pressed() -> void:
	var my_id: String = _nm.my_id
	if _nm.players.has(my_id):
		_nm.players[my_id]["ready"] = true
	_ready_button.disabled = true
	_ready_button.text = "  ГОТОВ  ✓"
	_update_row_ready(my_id, true)
	_nm.relay_all({"action": "set_ready", "player_id": my_id})
	_refresh_start_button()


func _on_start_pressed() -> void:
	if not _nm.is_host():
		return
	_nm.relay_all({"action": "start_game"})
	get_tree().change_scene_to_file("res://board.tscn")


# ── Оверлей ───────────────────────────────────────────────────────────────────

func _show_reconnect_overlay(text: String) -> void:
	if is_instance_valid(_reconnect_overlay):
		(_reconnect_overlay.get_child(0) as Label).text = text
		return
	_reconnect_overlay = UIStyle.reconnect_overlay(self, text)


func _hide_reconnect_overlay() -> void:
	if is_instance_valid(_reconnect_overlay):
		_reconnect_overlay.queue_free()
		_reconnect_overlay = null
