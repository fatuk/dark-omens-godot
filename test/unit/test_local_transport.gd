## LocalTransport: реле «в процессе» отвечает тем же протоколом, что и сервер.
extends GutTest

const Transport := preload("res://scripts/network/local_transport.gd")

var _t: Node
var _got: Array = []  # распарсенные ответы по порядку


func before_each() -> void:
	_got.clear()
	_t = add_child_autofree(Transport.new())
	_t.raw_received.connect(func(text: String) -> void: _got.append(JSON.parse_string(text)))


func _open() -> void:
	_t.connect_to_server("local://")
	await get_tree().process_frame
	await get_tree().process_frame
	_got.clear()


func _types() -> Array:
	var out: Array = []
	for i: int in range(_got.size()):
		out.append(String((_got[i] as Dictionary).get("type", "")))
	return out


func test_connect_opens_deferred_and_sends_welcome() -> void:
	var opened: Array = []
	_t.ws_opened.connect(func() -> void: opened.append(true))
	assert_eq(_t.connect_to_server("local://"), OK)
	assert_false(_t.is_open(), "открывается отложенно, как сокет")
	assert_true(_t.is_connecting_or_open())
	await get_tree().process_frame
	assert_true(_t.is_open())
	assert_eq(opened.size(), 1, "ws_opened один раз")
	await get_tree().process_frame
	assert_eq(_types(), ["welcome"])
	assert_eq(_got[0]["your_id"], Transport.CLIENT_ID)


func test_send_before_open_is_dropped() -> void:
	_t.send_raw({"type": "list_rooms"})
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(_got.size(), 0)


func test_create_room_replies_room_created_then_joined_as_host() -> void:
	await _open()
	_t.send_raw({"type": "hello", "name": "Андрей"})
	_t.send_raw({"type": "create_room", "room_name": "Демо", "password": "", "max_players": 4})
	await get_tree().process_frame
	assert_eq(_types(), ["room_created", "joined_room"])
	var joined: Dictionary = _got[1]
	assert_true(joined["is_host"])
	assert_eq(joined["host_id"], Transport.CLIENT_ID)
	assert_eq(joined["room_name"], "Демо")
	assert_eq(joined["players"].size(), 1)
	assert_eq(joined["players"][0]["name"], "Андрей")
	assert_false(joined["players"][0]["ready"])
	assert_eq(joined["seasons"], Array(SeasonGate.own), "стол — своя коробка")
	assert_null(joined["game_state"])


func test_rooms_list_empty_then_one_room() -> void:
	await _open()
	_t.send_raw({"type": "list_rooms"})
	await get_tree().process_frame
	assert_eq(_got[0]["rooms"], [])
	_got.clear()
	_t.send_raw({"type": "create_room", "room_name": "X", "password": "", "max_players": 2})
	_t.send_raw({"type": "list_rooms"})
	await get_tree().process_frame
	var rooms: Array = _got[2]["rooms"]
	assert_eq(rooms.size(), 1)
	assert_eq(rooms[0]["id"], Transport.ROOM_ID)
	assert_eq(rooms[0]["playerCount"], 1)


func test_set_ready_is_echoed_other_relay_is_swallowed() -> void:
	await _open()
	_t.send_raw({"type": "create_room", "room_name": "X", "password": "", "max_players": 2})
	await get_tree().process_frame
	_got.clear()
	_t.send_raw({"type": "relay", "data": {"action": "start_game", "lang": "ru"}})
	_t.send_raw({"type": "relay", "data": {"action": "game_sync", "state": {}}})
	_t.send_raw({"type": "relay_to", "to": "x", "data": {"action": "chat"}})
	_t.send_raw(
		{
			"type": "relay",
			"data":
			{"action": "set_ready", "player_id": Transport.CLIENT_ID, "investigator": "nurse"}
		}
	)
	await get_tree().process_frame
	assert_eq(_types(), ["relay"], "эхо только у set_ready")
	assert_eq(_got[0]["from_id"], Transport.CLIENT_ID)
	assert_eq(_got[0]["data"]["investigator"], "nurse")
	# Повторный joined_room (rejoin) уже видит готовность и сыщика.
	_got.clear()
	_t.send_raw({"type": "join_room", "room_id": Transport.ROOM_ID, "password": ""})
	await get_tree().process_frame
	assert_eq(_types(), ["joined_room"])
	assert_true(_got[0]["players"][0]["ready"])
	assert_eq(_got[0]["players"][0]["investigator"], "nurse")


func test_relay_outside_room_and_unknown_room_are_errors() -> void:
	await _open()
	_t.send_raw({"type": "relay", "data": {"action": "set_ready"}})
	_t.send_raw({"type": "join_room", "room_id": "nope", "password": ""})
	await get_tree().process_frame
	assert_eq(_types(), ["error", "error"])
	assert_eq(_got[1]["code"], "room_not_found")


func test_leave_room_forgets_room() -> void:
	await _open()
	_t.send_raw({"type": "create_room", "room_name": "X", "password": "", "max_players": 2})
	_t.send_raw({"type": "leave_room"})
	_t.send_raw({"type": "list_rooms"})
	await get_tree().process_frame
	assert_eq(_types(), ["room_created", "joined_room", "rooms_list"])
	assert_eq(_got[2]["rooms"], [])


func test_virtual_players_join_room_and_inject_relay() -> void:
	await _open()
	_t.add_virtual_player("bot-1", "Бот 1")
	_t.send_raw({"type": "create_room", "room_name": "X", "password": "", "max_players": 2})
	await get_tree().process_frame
	var joined: Dictionary = _got[1]
	assert_eq(joined["players"].size(), 2, "бот посажен до комнаты → в joined_room")
	assert_eq(joined["players"][1]["id"], "bot-1")
	_got.clear()
	_t.add_virtual_player("bot-2", "Бот 2")
	_t.add_virtual_player("bot-2", "Бот 2")  # дубликат игнорируется
	_t.inject_relay("bot-1", {"action": "set_ready", "player_id": "bot-1", "investigator": "nurse"})
	_t.send_raw({"type": "list_rooms"})
	await get_tree().process_frame
	assert_eq(_types(), ["player_joined", "relay", "rooms_list"])
	assert_eq(_got[0]["player"]["name"], "Бот 2")
	assert_eq(_got[1]["from_id"], "bot-1")
	assert_eq(_got[2]["rooms"][0]["playerCount"], 3)
	assert_eq(_t.virtual_ids(), ["bot-1", "bot-2"])
	_got.clear()
	_t.send_raw({"type": "join_room", "room_id": Transport.ROOM_ID, "password": ""})
	await get_tree().process_frame
	assert_true(_got[0]["players"][1]["ready"], "готовность бота видна в joined_room")
	_t.send_raw({"type": "leave_room"})
	assert_eq(_t.virtual_ids(), [], "вышли — стол разобран")


func test_disconnect_closes_deferred_and_mutes_pending_replies() -> void:
	await _open()
	var closed: Array = []
	_t.ws_closed.connect(func() -> void: closed.append(true))
	_t.send_raw({"type": "list_rooms"})
	_t.disconnect_from_server()
	assert_false(_t.is_open())
	assert_false(_t.is_connecting_or_open())
	await get_tree().process_frame
	assert_eq(closed.size(), 1)
	assert_eq(_got.size(), 0, "ответ после закрытия не доставляется")
