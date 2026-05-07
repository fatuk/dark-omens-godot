## NetworkManager — игровая логика поверх транспорта.
## Отвечает за: состояние лобби, список игроков, relay-сообщения.
## WebSocket-детали делегированы в RelayTransport (autoload).
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
signal reconnecting(attempt: int)
signal reconnected
signal rejoin_failed
signal connection_lost
signal room_deleted(reason: String)

# Совместимость с lobby.gd
signal player_connected(id: String, info: Dictionary)
signal player_disconnected(id: String)
signal server_disconnected

# ── Игровое состояние ──────────────────────────────────────────────────────────
var my_id: String = ""
var my_name: String = ""
var room_id: String = ""
var room_name: String = ""
var players: Dictionary = {}  # pid -> {id, name, ready, investigator}

var _is_host_flag: bool = false
var game_started: bool  = false  # true если игровая сессия уже запущена (из DB)

# Сохранённое состояние для rejoin при реконнекте
var _saved_room_id:    String = ""
var _saved_room_pass:  String = ""
var _saved_ready:      bool   = false
var _saved_investigator: String = ""


# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	# Должен обрабатывать сетевые события, даже когда дерево на паузе
	process_mode = Node.PROCESS_MODE_ALWAYS
	var t := _transport()
	t.ws_opened.connect(_on_ws_open)
	t.ws_closed.connect(_on_ws_closed)
	t.raw_received.connect(_on_raw_received)
	t.reconnecting.connect(func(n: int) -> void: reconnecting.emit(n))
	t.connection_lost.connect(func() -> void: connection_lost.emit())


# ── Публичный API ──────────────────────────────────────────────────────────────

func connect_to_relay(player_name: String, relay_url: String = "ws://127.0.0.1:3030") -> Error:
	my_name    = player_name.strip_edges()
	my_id      = ""
	room_id    = ""
	room_name  = ""
	players.clear()
	_is_host_flag = false
	return _transport().connect_to_server(relay_url)


func disconnect_from_relay() -> void:
	_clear_room_state()
	_transport().disconnect_from_server()


func list_rooms() -> void:
	_send({"type": "list_rooms"})


func create_room(p_room_name: String, password: String = "", max_players: int = 8) -> void:
	_saved_room_pass = password
	_send({"type": "create_room", "room_name": p_room_name, "password": password, "max_players": max_players})


func join_room(p_room_id: String, password: String = "") -> void:
	_saved_room_pass = password
	_send({"type": "join_room", "room_id": p_room_id, "password": password})


func leave_room() -> void:
	if not room_id.is_empty():
		_send({"type": "leave_room"})
	_clear_room_state()


func delete_room() -> void:
	if not _is_host_flag:
		return
	_send({"type": "delete_room"})
	_clear_room_state()


func relay_all(data: Dictionary) -> void:
	if data.get("action", "") == "set_ready":
		_saved_ready       = true
		_saved_investigator = data.get("investigator", "")
	_send({"type": "relay", "data": data})


func relay_to(player_id: String, data: Dictionary) -> void:
	_send({"type": "relay_to", "to": player_id, "data": data})


func is_connected_to_relay() -> bool:
	return _transport().is_open()


func is_reconnecting() -> bool:
	return _transport().is_connecting_or_open() or not _saved_room_id.is_empty()


func has_session() -> bool:
	return not my_name.is_empty()


func is_host() -> bool:
	return _is_host_flag


# ── Транспортные события ──────────────────────────────────────────────────────

func _on_ws_open() -> void:
	var hello: Dictionary = {"type": "hello", "name": my_name}
	var auth: Node = get_node_or_null("/root/AuthManager")
	if auth and not (auth as Node).get("session_token").is_empty():
		hello["token"] = (auth as Node).get("session_token")
	_send(hello)
	if not _saved_room_id.is_empty():
		_send({"type": "join_room", "room_id": _saved_room_id, "password": _saved_room_pass})


func _on_ws_closed() -> void:
	disconnected_from_relay.emit()
	server_disconnected.emit()


