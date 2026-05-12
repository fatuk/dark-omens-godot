extends Control

## Лобби комнаты — тонкая обвязка над investigator_picker.
##
## После рефакторинга весь UI лобби живёт в picker'е (full-screen overlay):
##   • выбор сыщика (карусель)
##   • заголовок с именем комнаты + ролью
##   • краткий список игроков (crown + имя), плюс модалка «Подробнее»
##   • кнопки «Назад / Готов / Начать игру»
##
## Этот скрипт держит только бизнес-логику:
##   • перс-стейт «уже нажал готов» (для авто-восстановления при перезаходе)
##   • рассылка picking/set_ready/start_game через NetworkManager.relay_all
##   • переходы между сценами при старте/выходе
##   • картинка переподключения при потере связи
##
## Никакого UI здесь больше нет — picker сам строит и обновляет всё своё
## поверх NetworkManager.players (он подписан на те же сигналы).

const _PREFS_PATH    := "user://dark_omens_prefs.cfg"
const _PREFS_SECTION := "lobby"

@onready var _picker: Node = %Picker

# ── Состояние ─────────────────────────────────────────────────────────────────
var _nm: Node
var _was_ready: bool = false
var _reconnect_overlay: Control

# pid → имя (для красивого лога при выходе игрока)
var _player_names: Dictionary = {}


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

	_picker.investigator_selected.connect(_on_investigator_selected)
	# Picker — это весь UI лобби; его кнопки дёргают здешние обработчики.
	if _picker.has_signal("back_pressed"):
		_picker.back_pressed.connect(_on_back_pressed)
	if _picker.has_signal("confirm_pressed"):
		_picker.confirm_pressed.connect(_on_ready_pressed)
	if _picker.has_signal("start_pressed"):
		_picker.start_pressed.connect(_on_start_pressed)

	# Восстановим имена игроков (нужны при логе ухода).
	for pid: String in _nm.players.keys():
		_player_names[pid] = _nm.players[pid].get("name", pid)

	# Восстановим occupancy сыщиков для уже готовых игроков.
	for pid: String in _nm.players.keys():
		var info: Dictionary = _nm.players[pid]
		if pid != _nm.my_id and info.get("ready", false):
			var inv: String = info.get("investigator", "")
			if not inv.is_empty():
				_picker.mark_taken(inv, info.get("name", pid))

	_refresh_start_button()

	GameConsole.log("Комната «%s» — вы вошли (%s)" % [
		_nm.room_name,
		"ведущий" if _nm.is_host() else "игрок"
	])
	# Откладываем: picker сам откладывает автовыбор сохранённого сыщика,
	# чтобы успели расставиться mark_taken. Auto-ready должен бежать после.
	call_deferred("_check_auto_ready")
	# Прыгаем на карту только если игра уже идёт И мы УЖЕ были в этой сессии
	# (сервер восстановил наш investigator из game_players).
	var my_pdata: Dictionary = _nm.players.get(_nm.my_id, {})
	var my_inv:   String     = my_pdata.get("investigator", "")
	if _nm.game_started and not my_inv.is_empty():
		GameConsole.log("Игра уже идёт, у нас есть сыщик — переходим на карту")
		SceneManager.go("world_map")


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
	# но НЕ переходим сразу: ждём start_game от хоста (или сами нажмём «Начать»).
	_was_ready = true
	if _nm.players.has(_nm.my_id):
		_nm.players[_nm.my_id]["ready"]        = true
		_nm.players[_nm.my_id]["investigator"] = selected
	_picker.lock_confirm()
	_nm.relay_all({"action": "set_ready", "player_id": _nm.my_id, "investigator": selected})
	_refresh_start_button()


# ── Выбор сыщика ─────────────────────────────────────────────────────────────

func _on_investigator_selected(inv_name: String) -> void:
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


# Хост: разрешать «Начать», когда выбрал сыщика и подтвердил.
func _refresh_start_button() -> void:
	if not _nm.is_host() or not is_instance_valid(_picker):
		return
	var selected: String = _picker.get_selected()
	_picker.set_start_enabled(not selected.is_empty() and _was_ready)


# ── Обработчики сигналов NetworkManager ───────────────────────────────────────

func _on_player_connected(id: String, info: Dictionary) -> void:
	_player_names[id] = info.get("name", id)
	_refresh_start_button()


func _on_player_disconnected(id: String) -> void:
	_release_player_investigator(id)
	_player_names.erase(id)
	_refresh_start_button()


func _on_player_left_relay(player_id: String, _new_host_id: String) -> void:
	_release_player_investigator(player_id)
	_player_names.erase(player_id)
	_refresh_start_button()


# Освобождаем сыщика ушедшего игрока, чтобы он стал доступен другим.
func _release_player_investigator(id: String) -> void:
	if not is_instance_valid(_picker) or not _nm.players.has(id):
		return
	var inv: String = _nm.players[id].get("investigator", "")
	if not inv.is_empty():
		_picker.mark_available(inv)


func _on_reconnecting(attempt: int) -> void:
	GameConsole.warn("Соединение потеряно — попытка переподключения %d" % attempt)
	_show_reconnect_overlay("Соединение потеряно\nПереподключение... (попытка %d)" % attempt)


func _on_reconnected() -> void:
	GameConsole.log("Переподключились к комнате «%s»" % _nm.room_name)
	_hide_reconnect_overlay()
	# Картинка игроков обновится сама — picker подписан на NM.player_connected/left.
	_refresh_start_button()
	# Если до разрыва уже нажали «Готов» — повторно отправляем серверу.
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
			var pname: String = _player_names.get(pid, pid)
			GameConsole.log("%s готов  ·  сыщик: %s" % [pname, inv_name])
			# Блокируем сыщика для остальных
			if pid != _nm.my_id and is_instance_valid(_picker):
				_picker.mark_taken(inv_name, pname)
			_refresh_start_button()
		"start_game":
			_clear_ready_state()
			SceneManager.go("world_map")


# ── Обработчики сигналов picker'а ─────────────────────────────────────────────

func _on_back_pressed() -> void:
	GameConsole.log("Вы покинули комнату «%s»" % _nm.room_name)
	_clear_ready_state()
	_nm.leave_room()
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
	_picker.lock_confirm()
	if _nm.players.has(_nm.my_id):
		_nm.players[_nm.my_id]["ready"]        = true
		_nm.players[_nm.my_id]["investigator"] = selected
	# Хост тоже рассылает — другие игроки увидят его статус и сыщика.
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
		_nm.players[_nm.my_id]["ready"]        = true
		_nm.players[_nm.my_id]["investigator"] = selected
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
	var arr: Array = DataLoader.load_array("res://data/investigators.json")
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
