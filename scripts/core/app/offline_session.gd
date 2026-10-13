class_name OfflineSession
extends RefCounted

## Офлайн-партия без аккаунта и сервера: гость + LocalTransport (реле «в процессе»)
## + запечённый по Древним контент (OfflineContent) + боты на свободных местах.
## Вход «Играть офлайн» ведёт в главное меню (выбор Древнего и мест), демо-сборка —
## сразу за стол.
##
## Демо-сборка узнаётся по feature-тегу `demo` пресета экспорта (или `--demo` в
## пользовательских аргументах командной строки — для локальной проверки).

const GUEST_ID := "guest"


static func is_demo_build() -> bool:
	return OS.has_feature("demo") or OS.get_cmdline_user_args().has("--demo")


## Идёт ли офлайн-сессия (транспорт локальный).
static func is_active() -> bool:
	return bool(NetworkManager.local_mode)


## Войти в офлайн как гость (аккаунт, если есть, сохраняется) и уйти в главное меню:
## там локальное реле подключится само, а «Создать комнату» спросит Древнего (из
## запечённых) и число мест — свободные места займут боты. false — контента нет.
static func enter() -> bool:
	if not _prepare():
		return false
	SceneManager.go("main_menu")
	return true


## Демо-сборка: сразу офлайн-стол на `player_count` мест с Древним `ancient` (пусто —
## первый запечённый, т.е. демо), минуя меню. В лобби — по joined_room.
static func start(player_count: int = 1, ancient: String = "") -> bool:
	if not _prepare():
		return false
	var nm: Node = NetworkManager
	var seats: int = maxi(1, player_count)
	nm.connect(
		"joined_room",
		func(_rid: String, _rname: String, _host: bool, _players: Array) -> void:
			SceneManager.go("lobby"),
		CONNECT_ONE_SHOT
	)
	nm.connect("connected_to_relay", func() -> void: create_table(seats, ancient), CONNECT_ONE_SHOT)
	nm.call("connect_to_relay", _player_name(), "local://")
	return true


## Создать офлайн-стол (локальное реле уже подключено): зерно кампании, боты на
## свободные места, комната. ancient — id или имя Древнего; "" — первый запечённый.
static func create_table(seats: int, ancient: String = "", room_name: String = "") -> void:
	var nm: Node = NetworkManager
	var n: int = maxi(1, seats)
	var ancient_id: String = OfflineContent.resolve_ancient(ancient)
	if ancient_id.is_empty():
		var list: Array = OfflineContent.ancients(TranslationServer.get_locale())
		if not list.is_empty():
			ancient_id = String((list[0] as Dictionary).get("id", ""))
	GameState.set_campaign_seed(ancient_id, n)
	_seat_bots(nm, n - 1)
	var rname: String = room_name
	if rname.strip_edges().is_empty():
		rname = TranslationServer.translate("OFFLINE_ROOM_NAME")
	nm.call("create_room", rname, "", n)


# Гость (если не вошли в аккаунт) + локальный транспорт. false — нет контента.
static func _prepare() -> bool:
	if not OfflineContent.available():
		push_warning("[Offline] нет запечённого контента (data/offline) — офлайн недоступен")
		return false
	var auth: Node = AuthManager
	if not bool(auth.call("is_logged_in")):
		auth.set(
			"current_user",
			{"id": GUEST_ID, "email": "", "name": TranslationServer.translate("OFFLINE_GUEST_NAME")}
		)
	NetworkManager.call("set_local_mode", true)
	return true


static func _player_name() -> String:
	return String((AuthManager.get("current_user") as Dictionary).get("name", "Guest"))


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