func _on_raw_received(text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		_handle_message(parsed as Dictionary)
	else:
		push_warning("[NM] Malformed message: %s" % text.left(120))


# ── Обработка сообщений ────────────────────────────────────────────────────────

func _handle_message(msg: Dictionary) -> void:
	match msg.get("type", ""):

		"pong":
			pass

		"welcome":
			my_id = msg.get("your_id", "")
			if _saved_room_id.is_empty():
				connected_to_relay.emit()

		"rooms_list":
			rooms_updated.emit(msg.get("rooms", []))

		"room_created":
			pass  # за ним сразу идёт joined_room

		"joined_room":
			var was_reconnect: bool = (
				not _saved_room_id.is_empty() and
				_saved_room_id == msg.get("room_id", "")
			)
			room_id       = msg.get("room_id", "")
			room_name     = msg.get("room_name", "")
			_is_host_flag = msg.get("is_host", false)
			game_started  = msg.get("game_started", false)
			_saved_room_id = room_id
			players.clear()
			var raw_players: Array = msg.get("players", [])
			for i in range(raw_players.size()):
				var p: Dictionary = raw_players[i]
				var pid: String   = p.get("id", "")
				players[pid] = {
					"id":           pid,
					"name":         p.get("name", ""),
					"ready":        p.get("ready", false),
					"investigator": p.get("investigator", ""),
				}
			if was_reconnect:
				reconnected.emit()
				if _saved_ready:
					_send({"type": "relay", "data": {
						"action":       "set_ready",
						"player_id":    my_id,
						"investigator": _saved_investigator,
					}})
			joined_room.emit(room_id, room_name, _is_host_flag, raw_players)

		"player_joined":
			var p: Dictionary = msg.get("player", {})
			var pid: String   = p.get("id", "")
			players[pid] = {
				"id":           pid,
				"name":         p.get("name", ""),
				"ready":        p.get("ready", false),
				"investigator": p.get("investigator", ""),
			}
			GameConsole.log("%s зашёл в комнату" % p.get("name", pid))
			player_joined.emit(p)
			player_connected.emit(pid, players[pid])

		"player_left":
			var pid: String      = msg.get("player_id", "")
			var new_host: String = msg.get("new_host_id", "")
			var pname: String    = players.get(pid, {}).get("name", pid)
			players.erase(pid)
			if not new_host.is_empty() and new_host == my_id:
				_is_host_flag = true
				GameConsole.log("%s вышел  ·  вы стали ведущим" % pname)
			else:
				GameConsole.log("%s вышел из комнаты" % pname)
			player_left.emit(pid, new_host)
			player_disconnected.emit(pid)

		"relay":
			var from_id: String  = msg.get("from_id", "")
			var data: Dictionary = msg.get("data", {})
			relay_received.emit(from_id, data)
			var action: String = data.get("action", "")
			if action == "set_ready":
				var pid: String = data.get("player_id", "")
				if players.has(pid):
					players[pid]["ready"]       = true
					players[pid]["investigator"] = data.get("investigator", players[pid].get("investigator", ""))

		"room_deleted":
			_clear_room_state()
			room_deleted.emit(msg.get("reason", "Комната закрыта"))

		"error":
			var err_msg: String = msg.get("message", "Ошибка сервера")
			if "Сессия" in err_msg and "недействительна" in err_msg:
				var auth: Node = get_node_or_null("/root/AuthManager")
				if auth:
					(auth as Node).set("session_token", "")
				print("[NM] Session expired — cleared token, will retry anonymously")
				return
			if not _saved_room_id.is_empty():
				_clear_room_state()
				rejoin_failed.emit()
			else:
				relay_error.emit(err_msg)


# ── Helpers ────────────────────────────────────────────────────────────────────

func _send(data: Dictionary) -> void:
	_transport().send_raw(data)


func _transport() -> Node:
	return get_node("/root/RelayTransport")


func _clear_room_state() -> void:
	room_id          = ""
	room_name        = ""
	_saved_room_id   = ""
	_saved_room_pass = ""
	_saved_ready     = false
	_saved_investigator = ""
	players.clear()
	_is_host_flag = false
	game_started  = false
