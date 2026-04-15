extends Control

const InvestigatorPickerScene = preload("res://scenes/investigator_picker.tscn")

# ── Ссылки ─────────────────────────────────────────────────────────────────────
var _nm: Node
var _player_list:      VBoxContainer
var _start_button:     Button
var _ready_button:     Button
var _status_label:     Label
var _room_label:       Label
var _player_rows:      Dictionary = {}  # pid -> HBoxContainer
var _player_tags:      Dictionary = {}  # pid -> Label (статус)
var _player_inv_lbls:  Dictionary = {}  # pid -> Label (сыщик)
var _player_names:     Dictionary = {}  # pid -> String  (для лога при выходе)
var _reconnect_overlay: Control

# Нетипизированная переменная — class_name убран из пикера во избежание
# конфликта "hides a global script class" при preload + class_name
var _picker     = null   # InvestigatorPicker instance
var _was_ready: bool = false

# ── Персистентность состояния лобби ───────────────────────────────────────────

const _PREFS_PATH    := "user://dark_omens_prefs.cfg"
const _PREFS_SECTION := "lobby"


func _save_ready_state() -> void:
	var cfg := ConfigFile.new()
	cfg.load(_PREFS_PATH)
	cfg.set_value(_PREFS_SECTION, "room_id",   _nm.room_id)
	cfg.set_value(_PREFS_SECTION, "was_ready", true)
	cfg.save(_PREFS_PATH)


func _clear_ready_state() -> void:
	var cfg := ConfigFile.new()
	cfg.load(_PREFS_PATH)
	cfg.set_value(_PREFS_SECTION, "was_ready", false)
	cfg.save(_PREFS_PATH)


func _check_auto_ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_PREFS_PATH) != OK:
		return
	var saved_room:  String = cfg.get_value(_PREFS_SECTION, "room_id",   "")
	var saved_ready: bool   = cfg.get_value(_PREFS_SECTION, "was_ready", false)
	if not saved_ready or saved_room != _nm.room_id:
		return
	if not is_instance_valid(_picker):
		return
	var selected: String = _picker.get_selected()
	if selected.is_empty():
		return
	# Уже были готовы в этой комнате — сообщаем статус остальным и сразу на карту
	_was_ready = true
	if _nm.players.has(_nm.my_id):
		_nm.players[_nm.my_id]["ready"]       = true
		_nm.players[_nm.my_id]["investigator"] = selected
	_nm.relay_all({"action": "set_ready", "player_id": _nm.my_id, "investigator": selected})
	SceneManager.go("world_map")


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
	GameConsole.log("Комната «%s» — вы вошли (%s)" % [
		_nm.room_name,
		"ведущий" if _nm.is_host() else "игрок"
	])
	_check_auto_ready()


# ── Построение UI ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	UIStyle.apply_bg(self)

	# Заполняем весь экран с отступами — без ScrollContainer,
	# чтобы пикер мог получить SIZE_EXPAND_FILL по вертикали
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left",   80)
	margin.add_theme_constant_override("margin_right",  80)
	margin.add_theme_constant_override("margin_top",    24)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)

	var root_vbox := VBoxContainer.new()
	root_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	root_vbox.add_theme_constant_override("separation", 14)
	margin.add_child(root_vbox)

	# ── Заголовок ──
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

	# ── Список игроков ──
	var players_panel := UIStyle.panel(16)
	root_vbox.add_child(players_panel)

	var panel_vbox := VBoxContainer.new()
	panel_vbox.add_theme_constant_override("separation", 8)
	players_panel.add_child(panel_vbox)

	var list_header := Label.new()
	list_header.text = "ИГРОКИ В ЛОББИ"
	list_header.add_theme_font_size_override("font_size", 13)
	list_header.add_theme_color_override("font_color", UIColors.MUTED)
	panel_vbox.add_child(list_header)

	UIStyle.separator(panel_vbox)

	_player_list = VBoxContainer.new()
	_player_list.add_theme_constant_override("separation", 6)
	panel_vbox.add_child(_player_list)

	UIStyle.separator(root_vbox)

	# ── Выбор сыщика ──
	var picker_header := Label.new()
	picker_header.text = "ВЫБЕРИТЕ СЫЩИКА"
	picker_header.add_theme_font_size_override("font_size", 13)
	picker_header.add_theme_color_override("font_color", UIColors.MUTED)
	root_vbox.add_child(picker_header)

	_picker = InvestigatorPickerScene.instantiate()
	_picker.investigator_selected.connect(_on_investigator_selected)
	_picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(_picker)

	UIStyle.separator(root_vbox)

	# ── Кнопки ──
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
	_ready_button.disabled = true
	_ready_button.pressed.connect(_on_ready_pressed)
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

	var bottom_pad := Control.new()
	bottom_pad.custom_minimum_size.y = 24
	root_vbox.add_child(bottom_pad)

	_refresh_start_button()


