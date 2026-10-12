class_name OfflineSession
extends RefCounted

## Офлайн-партия без аккаунта и сервера: гость + LocalTransport (реле «в процессе»)
## + запечённый контент (OfflineContent). Один вход для кнопки «Играть офлайн» на
## экране входа и для демо-сборки, где сервера нет вовсе.
##
## Демо-сборка узнаётся по feature-тегу `demo` пресета экспорта (или `--demo` в
## пользовательских аргументах командной строки — для локальной проверки).

const GUEST_ID := "guest"


static func is_demo_build() -> bool:
	return OS.has_feature("demo") or OS.get_cmdline_user_args().has("--demo")


## Идёт ли офлайн-сессия (транспорт локальный).
static func is_active() -> bool:
	return bool(NetworkManager.local_mode)


## Поднять офлайн-стол: гость (если нет аккаунта), локальный транспорт, комната на
## `player_count` мест с Древним `ancient` (пусто — первый запечённый, т.е. демо).
## В лобби уходим по joined_room — как из главного меню. false — контента нет.
static func start(player_count: int = 1, ancient: String = "") -> bool:
	if not OfflineContent.available():
		push_warning("[Offline] нет запечённого контента (data/offline) — офлайн недоступен")
		return false
	var auth: Node = AuthManager
	if not bool(auth.call("is_logged_in")):
		auth.set(
			"current_user",
			{"id": GUEST_ID, "email": "", "name": TranslationServer.translate("OFFLINE_GUEST_NAME")}
		)
	var pname: String = String((auth.get("current_user") as Dictionary).get("name", "Guest"))

	var nm: Node = NetworkManager
	nm.call("set_local_mode", true)
	var ancient_id: String = ancient
	if ancient_id.is_empty():
		var list: Array = OfflineContent.ancients(TranslationServer.get_locale())
		if not list.is_empty():
			ancient_id = String((list[0] as Dictionary).get("id", ""))
	GameState._campaign.set_seed(ancient_id, maxi(1, player_count))

	var room_name: String = TranslationServer.translate("OFFLINE_ROOM_NAME")
	var seats: int = maxi(1, player_count)
	nm.connect(
		"joined_room",
		func(_rid: String, _rname: String, _host: bool, _players: Array) -> void:
			SceneManager.go("lobby"),
		CONNECT_ONE_SHOT
	)
	nm.connect(
		"connected_to_relay",
		func() -> void:
			_seat_bots(nm, seats - 1)
			nm.call("create_room", room_name, "", seats),
		CONNECT_ONE_SHOT
	)
	nm.call("connect_to_relay", pname, "local://")
	return true


# Остальные места за столом — боты: виртуальные клиенты локального реле + драйвер,
# который за них ходит. Сажаем ДО create_room, чтобы они были в joined_room.players.
static func _seat_bots(nm: Node, count: int) -> void:
	var old: Node = nm.get_node_or_null("BotDriver")
	if old != null:
		old.queue_free()
	if count <= 0:
		return
	var transport: Node = nm.call("local_transport")
	if transport == null:
		return
	var ids: Array = []
	for i: int in range(count):
		var bid: String = "bot-%d" % (i + 1)
		var bname: String = TranslationServer.translate("OFFLINE_BOT_NAME") % (i + 1)
		transport.call("add_virtual_player", bid, bname)
		ids.append(bid)
	var driver := BotDriver.new()
	driver.name = "BotDriver"
	driver.setup(ids)
	nm.add_child(driver)


## Свернуть офлайн-сессию: обратно на сокет, гостя забыть (аккаунт, если он был,
## остаётся). Зовётся из «Выйти» главного меню.
static func stop() -> void:
	var nm: Node = NetworkManager
	if not bool(nm.get("local_mode")):
		return
	var driver: Node = nm.get_node_or_null("BotDriver")
	if driver != null:
		driver.queue_free()
	nm.call("disconnect_from_relay")
	nm.call("set_local_mode", false)
	var auth: Node = AuthManager
	if String(auth.get("session_token")).is_empty():
		auth.set("current_user", {})
