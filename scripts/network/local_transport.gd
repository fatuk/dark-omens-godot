## LocalTransport — офлайн-замена RelayTransport: реле «в процессе».
##
## Отвечает тем же подмножеством протокола, что и настоящее реле (welcome,
## rooms_list, room_created + joined_room, эхо relay set_ready, error), поэтому
## NetworkManager не отличает его от сокета и игровой код не меняется. Комната
## одна, соединение одно — мы же и хост. Чужих соединений нет, так что relay /
## relay_to другим доставлять некому: start_game, game_sync, чат и лента просто
## глотаются (настоящее реле их отправителю тоже не возвращает).
##
## Ответы уходят отложенно (call_deferred) — как и по сети: NetworkManager
## никогда не получает ответ изнутри своего же send.
extends Node

signal ws_opened
signal ws_closed
signal raw_received(text: String)
# Два сигнала ниже никогда не испускаются: локальной связи нечего терять. Объявлены,
# чтобы NetworkManager подписывался на одну и ту же поверхность, что и у сокета.
@warning_ignore("unused_signal")
signal reconnecting(attempt: int)
@warning_ignore("unused_signal")
signal connection_lost

const CLIENT_ID := "local-player"
const ROOM_ID := "local-room"

var _state: int = WebSocketPeer.STATE_CLOSED
var _client_name: String = ""
var _room: Dictionary = {}  # {name, max_players, created_at}; пусто — комнаты нет
var _ready_flag: bool = false
var _investigator: String = ""
# Виртуальные клиенты (боты): [{id, name, ready, investigator}]. Сидят в комнате
# вместе с нами; их relay-сообщения заходят через inject_relay.
var _virtual: Array = []

# ── Виртуальные клиенты ───────────────────────────────────────────────────────


## Посадить виртуального игрока (бота) за стол. До создания комнаты — попадёт в
## joined_room.players; после — приходит player_joined, как при входе игрока.
func add_virtual_player(id: String, player_name: String) -> void:
	for v: Dictionary in _virtual:
		if String(v["id"]) == id:
			return
	var entry: Dictionary = {"id": id, "name": player_name, "ready": false, "investigator": ""}
	_virtual.append(entry)
	if not _room.is_empty():
		_reply({"type": "player_joined", "player": _player_entry(entry)})


## Relay-сообщение от лица виртуального клиента: доставляется хосту (нам) как
## {type: relay, from_id, data} — ровно то, что прислало бы реле от удалённого игрока.
func inject_relay(from_id: String, data: Dictionary) -> void:
	if _state != WebSocketPeer.STATE_OPEN or _room.is_empty():
		return
	if String(data.get("action", "")) == "set_ready":
		for v: Dictionary in _virtual:
			if String(v["id"]) == from_id:
				v["ready"] = true
				v["investigator"] = String(data.get("investigator", ""))
	_reply({"type": "relay", "from_id": from_id, "data": data})


func virtual_ids() -> Array:
	var out: Array = []
	for v: Dictionary in _virtual:
		out.append(String(v["id"]))
	return out


# ── Поверхность RelayTransport ────────────────────────────────────────────────


func connect_to_server(_url: String) -> Error:
	_state = WebSocketPeer.STATE_CONNECTING
	call_deferred("_open_now")
	return OK


func disconnect_from_server() -> void:
	if _state == WebSocketPeer.STATE_CLOSED:
		return
	_state = WebSocketPeer.STATE_CLOSED
	_room.clear()
	ws_closed.emit.call_deferred()


## Принять пакет от NetworkManager. Молча игнорирует, пока «сокет» не открыт.
func send_raw(data: Dictionary) -> void:
	if _state != WebSocketPeer.STATE_OPEN:
		return
	_handle(data)


func is_open() -> bool:
	return _state == WebSocketPeer.STATE_OPEN


func is_connecting_or_open() -> bool:
	return _state != WebSocketPeer.STATE_CLOSED