# ── Выбор сыщика ─────────────────────────────────────────────────────────────

func _on_investigator_selected(_inv_name: String) -> void:
	if is_instance_valid(_ready_button) and not _was_ready:
		_ready_button.disabled = false
	_refresh_start_button()


# ── Список игроков ────────────────────────────────────────────────────────────

func _update_room_label() -> void:
	if not is_instance_valid(_room_label):
		return
	if _nm.is_host():
		_room_label.text = "Комната: %s  •  Вы — ведущий игры  •  Ожидание участников..." % _nm.room_name
	else:
		_room_label.text = "Комната: %s  •  Ожидайте начала игры" % _nm.room_name


func _populate_players() -> void:
	for pid: String in _nm.players:
		var info: Dictionary = _nm.players[pid]
		_add_player_row(pid, info)
		# Логируем всех кроме себя — они уже были в комнате до нашего входа
		if pid != _nm.my_id:
			GameConsole.log("%s уже в комнате" % info.get("name", pid))
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

	var name_vbox := VBoxContainer.new()
	name_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_vbox.add_theme_constant_override("separation", 2)
	row.add_child(name_vbox)

	var name_lbl := Label.new()
	name_lbl.text = info.get("name", "???")
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	name_vbox.add_child(name_lbl)

	var inv_lbl := Label.new()
	inv_lbl.add_theme_font_size_override("font_size", 11)
	inv_lbl.add_theme_color_override("font_color", UIColors.ACCENT)
	name_vbox.add_child(inv_lbl)
	_player_inv_lbls[id] = inv_lbl

	var tag := Label.new()
	tag.add_theme_font_size_override("font_size", 13)
	tag.custom_minimum_size.x = 90
	if is_me_host:
		tag.text = "Ведущий"
		tag.add_theme_color_override("font_color", UIColors.ACCENT)
	elif info.get("ready", false):
		tag.text = "Готов ✓"
		tag.add_theme_color_override("font_color", UIColors.READY)
	else:
		tag.text = "Ожидает..."
		tag.add_theme_color_override("font_color", UIColors.MUTED)
	row.add_child(tag)
	_player_tags[id] = tag

	_player_list.add_child(row)
	_player_rows[id] = row
	_player_names[id] = info.get("name", id)


func _remove_player_row(id: String) -> void:
	if _player_rows.has(id):
		(_player_rows[id] as Node).queue_free()
		_player_rows.erase(id)
		_player_tags.erase(id)
		_player_inv_lbls.erase(id)
		_player_names.erase(id)


func _update_row_ready(id: String, is_ready: bool, inv_name: String = "") -> void:
	if _player_tags.has(id):
		var tag := _player_tags[id] as Label
		if is_ready:
			tag.text = "Готов ✓"
			tag.add_theme_color_override("font_color", UIColors.READY)
		else:
			tag.text = "Ожидает..."
			tag.add_theme_color_override("font_color", UIColors.MUTED)
	if not inv_name.is_empty() and _player_inv_lbls.has(id):
		(_player_inv_lbls[id] as Label).text = inv_name


func _refresh_start_button() -> void:
	var selected: String = _picker.get_selected() if is_instance_valid(_picker) else ""

	if not _nm.is_host() or not is_instance_valid(_start_button):
		if is_instance_valid(_status_label) and not _nm.is_host():
			if selected.is_empty():
				_status_label.text = "Выберите сыщика, затем нажмите «Готов»"
			elif not _was_ready:
				_status_label.text = "Нажмите «Готов», чтобы подтвердить выбор"
			else:
				_status_label.text = "Ожидайте решения ведущего"
			_status_label.modulate = UIColors.MUTED
		return

	var non_host: int = _nm.players.size() - 1
	if selected.is_empty():
		_start_button.disabled = true
		_status_label.text     = "Выберите своего сыщика"
		_status_label.modulate = UIColors.WARNING
	elif not _was_ready:
		_start_button.disabled = true
		_status_label.text     = "Нажмите «Готов», затем можно начинать"
		_status_label.modulate = UIColors.WARNING
	else:
		_start_button.disabled = false
		_status_label.text     = "Игроков: %d  •  Можно начинать!" % _nm.players.size()
		_status_label.modulate = UIColors.READY


# ── Обработчики сигналов ──────────────────────────────────────────────────────

func _on_player_connected(id: String, info: Dictionary) -> void:
	_add_player_row(id, info)
	_refresh_start_button()
	# Если уже нажали «Готов» — сообщаем новому игроку наш статус напрямую,
	# он мог зайти уже после того как мы отправили relay_all
	if _was_ready and is_instance_valid(_picker):
		var selected: String = _picker.get_selected()
		if not selected.is_empty():
			_nm.relay_to(id, {"action": "set_ready", "player_id": _nm.my_id, "investigator": selected})


