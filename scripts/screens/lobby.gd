extends Control

## Лобби комнаты: список игроков, выбор сыщика, кнопки готовности.
## Разметка статичной части в scenes/lobby.tscn, тут только поведение,
## стилизация и динамические строки игроков.

const _PREFS_PATH    := "user://dark_omens_prefs.cfg"
const _PREFS_SECTION := "lobby"

# ── Узлы ──────────────────────────────────────────────────────────────────────
@onready var _bg:           ColorRect      = $Bg
@onready var _room_label:   Label          = %RoomLabel
@onready var _players_panel: PanelContainer = %PlayersPanel
@onready var _player_list:  VBoxContainer  = %PlayerList
@onready var _picker:       Node           = %Picker
@onready var _back_btn:     Button         = %BackBtn
@onready var _delete_btn:   Button         = %DeleteBtn
@onready var _ready_button: Button         = %ReadyBtn
@onready var _start_button: Button         = %StartBtn
@onready var _status_label: Label          = %StatusLabel

# ── Состояние ─────────────────────────────────────────────────────────────────
var _nm: Node
var _was_ready: bool = false
var _reconnect_overlay: Control

# Дин. словари по pid
var _player_rows:     Dictionary = {}   # pid -> HBoxContainer
var _player_tags:     Dictionary = {}   # pid -> Label (статус)
var _player_inv_lbls: Dictionary = {}   # pid -> Label (сыщик)
var _player_names:    Dictionary = {}   # pid -> String  (для лога при выходе)


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_apply_styles()

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

	_picker.investigator_selected.connect(_on_investigator_selected)

	# Кнопки видимы по роли
	_delete_btn.visible = _nm.is_host()
	_start_button.visible = _nm.is_host()

	_wire_handlers()
	_update_room_label()
	_populate_players()
	_refresh_start_button()

	GameConsole.log("Комната «%s» — вы вошли (%s)" % [
		_nm.room_name,
		"ведущий" if _nm.is_host() else "игрок"
	])
	# Откладываем: picker сам откладывает автовыбор сохранённого сыщика,
	# чтобы успели расставиться mark_taken. Auto-ready должен бежать после.
	call_deferred("_check_auto_ready")
	# Прыгаем на карту только если игра уже идёт И мы УЖЕ были в этой сессии
	# (сервер восстановил наш investigator из game_players). Иначе — новый
	# поздний игрок без сыщика; пусть выберет в лобби.
	var my_pdata: Dictionary = _nm.players.get(_nm.my_id, {})
	var my_inv:   String     = my_pdata.get("investigator", "")
	if _nm.game_started and not my_inv.is_empty():
		GameConsole.log("Игра уже идёт, у нас есть сыщик — переходим на карту")
		SceneManager.go("world_map")


# ── Стили ─────────────────────────────────────────────────────────────────────

func _apply_styles() -> void:
	_bg.color = UIColors.BG

	($Margin/Root/Title as Label).add_theme_color_override("font_color", UIColors.ACCENT)
	_room_label.add_theme_color_override("font_color", UIColors.MUTED)

	UIStyle.style_panel(_players_panel, 16)
	($Margin/Root/PlayersPanel/VBox/Header as Label) \
		.add_theme_color_override("font_color", UIColors.MUTED)

	($Margin/Root/PickerHeader as Label).add_theme_color_override("font_color", UIColors.MUTED)

	UIStyle.style_button(_back_btn,     UIColors.DANGER)
	UIStyle.style_button(_delete_btn,   UIColors.DANGER)
	UIStyle.style_button(_ready_button)
	UIStyle.style_button(_start_button, UIColors.ACCENT)

	_status_label.add_theme_color_override("font_color", UIColors.MUTED)


func _wire_handlers() -> void:
	_back_btn.pressed.connect(_on_back_pressed)
	_delete_btn.pressed.connect(_on_delete_room_pressed)
	_ready_button.pressed.connect(_on_ready_pressed)
	_start_button.pressed.connect(_on_start_pressed)


# ── Персистентность состояния лобби ───────────────────────────────────────────

