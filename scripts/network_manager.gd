extends Node

# ── Сигналы ────────────────────────────────────────────────────────────────────
signal connected_to_relay
signal disconnected_from_relay
signal rooms_updated(rooms: Array)
signal joined_room(room_id: String, room_name: String, is_host: bool, players: Array)
signal player_joined(player: Dictionary)
signal player_left(player_id: String, new_host_id: String)
signal relay_received(from_id: String, data: Dictionary)
signal relay_error(message: String)
signal reconnecting(attempt: int)        # попытка переподключения
signal reconnected                        # успешно переподключились
signal rejoin_failed                      # переподключились, но комната уже не существует
signal connection_lost                    # исчерпали все попытки переподключения
signal room_deleted(reason: String)       # комната была удалена (хостом или сервером)

# Совместимость с lobby.gd
signal player_connected(id: String, info: Dictionary)
signal player_disconnected(id: String)
signal server_disconnected

# ── Состояние ──────────────────────────────────────────────────────────────────
var my_id: String = ""
var my_name: String = ""
var room_id: String = ""
var room_name: String = ""
var players: Dictionary = {}  # String -> {id, name, ready}

var _relay_url: String = "ws://localhost:3030"
var _is_host_flag: bool = false
var _ws := WebSocketPeer.new()
var _prev_state: int = WebSocketPeer.STATE_CLOSED

# Автопереподключение
const RECONNECT_DELAY := 3.0    # секунд между попытками
const RECONNECT_MAX   := 10     # после этого — сдаёмся

var _reconnect_enabled: bool = false   # включено только когда сами подключились
var _reconnect_timer: float = 0.0
var _reconnect_attempts: int = 0

# Запомненная комната для rejoin
var _saved_room_id: String = ""
var _saved_room_pass: String = ""   # пароль храним только в памяти на сессию

# Keepalive: app-level пинг каждые 20с, чтобы сервер не кикнул по heartbeat
const KEEPALIVE_INTERVAL := 20.0
var _keepalive_timer: float = KEEPALIVE_INTERVAL


# ── API ────────────────────────────────────────────────────────────────────────

func connect_to_relay(player_name: String, relay_url: String = "ws://localhost:3030") -> Error:
	my_name = player_name.strip_edges()
	_relay_url = relay_url.strip_edges()
	my_id = ""
	room_id = ""
	room_name = ""
	players.clear()
	_is_host_flag = false
	_reconnect_enabled = true
	_reconnect_attempts = 0
	_reconnect_timer = 0.0
	_prev_state = WebSocketPeer.STATE_CLOSED
	return _do_connect()


func disconnect_from_relay() -> void:
	_reconnect_enabled = false
	_saved_room_id = ""
	_saved_room_pass = ""
	room_id = ""
	room_name = ""
	players.clear()
	_ws.close()
	_prev_state = WebSocketPeer.STATE_CLOSED


func list_rooms() -> void:
	_send({"type": "list_rooms"})


func create_room(p_room_name: String, password: String = "", max_players: int = 8) -> void:
	_saved_room_pass = password   # запомним пароль для rejoin
	_send({"type": "create_room", "room_name": p_room_name, "password": password, "max_players": max_players})


func join_room(p_room_id: String, password: String = "") -> void:
	_saved_room_pass = password
	_send({"type": "join_room", "room_id": p_room_id, "password": password})


func leave_room() -> void:
	if not room_id.is_empty():
		_send({"type": "leave_room"})
	room_id = ""
	room_name = ""
	_saved_room_id = ""
	_saved_room_pass = ""
	players.clear()
	_is_host_flag = false


func delete_room() -> void:
	if not _is_host_flag:
		return
	_send({"type": "delete_room"})
	# Локально сбрасываем состояние сразу
	room_id = ""
	room_name = ""
	_saved_room_id = ""
	_saved_room_pass = ""
	players.clear()
	_is_host_flag = false


func relay_all(data: Dictionary) -> void:
	_send({"type": "relay", "data": data})


func relay_to(player_id: String, data: Dictionary) -> void:
	_send({"type": "relay_to", "to": player_id, "data": data})


func is_connected_to_relay() -> bool:
	return _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


func is_reconnecting() -> bool:
	return _reconnect_enabled and (_reconnect_timer > 0.0 or _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING)


func has_session() -> bool:
	## Был ли игрок когда-либо подключён в этой сессии (имя задано)
	return not my_name.is_empty()


func is_host() -> bool:
	return _is_host_flag


# ── Godot lifecycle ────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	var cur_state: int = _ws.get_ready_state()

	# Таймер переподключения
	if _reconnect_timer > 0.0:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0.0:
			_attempt_reconnect()
		return

	if cur_state == WebSocketPeer.STATE_CLOSED and _prev_state == WebSocketPeer.STATE_CLOSED:
		return

	_ws.poll()
	cur_state = _ws.get_ready_state()

	# Изменение состояния
	if cur_state != _prev_state:
		match cur_state:
			WebSocketPeer.STATE_OPEN:
				_on_ws_open()
			WebSocketPeer.STATE_CLOSED:
				if _prev_state != WebSocketPeer.STATE_CLOSED:
					_on_ws_closed()
		_prev_state = cur_state

	# Keepalive: app-level пинг, чтобы сервер не кикнул по heartbeat
	if cur_state == WebSocketPeer.STATE_OPEN:
		_keepalive_timer -= delta
		if _keepalive_timer <= 0.0:
			_keepalive_timer = KEEPALIVE_INTERVAL
			_send({"type": "ping"})

	# Чтение пакетов
	while _ws.get_available_packet_count() > 0:
		var raw: PackedByteArray = _ws.get_packet()
		var text: String = raw.get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			_handle_message(parsed as Dictionary)


