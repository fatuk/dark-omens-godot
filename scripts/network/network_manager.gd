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
signal player_left(player_id: String, new_host_id: String, user_id: String)
signal relay_received(from_id: String, data: Dictionary)
signal game_state_received(state: Dictionary)  # снапшот стейта от сервера
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
var my_id: String = ""  # id соединения — меняется при каждом реконнекте
var my_user_id: String = ""  # стабильный id аккаунта (relay userId); пусто → аноним
var my_name: String = ""
var room_id: String = ""
var room_name: String = ""
var players: Dictionary = {}  # pid -> {id, user_id, name, ready, investigator}

var _is_host_flag: bool = false
var _host_id: String = ""  # id соединения текущего хоста ("" — ещё неизвестен)
var game_started: bool = false  # true если игровая сессия уже запущена (из DB)

# Офлайн-режим (демо / соло без сервера): вместо сокета — LocalTransport, реле
# «в процессе». Протокол тот же, так что ниже по стеку ничего не меняется.
var local_mode: bool = false
var _local: Node = null
const _LOCAL_TRANSPORT := preload("res://scripts/network/local_transport.gd")

# Сохранённое состояние для rejoin при реконнекте
var _saved_room_id: String = ""
var _saved_room_pass: String = ""
var _saved_ready: bool = false
var _saved_investigator: String = ""

# Очередь игрового трафика (relay/relay_to), не ушедшего при закрытом сокете во
# время короткого реконнекта. Дошлётся после rejoin (_flush_outbox). Без неё
# действие, совершённое в момент разрыва, молча терялось.
const _OUTBOX_MAX := 64  # потолок очереди (защита от разбухания, если rejoin затянулся)
var _outbox: Array = []

# ── Lifecycle ──────────────────────────────────────────────────────────────────