# ── «Сервер» ──────────────────────────────────────────────────────────────────


func _open_now() -> void:
	if _state != WebSocketPeer.STATE_CONNECTING:
		return  # disconnect_from_server успел раньше
	_state = WebSocketPeer.STATE_OPEN
	# Реле шлёт welcome сразу при подключении, ещё до hello.
	_reply({"type": "welcome", "your_id": CLIENT_ID})
	ws_opened.emit()


func _handle(msg: Dictionary) -> void:
	match String(msg.get("type", "")):
		"hello":
			_client_name = String(msg.get("name", ""))
		"ping":
			_reply({"type": "pong"})
		"list_rooms":
			_reply({"type": "rooms_list", "rooms": _rooms_summary()})
		"create_room":
			_room = {
				"name": String(msg.get("room_name", "")),
				"max_players": int(msg.get("max_players", 8)),
				"created_at": Time.get_unix_time_from_system(),
			}
			_ready_flag = false
			_investigator = ""
			_reply({"type": "room_created", "room_id": ROOM_ID, "room_name": _room["name"]})
			_reply(_joined_room())
		"join_room":
			if _room.is_empty() or String(msg.get("room_id", "")) != ROOM_ID:
				_error("Комната не найдена", "room_not_found")
			else:
				_reply(_joined_room())
		"leave_room", "delete_room":
			_room.clear()
			_ready_flag = false
			_investigator = ""
			_virtual.clear()  # стол разобран — ботов сажают заново
		"delete_any_room":
			pass
		"relay":
			if _room.is_empty():
				_error("Вы не в комнате")
				return
			var data: Dictionary = msg.get("data", {})
			if String(data.get("action", "")) == "set_ready":
				_ready_flag = true
				_investigator = String(data.get("investigator", ""))
				# Единственное relay-сообщение, которое реле возвращает отправителю.
				_reply({"type": "relay", "from_id": CLIENT_ID, "data": data})
			# Остальное адресовано другим игрокам — их нет.
		"relay_to":
			pass
		_:
			_error("Неизвестный тип сообщения")


func _joined_room() -> Dictionary:
	var players: Array = [
		{
			"id": CLIENT_ID,
			"user_id": "",
			"name": _client_name,
			"ready": _ready_flag,
			"investigator": _investigator,
		}
	]
	for v: Dictionary in _virtual:
		players.append(_player_entry(v))
	return {
		"type": "joined_room",
		"room_id": ROOM_ID,
		"room_name": _room.get("name", ""),
		"your_id": CLIENT_ID,
		"is_host": true,
		"host_id": CLIENT_ID,
		# Стол — наш: играем в свою коробку (реле прислало бы сезоны хоста).
		"seasons": Array(SeasonGate.own),
		"players": players,
		"game_started": false,
		"game_state": null,
	}


func _player_entry(v: Dictionary) -> Dictionary:
	return {
		"id": String(v["id"]),
		"user_id": "",
		"name": String(v["name"]),
		"ready": bool(v["ready"]),
		"investigator": String(v["investigator"]),
	}


func _rooms_summary() -> Array:
	if _room.is_empty():
		return []
	return [
		{
			"id": ROOM_ID,
			"name": _room.get("name", ""),
			"playerCount": 1 + _virtual.size(),
			"maxPlayers": _room.get("max_players", 8),
			"locked": false,
			"empty": false,
			"hasSavedGame": false,
			"createdAt": _room.get("created_at", 0),
			"emptyAt": null,
		}
	]


func _error(message: String, code: String = "") -> void:
	var msg: Dictionary = {"type": "error", "message": message}
	if not code.is_empty():
		msg["code"] = code
	_reply(msg)


func _reply(msg: Dictionary) -> void:
	call_deferred("_emit_raw", JSON.stringify(msg))


func _emit_raw(text: String) -> void:
	if _state == WebSocketPeer.STATE_OPEN:
		raw_received.emit(text)