func _on_player_disconnected(id: String) -> void:
	_remove_player_row(id)
	_refresh_start_button()


func _on_player_left_relay(player_id: String, new_host_id: String) -> void:
	_remove_player_row(player_id)
	if new_host_id == _nm.my_id:
		_update_room_label()
	_refresh_start_button()


func _on_reconnecting(attempt: int) -> void:
	GameConsole.warn("Соединение потеряно — попытка переподключения %d" % attempt)
	_show_reconnect_overlay("Соединение потеряно\nПереподключение... (попытка %d)" % attempt)


func _on_reconnected() -> void:
	GameConsole.log("Переподключились к комнате «%s»" % _nm.room_name)
	_hide_reconnect_overlay()
	for pid: String in _player_rows.keys():
		if not _nm.players.has(pid):
			_remove_player_row(pid)
	for pid: String in _nm.players:
		if not _player_rows.has(pid):
			_add_player_row(pid, _nm.players[pid])
	_refresh_start_button()
	# Если до разрыва уже нажали «Готов» — повторно отправляем серверу
	if _was_ready:
		_resend_ready()


func _on_rejoin_failed() -> void:
	_show_reconnect_overlay("Комната не найдена\nВозврат в главное меню...")
	await get_tree().create_timer(2.0).timeout
	SceneManager.go("main_menu")


func _on_connection_lost() -> void:
	_show_reconnect_overlay("Нет связи с сервером\nВозврат в главное меню...")
	await get_tree().create_timer(3.0).timeout
	SceneManager.go("main_menu")


func _on_server_disconnected() -> void:
	pass  # ждём reconnecting/reconnected/rejoin_failed/connection_lost


func _on_relay_received(_from_id: String, data: Dictionary) -> void:
	match data.get("action", ""):
		"set_ready":
			var pid: String      = data.get("player_id", "")
			var inv_name: String = data.get("investigator", "")
			if _nm.players.has(pid):
				_nm.players[pid]["ready"] = true
				if not inv_name.is_empty():
					_nm.players[pid]["investigator"] = inv_name
			_update_row_ready(pid, true, inv_name)
			_refresh_start_button()
			var pname: String = _player_names.get(pid, pid)
			GameConsole.log("%s готов  ·  сыщик: %s" % [pname, inv_name])
		"start_game":
			SceneManager.go("world_map")


# ── Обработчики кнопок ────────────────────────────────────────────────────────

func _on_back_pressed() -> void:
	GameConsole.log("Вы покинули комнату «%s»" % _nm.room_name)
	_clear_ready_state()
	_nm.leave_room()
	SceneManager.go("main_menu")


func _on_delete_room_pressed() -> void:
	GameConsole.log("Комната «%s» закрыта ведущим" % _nm.room_name)
	_clear_ready_state()
	_nm.delete_room()
	SceneManager.go("main_menu")


func _on_room_deleted(reason: String) -> void:
	GameConsole.warn("Комната удалена: %s" % reason)
	_show_reconnect_overlay("Комната закрыта: %s\nВозврат в меню..." % reason)
	await get_tree().create_timer(1.5).timeout
	SceneManager.go("main_menu")


func _on_ready_pressed() -> void:
	var selected: String = _picker.get_selected()
	if selected.is_empty():
		return
	_was_ready = true
	_save_ready_state()
	GameConsole.log("Вы готовы  ·  сыщик: %s" % selected)
	if is_instance_valid(_ready_button):
		_ready_button.disabled = true
		_ready_button.text     = "  ГОТОВ  ✓"
	_update_row_ready(_nm.my_id, true, selected)
	if _nm.players.has(_nm.my_id):
		_nm.players[_nm.my_id]["ready"]       = true
		_nm.players[_nm.my_id]["investigator"] = selected
	# Хост тоже рассылает — другие игроки увидят его статус и сыщика
	_nm.relay_all({"action": "set_ready", "player_id": _nm.my_id, "investigator": selected})
	_refresh_start_button()


func _resend_ready() -> void:
	var selected: String = _picker.get_selected()
	if selected.is_empty():
		return
	if _nm.players.has(_nm.my_id):
		_nm.players[_nm.my_id]["ready"]       = true
		_nm.players[_nm.my_id]["investigator"] = selected
	_update_row_ready(_nm.my_id, true, selected)
	_nm.relay_all({"action": "set_ready", "player_id": _nm.my_id, "investigator": selected})


func _on_start_pressed() -> void:
	if not _nm.is_host():
		return
	var selected: String = _picker.get_selected()
	if selected.is_empty():
		return
	if _nm.players.has(_nm.my_id):
		_nm.players[_nm.my_id]["investigator"] = selected
	GameConsole.log("Игра началась! Игроков: %d" % _nm.players.size())
	_nm.relay_all({"action": "start_game"})
	SceneManager.go("world_map")


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
