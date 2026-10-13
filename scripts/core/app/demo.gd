class_name Demo
extends RefCounted

## Демо-сборка: отдельный пресет экспорта с feature-тегом `demo` (или `--demo` в
## пользовательских аргументах — локальная проверка из редактора). Кодовая база та
## же; отличия включаются проверками Demo.active():
##   • «Играть» на главной сразу сажает за офлайн-стол демо-Древнего: гость + 2 бота,
##     без логина, сервера и списка комнат;
##   • лобби — только выбор сыщика: «Начать» нет, партия стартует сама, как только
##     игрок и боты готовы; состояние лобби на диск не пишется;
##   • любой выход в меню комнат или на вход (пауза, финал партии, «Назад» в лобби)
##     ведёт на главную, офлайн-сессия сворачивается — прогресс партии не хранится.
## Настройки (звук, экран, язык) работают как обычно.

const SEATS := 3  # гость + 2 бота

## Включить демо-режим в рантайме (тесты, проверка из редактора без пересборки).
static var forced: bool = false


static func active() -> bool:
	return forced or OS.has_feature("demo") or OS.get_cmdline_user_args().has("--demo")


## Демо-набор контента: какие сыщики и активы есть в демо (печёт bake-offline-content
## по тегу demo в CMS). Вида нет в файле — он не ограничен.
const CONTENT_PATH := "res://data/offline/demo/content.json"

static var _content: Dictionary = {}
static var _content_loaded: bool = false


## Входит ли запись в демо-набор вида kind ("assets" — по id, "investigators" — по
## имени). Вне демо, без kind или для неограниченного вида — всегда да.
static func allows(kind: String, entry: Dictionary) -> bool:
	if kind.is_empty() or not active():
		return true
	if not _content_loaded:
		_content_loaded = true
		if FileAccess.file_exists(CONTENT_PATH):
			set_content(DataLoader.load_dict(CONTENT_PATH))
	if not _content.has(kind):
		return true
	var key: String = String(entry.get("id", entry.get("name", "")))
	return (_content[kind] as Dictionary).has(key)


## Подложить демо-набор ({вид: [ключи]}) — загрузка файла и тесты.
static func set_content(content: Dictionary) -> void:
	_content_loaded = true
	_content = {}
	for kind: String in content.keys():
		var keys: Dictionary = {}
		for k_v: Variant in content[kind]:
			keys[String(k_v)] = true
		_content[kind] = keys


## Сцены полной игры, которых в демо нет: переход туда уводит на главную.
static func redirect(scene_name: String) -> String:
	if active() and (scene_name == "main_menu" or scene_name == "login"):
		return "home"
	return scene_name


## Сесть за демо-стол (кнопка «Играть» на главной). false — нет запечённого контента.
static func play() -> bool:
	return OfflineSession.start(SEATS)


## Выйти из партии на главную: свернуть офлайн-сессию и забыть партию целиком.
static func leave() -> void:
	OfflineSession.stop()
	GameState.reset_session()