# ── WebSocket события ─────────────────────────────────────────────────────────

func _on_ws_open() -> void:
	_reconnect_attempts = 0
	_keepalive_timer = KEEPALIVE_INTERVAL
	var hello: Dictionary = {"type": "hello", "name": my_name}
	var auth: Node = get_node_or_null("/root/AuthManager")
	if auth and not (auth as Node).get("session_token").is_empty():
		hello["token"] = (auth as Node).get("session_token")
	_send(hello)
	# Если были в комнате — попробуем войти обратно
	if not _saved_room_id.is_empty():
		_send({"type": "join_room", "room_id": _saved_room_id, "password": _saved_room_pass})


func _on_ws_closed() -> void:
	disconnected_from_relay.emit()
	server_disconnected.emit()
	if _reconnect_enabled and _reconnect_attempts < RECONNECT_MAX:
		_schedule_reconnect()


func _schedule_reconnect() -> void:
	_reconnect_attempts += 1
	_reconnect_timer = RECONNECT_DELAY
	reconnecting.emit(_reconnect_attempts)
	print("[NM] Relay disconnected, reconnect attempt %d in %.0fs..." % [_reconnect_attempts, RECONNECT_DELAY])


func _attempt_reconnect() -> void:
	if not _reconnect_enabled:
		return
	_ws = WebSocketPeer.new()
	_prev_state = WebSocketPeer.STATE_CLOSED
	var err: Error = _do_connect()
	if err != OK:
		# Не удалось — запланируем ещё раз
		if _reconnect_attempts < RECONNECT_MAX:
			_schedule_reconnect()
		else:
			_reconnect_enabled = false
			print("[NM] Gave up reconnecting after %d attempts" % RECONNECT_MAX)
			connection_lost.emit()


func _do_connect() -> Error:
	_ws = WebSocketPeer.new()
	var err: int = _ws.connect_to_url(_relay_url)
	if err == OK:
		_prev_state = WebSocketPeer.STATE_CONNECTING
	return err as Error


# ── Обработка сообщений ────────────────────────────────────────────────────────

func _handle_message(msg: Dictionary) -> void:
	var msg_type: String = msg.get("type", "")
	match msg_type:

		"pong":
			pass  # keepalive acknowledged

		"welcome":
			my_id = msg.get("your_id", "")
			if _saved_room_id.is_empty():
				# Обычное первое подключение
				connected_to_relay.emit()
			else:
				# Переподключились — сигнал reconnected придёт после joined_room
				pass

		"rooms_list":
			rooms_updated.emit(msg.get("rooms", []))

		"room_created":
			pass  # immediately followed by joined_room

		"joined_room":
			var was_reconnect: bool = not _saved_room_id.is_empty() and _saved_room_id == msg.get("room_id", "")
			room_id = msg.get("room_id", "")
			room_name = msg.get("room_name", "")
			_is_host_flag = msg.get("is_host", false)
			_saved_room_id = room_id   # обновляем на случай смены
			players.clear()
			var raw_players: Array = msg.get("players", [])
			for i in range(raw_players.size()):
				var p: Dictionary = raw_players[i]
				var pid: String = p.get("id", "")
				players[pid] = {"id": pid, "name": p.get("name", ""), "ready": false}
			if was_reconnect:
				reconnected.emit()
			else:
				connected_to_relay.emit()
			joined_room.emit(room_id, room_name, _is_host_flag, raw_players)

		"player_joined":
			var p: Dictionary = msg.get("player", {})
			var pid: String = p.get("id", "")
			players[pid] = {"id": pid, "name": p.get("name", ""), "ready": false}
			GameConsole.log("%s зашёл в комнату" % p.get("name", pid))
			player_joined.emit(p)
			player_connected.emit(pid, players[pid])

		"player_left":
			var pid: String = msg.get("player_id", "")
			var new_host: String = msg.get("new_host_id", "")
			var pname: String = players.get(pid, {}).get("name", pid)
			if players.has(pid):
				players.erase(pid)
			if not new_host.is_empty() and new_host == my_id:
				_is_host_flag = true
				GameConsole.log("%s вышел  ·  вы стали ведущим" % pname)
			else:
				GameConsole.log("%s вышел из комнаты" % pname)
			player_left.emit(pid, new_host)
			player_disconnected.emit(pid)

		"relay":
			var from_id: String = msg.get("from_id", "")
			var data: Dictionary = msg.get("data", {})
			relay_received.emit(from_id, data)
			var action: String = data.get("action", "")
			if action == "set_ready":
				var pid: String = data.get("player_id", "")
				if players.has(pid):
					players[pid]["ready"] = true
			elif action == "start_game":
				SceneManager.go("world_map")

		"room_deleted":
			room_id = ""
			room_name = ""
			_saved_room_id = ""
			_saved_room_pass = ""
			players.clear()
			_is_host_flag = false
			room_deleted.emit(msg.get("reason", "Комната закрыта"))

		"error":
			var err_msg: String = msg.get("message", "Ошибка сервера")
			# Если rejoin провалился — комнаты больше нет, сбрасываем
			if not _saved_room_id.is_empty():
				_saved_room_id = ""
				_saved_room_pass = ""
				room_id = ""
				room_name = ""
				players.clear()
				_is_host_flag = false
				rejoin_failed.emit()
			else:
				relay_error.emit(err_msg)


# ── Внутренние методы ──────────────────────────────────────────────────────────

func _send(data: Dictionary) -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_ws.send_text(JSON.stringify(data))