func _save_ready_state() -> void:
	var cfg := ConfigFile.new()
	cfg.load(_PREFS_PATH)
	cfg.set_value(_PREFS_SECTION, "room_id",     _nm.room_id)
	cfg.set_value(_PREFS_SECTION, "was_ready",   true)
	cfg.set_value(_PREFS_SECTION, "player_name", _nm.my_name)
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
	var saved_room:   String = cfg.get_value(_PREFS_SECTION, "room_id",     "")
	var saved_ready:  bool   = cfg.get_value(_PREFS_SECTION, "was_ready",   false)
	var saved_player: String = cfg.get_value(_PREFS_SECTION, "player_name", "")
	if not saved_ready or saved_room != _nm.room_id or saved_player != _nm.my_name:
		return
	if not is_instance_valid(_picker):
		return
	var selected: String = _picker.get_selected()
	if selected.is_empty():
		return
	# Уже были готовы в этой комнате — восстанавливаем статус,
	# но НЕ переходим сразу: ждём start_game от хоста (или сами нажмём «Начать»)
	_was_ready = true
	if _nm.players.has(_nm.my_id):
		_nm.players[_nm.my_id]["ready"]       = true
		_nm.players[_nm.my_id]["investigator"] = selected
	_update_row_ready(_nm.my_id, true, selected)
	if is_instance_valid(_ready_button):
		_ready_button.disabled = true
		_ready_button.text     = "  ГОТОВ  ✓"
	_nm.relay_all({"action": "set_ready", "player_id": _nm.my_id, "investigator": selected})
	_refresh_start_button()


# ── Выбор сыщика ─────────────────────────────────────────────────────────────

func _on_investigator_selected(inv_name: String) -> void:
	if is_instance_valid(_ready_button) and not _was_ready:
		_ready_button.disabled = inv_name.is_empty()
	# Локальное состояние + броадкаст: остальные игроки сразу видят
	# нашего сыщика как занятого, не дожидаясь нажатия «Готов».
	if _nm.players.has(_nm.my_id):
		_nm.players[_nm.my_id]["investigator"] = inv_name
	_nm.relay_all({"action": "picking", "player_id": _nm.my_id, "investigator": inv_name})
	_refresh_start_button()


# Пересчитать занятость карточек по данным NetworkManager.players.
func _recompute_taken() -> void:
	if not is_instance_valid(_picker):
		return
	var taken: Dictionary = {}
	for pid: String in _nm.players:
		if pid == _nm.my_id:
			continue
		var inv: String = _nm.players[pid].get("investigator", "")
		if not inv.is_empty():
			taken[inv] = _nm.players[pid].get("name", pid)
	_picker.sync_taken(taken)


# ── Список игроков ────────────────────────────────────────────────────────────

func _update_room_label() -> void:
	if not is_instance_valid(_room_label):
		return
	if _nm.is_host():
		_room_label.text = "Комната: %s  •  Вы — ведущий игры  •  Ожидание участников..." % _nm.room_name
	else:
		_room_label.text = "Комната: %s  •  Ожидайте начала игры" % _nm.room_name


func _populate_players() -> void:
	GameConsole.log("[DEBUG] players при загрузке лобби: %s" % JSON.stringify(_nm.players))
	for pid: String in _nm.players:
		var info: Dictionary = _nm.players[pid]
		_add_player_row(pid, info)
		if pid != _nm.my_id:
			GameConsole.log("%s уже в комнате" % info.get("name", pid))
		# Применяем ready-стейт, который пришёл с сервера в joined_room
		if pid != _nm.my_id:
			var inv: String = info.get("investigator", "")
			var rdy: bool   = info.get("ready", false)
			if rdy:
				_update_row_ready(pid, true, inv)
				if not inv.is_empty() and is_instance_valid(_picker):
					_picker.mark_taken(inv, info.get("name", pid))


