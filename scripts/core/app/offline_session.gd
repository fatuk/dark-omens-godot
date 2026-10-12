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
	nm.connect(
		"joined_room",
		func(_rid: String, _rname: String, _host: bool, _players: Array) -> void:
			SceneManager.go("lobby"),
		CONNECT_ONE_SHOT
	)
	nm.connect(
		"connected_to_relay",
		func() -> void: nm.call("create_room", room_name, "", maxi(1, player_count)),
		CONNECT_ONE_SHOT
	)
	nm.call("connect_to_relay", pname, "local://")
	return true


## Свернуть офлайн-сессию: обратно на сокет, гостя забыть (аккаунт, если он был,
## остаётся). Зовётся из «Выйти» главного меню.
static func stop() -> void:
	var nm: Node = NetworkManager
	if not bool(nm.get("local_mode")):
		return
	nm.call("disconnect_from_relay")
	nm.call("set_local_mode", false)
	var auth: Node = AuthManager
	if String(auth.get("session_token")).is_empty():
		auth.set("current_user", {})