func _ready() -> void:
	# Должен обрабатывать сетевые события, даже когда дерево на паузе
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Закрытие окна не закрываем сразу — сначала шлём leave_room (см. _notification /
	# leave_and_quit), иначе обрыв сокета уводит хоста в 12с grace вместо промоушена.
	get_tree().set_auto_accept_quit(false)
	_wire(_transport())


func _wire(t: Node) -> void:
	t.ws_opened.connect(_on_ws_open)
	t.ws_closed.connect(_on_ws_closed)
	t.raw_received.connect(_on_raw_received)
	t.reconnecting.connect(_on_transport_reconnecting)
	t.connection_lost.connect(_on_transport_lost)


func _unwire(t: Node) -> void:
	t.ws_opened.disconnect(_on_ws_open)
	t.ws_closed.disconnect(_on_ws_closed)
	t.raw_received.disconnect(_on_raw_received)
	t.reconnecting.disconnect(_on_transport_reconnecting)
	t.connection_lost.disconnect(_on_transport_lost)


func _on_transport_reconnecting(n: int) -> void:
	reconnecting.emit(n)


func _on_transport_lost() -> void:
	connection_lost.emit()


# ── Публичный API ──────────────────────────────────────────────────────────────


## Включить/выключить офлайн-режим. Рвёт текущее соединение и комнату: звать до
## connect_to_relay (url при local_mode игнорируется).
func set_local_mode(enabled: bool) -> void:
	if enabled == local_mode:
		return
	var old: Node = _transport()
	old.disconnect_from_server()
	_clear_room_state()
	_unwire(old)
	local_mode = enabled
	if enabled:
		if _local == null:
			_local = _LOCAL_TRANSPORT.new()
			_local.name = "LocalTransport"
			add_child(_local)
	elif _local != null:
		_local.queue_free()
		_local = null
	_wire(_transport())


func connect_to_relay(player_name: String, relay_url: String = "ws://127.0.0.1:3030") -> Error:
	my_name = player_name.strip_edges()
	my_id = ""
	my_user_id = ""
	room_id = ""
	room_name = ""
	players.clear()
	_is_host_flag = false
	_host_id = ""
	_outbox.clear()
	return _transport().connect_to_server(relay_url)


func disconnect_from_relay() -> void:
	_clear_room_state()
	_transport().disconnect_from_server()


func list_rooms() -> void:
	_send({"type": "list_rooms"})


func create_room(p_room_name: String, password: String = "", max_players: int = 8) -> void:
	_saved_room_pass = password
	_send(
		{
			"type": "create_room",
			"room_name": p_room_name,
			"password": password,
			"max_players": max_players
		}
	)


func join_room(p_room_id: String, password: String = "") -> void:
	_saved_room_pass = password
	_send({"type": "join_room", "room_id": p_room_id, "password": password})


func leave_room() -> void:
	if not room_id.is_empty():
		_send({"type": "leave_room"})
	_clear_room_state()


# Закрытие окна (крестик / Alt+F4) — как намеренный выход: leave_and_quit.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		leave_and_quit()


## Намеренный выход из приложения (кнопка «Выход» / закрытие окна): шлём leave_room,
## чтобы relay промоутил нового хоста СРАЗУ (без 12с grace транзиентного обрыва),
## даём сокету флашнуться (transport поллит и на паузе — PROCESS_MODE_ALWAYS), затем
## закрываем. process_always-таймер тикает даже при get_tree().paused.
func leave_and_quit() -> void:
	if not room_id.is_empty():
		_send({"type": "leave_room"})
		_clear_room_state()
		await get_tree().create_timer(0.25, true).timeout
	get_tree().quit()


func delete_room() -> void:
	if not _is_host_flag:
		return
	_send({"type": "delete_room"})
	_clear_room_state()


## Удалить любую ПУСТУЮ комнату из списка (для чистки тестовых).
func delete_any_room(target_room_id: String) -> void:
	_send({"type": "delete_any_room", "room_id": target_room_id})


func relay_all(data: Dictionary) -> void:
	if data.get("action", "") == "set_ready":
		_saved_ready = true
		_saved_investigator = data.get("investigator", "")
	_queue_or_send({"type": "relay", "data": data})


func relay_to(player_id: String, data: Dictionary) -> void:
	_queue_or_send({"type": "relay_to", "to": player_id, "data": data})


## Лобби: записать выбранного сыщика игрока в список комнаты (локально; рассылку
## делает вызывающий). NetworkManager владеет players — UI не пишет туда напрямую.
func set_lobby_investigator(pid: String, investigator: String) -> void:
	if players.has(pid):
		players[pid]["investigator"] = investigator


## Лобби: отметить игрока готовым (+ сыщик, если задан непустым). См.
## set_lobby_investigator — единственный владелец мутаций players.
func set_lobby_ready(pid: String, investigator: String = "") -> void:
	if not players.has(pid):
		return
	players[pid]["ready"] = true
	if not investigator.is_empty():
		players[pid]["investigator"] = investigator


## Лобби: снять готовность (перевыбор сыщика до старта). См. set_lobby_ready.
func set_lobby_not_ready(pid: String) -> void:
	if players.has(pid):
		players[pid]["ready"] = false


func is_connected_to_relay() -> bool:
	return _transport().is_open()


func is_reconnecting() -> bool:
	return _transport().is_connecting_or_open() or not _saved_room_id.is_empty()


func has_session() -> bool:
	return not my_name.is_empty()


func is_host() -> bool:
	return _is_host_flag


# id соединения текущего хоста ("" если ещё неизвестен). Используется GameState,
# чтобы принимать game_sync только от хоста. Мы сами хост → наш id соединения.
func host_id() -> String:
	if _is_host_flag:
		return my_id
	return _host_id


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
				not _saved_room_id.is_empty() and _saved_room_id == msg.get("room_id", "")
			)
			room_id = msg.get("room_id", "")
			room_name = msg.get("room_name", "")
			_is_host_flag = msg.get("is_host", false)
			# id хоста, если relay его присылает (иначе останется "" — тогда
			# GameState не сможет отфильтровать чужой game_sync, но и не сломается).
			_host_id = String(msg.get("host_id", ""))
			game_started = msg.get("game_started", false)
			# Сезоны СТОЛА приходят от сервера снимком прав хоста: чью коробку
			# принесли, в ту и играем. Свои личные сезоны (SeasonGate.own) при
			# этом не трогаем — за них отвечает вход в аккаунт.
			SeasonGate.set_room(msg.get("seasons", []))
			_saved_room_id = room_id
			players.clear()
			var raw_players: Array = msg.get("players", [])
			for i in range(raw_players.size()):
				var p: Dictionary = raw_players[i]
				var pid: String = p.get("id", "")
				players[pid] = {
					"id": pid,
					"user_id": p.get("user_id", ""),
					"name": p.get("name", ""),
					"ready": p.get("ready", false),
					"investigator": p.get("investigator", ""),
				}
			# Свой стабильный account-id берём из собственной записи в списке
			# (relay присылает его в user_id). Аноним → фолбэк на id соединения.
			if players.has(my_id):
				my_user_id = players[my_id].get("user_id", "")
			if my_user_id.is_empty():
				my_user_id = my_id
			if was_reconnect:
				reconnected.emit()
				if _saved_ready:
					_send(
						{
							"type": "relay",
							"data":
							{
								"action": "set_ready",
								"player_id": my_id,
								"investigator": _saved_investigator,
							}
						}
					)
				# Rejoin подтверждён — дошлём трафик, накопленный за разрыв.
				_flush_outbox()
			joined_room.emit(room_id, room_name, _is_host_flag, raw_players)
			# Снапшот игрового стейта (если сервер прислал) — кладём в GameState.
			# GameState инициализируется до перехода в world_map.
			var snapshot: Variant = msg.get("game_state", null)
			if snapshot is Dictionary:
				game_state_received.emit(snapshot)

		"player_joined":
			var p: Dictionary = msg.get("player", {})
			var pid: String = p.get("id", "")
			players[pid] = {
				"id": pid,
				"user_id": p.get("user_id", ""),
				"name": p.get("name", ""),
				"ready": p.get("ready", false),
				"investigator": p.get("investigator", ""),
			}
			GameConsole.log("%s зашёл в комнату" % p.get("name", pid))
			player_joined.emit(p)
			player_connected.emit(pid, players[pid])

		"player_left":
			# .get(key, "") НЕ спасает от JSON null: ключ есть со значением null (напр.
			# new_host_id, когда вышел НЕ хост и миграции не было) → возвращается null,
			# а не default. Приводим к "" через is-String-гард.
			var pid_v: Variant = msg.get("player_id")
			var pid: String = pid_v if pid_v is String else ""
			var nh_v: Variant = msg.get("new_host_id")
			var new_host: String = nh_v if nh_v is String else ""
			var uid_v: Variant = msg.get("user_id")
			var left_uid: String = uid_v if uid_v is String else ""
			var pname: String = players.get(pid, {}).get("name", pid)
			players.erase(pid)
			# relay мигрировал хоста на new_host — обновляем его id соединения.
			if not new_host.is_empty():
				_host_id = new_host
			if not new_host.is_empty() and new_host == my_id:
				_is_host_flag = true
				GameConsole.log("%s вышел  ·  вы стали ведущим" % pname)
			else:
				GameConsole.log("%s вышел из комнаты" % pname)
			player_left.emit(pid, new_host, left_uid)
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
					players[pid]["investigator"] = data.get(
						"investigator", players[pid].get("investigator", "")
					)

		"room_deleted":
			_clear_room_state()
			room_deleted.emit(msg.get("reason", "Комната закрыта"))

		"error":
			var err_msg: String = msg.get("message", tr("NET_ERR_SERVER"))
			# Протухший токен — по коду от сервера, не по подстроке локализованного текста.
			if String(msg.get("code", "")) == "session_invalid":
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


