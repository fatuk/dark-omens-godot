class_name SeasonGate
extends RefCounted

## Какой сезонный контент доступен сейчас.
##
## Два независимых набора, потому что права работают по-разному:
##   • `room` — контент СТОЛА: чаша монстров, пул заклинаний, колода активов.
##     Идёт от ХОСТА — чью коробку принесли, в ту и играем. Поэтому пулы
##     наполняются только на хосте и разъезжаются к остальным синком.
##   • `own` — ЛИЧНЫЙ выбор сыщика. Идёт от самого игрока: купил сезон —
##     играешь его персонажами даже в чужой базовой комнате.
##
## Фильтруем ТОЛЬКО пулы выдачи. Поиск by_id не трогаем никогда: контент чужого
## сезона может уже лежать на столе (хост им владеет, нам прислали синком), и
## показать его мы обязаны — иначе у игрока пропадёт карта из руки.
##
## Карточка без поля `season` считается НЕДОСТУПНОЙ. Правило то же, что в CMS:
## забыли разметить — контент не утечёт в релиз молча.
##
## Прав пока нет (см. licenses в реле — там одна строка на пользователя,
## «право есть/нет»). До их появления оба набора равны базовому сезону, и это
## ровно то ограничение контента, которое нужно к первому релизу.

const BASE: Array[String] = ["core"]

static var room: Array[String] = BASE.duplicate()
static var own: Array[String] = BASE.duplicate()


## Доступна ли запись за столом (монстр, заклинание, актив).
static func room_allows(entry: Dictionary) -> bool:
	return room.has(String(entry.get("season", "")))


## Доступна ли запись лично игроку (сыщик).
static func own_allows(entry: Dictionary) -> bool:
	return own.has(String(entry.get("season", "")))


## Пул стола: только записи доступных комнате сезонов.
static func filter_room(list: Array) -> Array:
	var out: Array = []
	for i: int in range(list.size()):
		var e: Dictionary = list[i]
		if room_allows(e):
			out.append(e)
	return out


## Личный пул: только записи сезонов, которыми владеет игрок.
static func filter_own(list: Array) -> Array:
	var out: Array = []
	for i: int in range(list.size()):
		var e: Dictionary = list[i]
		if own_allows(e):
			out.append(e)
	return out


## Хост открывает столу свои сезоны (на старте партии). Пустой список не
## принимаем: партия без контента неиграбельна, лучше откатиться к базе.
static func set_room(seasons: Array) -> void:
	room = _clean(seasons)


## Игрок открывает себе свои сезоны (после входа в аккаунт).
static func set_own(seasons: Array) -> void:
	own = _clean(seasons)


static func _clean(seasons: Array) -> Array[String]:
	var out: Array[String] = []
	for i: int in range(seasons.size()):
		var s: String = String(seasons[i])
		if not s.is_empty() and not out.has(s):
			out.append(s)
	if out.is_empty():
		return BASE.duplicate()
	# База доступна всегда: её купили вместе с игрой.
	if not out.has("core"):
		out.append("core")
	return out