func _add_player_row(id: String, info: Dictionary) -> void:
	if _player_rows.has(id):
		return

	var row := HBoxContainer.new()
	row.name = "Player_" + id
	row.add_theme_constant_override("separation", 10)

	var is_me_host: bool = id == _nm.my_id and _nm.is_host()
	var crown := Label.new()
	crown.name = "Crown"
	crown.text = "♛" if is_me_host else "◆"
	crown.add_theme_font_size_override("font_size", 14)
	crown.add_theme_color_override("font_color", UIColors.ACCENT if is_me_host else UIColors.MUTED)
	crown.custom_minimum_size.x = 24
	row.add_child(crown)

	var name_vbox := VBoxContainer.new()
	name_vbox.name = "NameVBox"
	name_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_vbox.add_theme_constant_override("separation", 2)
	row.add_child(name_vbox)

	var name_lbl := Label.new()
	name_lbl.name = "Name"
	name_lbl.text = info.get("name", "???")
	name_lbl.add_theme_font_size_override("font_size", 16)
	name_lbl.add_theme_color_override("font_color", UIColors.TEXT)
	name_vbox.add_child(name_lbl)

	var inv_lbl := Label.new()
	inv_lbl.name = "Investigator"
	inv_lbl.add_theme_font_size_override("font_size", 11)
	inv_lbl.add_theme_color_override("font_color", UIColors.ACCENT)
	name_vbox.add_child(inv_lbl)
	_player_inv_lbls[id] = inv_lbl

	var tag := Label.new()
	tag.name = "Tag"
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
	# Освобождаем сыщика ушедшего игрока
	if is_instance_valid(_picker) and _nm.players.has(id):
		var inv: String = _nm.players[id].get("investigator", "")
		if not inv.is_empty():
			_picker.mark_available(inv)
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

	if not _nm.is_host():
		if selected.is_empty():
			_status_label.text = "Выберите сыщика, затем нажмите «Готов»"
		elif not _was_ready:
			_status_label.text = "Нажмите «Готов», чтобы подтвердить выбор"
		else:
			_status_label.text = "Ожидайте решения ведущего"
		_status_label.modulate = UIColors.MUTED
		return

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


# ── Обработчики сигналов NetworkManager ───────────────────────────────────────

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
		"picking":
			var pid: String = data.get("player_id", "")
			var inv: String = data.get("investigator", "")
			if _nm.players.has(pid):
				_nm.players[pid]["investigator"] = inv
			_recompute_taken()
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
			# Блокируем сыщика для остальных
			if pid != _nm.my_id and is_instance_valid(_picker):
				_picker.mark_taken(inv_name, pname)
		"start_game":
			_clear_ready_state()
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
	# Если игра уже идёт (мы поздний игрок) — хост не нажмёт «Начать», он уже
	# на карте. Прыгаем на карту сами, как только подтвердили выбор сыщика.
	if _nm.game_started:
		GameConsole.log("Игра уже идёт — присоединяемся на карте")
		_clear_ready_state()
		SceneManager.go("world_map")


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
	_clear_ready_state()
	# Инициализируем игровое состояние ДО рассылки start_game и перехода —
	# game_sync от хоста уйдёт раньше, чем не-хосты получат start_game и
	# переключатся на world_map (WebSocket FIFO).
	GameState.start_game(_build_players_init())
	_nm.relay_all({"action": "start_game"})
	SceneManager.go("world_map")


func _build_players_init() -> Array:
	# Читаем investigators.json для HP/Sanity max каждого выбранного сыщика.
	var inv_data: Dictionary = _load_investigators_index()
	var arr: Array = []
	for pid: String in _nm.players:
		var info: Dictionary = _nm.players[pid]
		var inv_name: String = info.get("investigator", "")
		var inv: Dictionary  = inv_data.get(inv_name, {})
		arr.append({
			"pid":          pid,
			"user_id":      pid,
			"name":         info.get("name", "???"),
			"investigator": inv_name,
			"hp_max":       int(inv.get("health", 5)),
			"sanity_max":   int(inv.get("sanity", 5)),
		})
	return arr


func _load_investigators_index() -> Dictionary:
	var text: String = FileAccess.get_file_as_string("res://data/investigators.json")
	if text.is_empty():
		return {}
	var arr: Variant = JSON.parse_string(text)
	if not arr is Array:
		return {}
	var idx: Dictionary = {}
	for inv: Dictionary in arr:
		idx[inv.get("name", "")] = inv
	return idx


# ── Оверлей переподключения ──────────────────────────────────────────────────

func _show_reconnect_overlay(text: String) -> void:
	if is_instance_valid(_reconnect_overlay):
		(_reconnect_overlay.get_child(0) as Label).text = text
		return
	_reconnect_overlay = UIStyle.reconnect_overlay(self, text)


func _hide_reconnect_overlay() -> void:
	if is_instance_valid(_reconnect_overlay):
		_reconnect_overlay.queue_free()
		_reconnect_overlay = null