# Отправить игровой трафик (relay/relay_to). Сокет открыт — сразу; закрыт, но мы
# в комнате (короткий реконнект) — в очередь, дошлём после rejoin. Вне комнаты —
# дропаем (терять нечего). Подряд идущие game_sync схлопываем до последнего: важен
# лишь свежий снапшот, а не история.
func _queue_or_send(data: Dictionary) -> void:
	if _transport().is_open():
		_send(data)
		return
	if _saved_room_id.is_empty():
		return
	if _is_game_sync(data):
		_outbox = _outbox.filter(func(m: Variant) -> bool: return not _is_game_sync(m))
	_outbox.append(data)
	if _outbox.size() > _OUTBOX_MAX:
		_outbox.pop_front()  # переполнение — жертвуем самым старым


func _is_game_sync(m: Variant) -> bool:
	if not (m is Dictionary):
		return false
	var d: Variant = (m as Dictionary).get("data", {})
	return d is Dictionary and String((d as Dictionary).get("action", "")) == "game_sync"


# Дошлём накопленный за реконнект игровой трафик в порядке очереди. Хостовые
# game_sync доедут снапшотом; действия не-хоста дойдут до хоста, который их
# отвалидирует (устаревшие по очереди/фазе отклонит). Зовётся после rejoin.
func _flush_outbox() -> void:
	if _outbox.is_empty():
		return
	var pending: Array = _outbox
	_outbox = []
	for m_v: Variant in pending:
		_send(m_v as Dictionary)


func _transport() -> Node:
	if local_mode and _local != null:
		return _local
	return get_node("/root/RelayTransport")


## Локальный транспорт (null вне офлайн-режима) — для посадки ботов и их сообщений.
func local_transport() -> Node:
	return _local if local_mode else null


func _clear_room_state() -> void:
	# Вышли из комнаты — стол снова базовый. Иначе сезоны прошлого хоста
	# протекли бы в следующую партию, где их никто не покупал.
	SeasonGate.set_room([])
	room_id = ""
	room_name = ""
	_saved_room_id = ""
	_saved_room_pass = ""
	_saved_ready = false
	_saved_investigator = ""
	players.clear()
	_is_host_flag = false
	_host_id = ""
	_outbox.clear()  # осознанный выход из комнаты — накопленный трафик не нужен
	game_started = false
