class_name ArtifactCatalog
extends RefCounted

## Статичный каталог артефактов (data/artifacts.json). Генерируется из CMS
## (relay scripts/export-game-content.ts), править файл руками бессмысленно.
##
## Артефакт устроен как актив: те же слоты эффектов (whileOwned / onGain /
## action / triggered / onReckoning), те же трейты. Отличий ровно два, и оба
## принципиальные:
##
##   1. ЕГО НЕ ПОКУПАЮТ. У артефакта нет цены и он не попадает ни в витрину, ни
##      в колоду активов: его выдают встречи и Иные миры («Получите 1 Артефакт»).
##      Поэтому это ОТДЕЛЬНЫЙ каталог, а не запись в assets.json — иначе
##      AssetCatalog.available_ids() потащил бы артефакты в магазин и в случайную
##      выдачу gainAsset.
##   2. ОН УНИКАЛЕН. Копия одна на партию, поэтому выдача исключает уже занятые
##      (см. GameState.artifact_pool).
##
## При этом ВЛАДЕНИЕ артефактом ничем не отличается от владения активом, и весь
## слой розыгрыша (пассивы проверок, слот action, боевые скидки, веер карт) обязан
## видеть его так же. Это обеспечено одним швом: AssetCatalog.by_id() падает
## сюда, если id не нашёлся среди активов. Всё, что ходит через by_id, работает с
## артефактами без правок; всё, что ходит через all() — колода и витрина — их не
## видит.

const PATH := "res://data/artifacts.json"
## Рамка карты артефакта — разметка как у актива (GameCard base_frame).
const FRAME: Texture2D = preload("res://assets/cards/artifact/card-frame.png")

static var _list: Array = []
static var _by_id: Dictionary = {}
static var _loaded: bool = false


## Все записи каталога (порядок файла).
static func all() -> Array:
	_load()
	return _list


## Запись по id ({} если нет).
static func by_id(id: String) -> Dictionary:
	_load()
	return _by_id.get(id, {})


## Есть ли такой артефакт в каталоге.
static func has(id: String) -> bool:
	_load()
	return _by_id.has(id)


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	_list = DataLoader.load_array(PATH)
	for a in _list:
		_by_id[String((a as Dictionary).get("id", ""))] = a


## Id артефактов, доступных столу: сезон комнаты + опциональный фильтр по трейту.
## Трейт задан, но не подошёл никому — отдаём НЕотфильтрованный список: пустая
## награда за успех хуже слегка неточной (то же правило, что у gainAsset).
static func available_ids(want_trait: String = "") -> Array:
	var out: Array = []
	var matched: Array = []
	for a_v: Variant in all():
		var a: Dictionary = a_v
		if not SeasonGate.room_allows(a):
			continue
		var id: String = String(a.get("id", ""))
		out.append(id)
		if not want_trait.is_empty() and (a.get("traits", []) as Array).has(want_trait):
			matched.append(id)
	if want_trait.is_empty() or matched.is_empty():
		return out
	return matched


## Случайный СВОБОДНЫЙ артефакт: из доступных вычитаются занятые (taken — набор
## id, ключи словаря). "" — свободных не осталось.
##
## Артефакт уникален, копия одна на партию, поэтому «занятые» считаются по всему
## столу, а не по рукам получателя: иначе двое сыщиков носили бы один
## «Некрономикон». Сам подсчёт занятых — забота вызывающего (он видит игроков).
static func pick_free(taken: Dictionary, want_trait: String = "") -> String:
	var pool: Array = []
	for id_v: Variant in available_ids(want_trait):
		if not taken.has(String(id_v)):
			pool.append(String(id_v))
	if pool.is_empty():
		return ""
	return String(pool[randi() % pool.size()])


## Payload карты для GameCard. Стоимости у артефакта нет — вместо неё подзаголовок
## помечает карту как артефакт, иначе за столом её не отличить от актива.
static func card_payload(a: Dictionary) -> Dictionary:
	# Ключа cost нет намеренно: GameCard показывает плашку стоимости по НАЛИЧИЮ
	# поля, а у артефакта цены не бывает — он не продаётся.
	var payload: Dictionary = {
		"title": a.get("nameKey", ""),
		"subtitle": "TRAIT_ARTIFACT",
		"desc": a.get("abilityKey", ""),
		"is_artifact": true,
		"base_frame": FRAME,  # своя рамка: без герба цены, фиолетовый камень
	}
	var art: Texture2D = card_art(String(a.get("id", "")))
	if art != null:
		payload["art"] = art
	return payload


## Арт артефакта: assets/cards/artifact/<Id Capitalized>.png. Нет файла → null
## (рамка без арта), как у активов.
static func card_art(id: String) -> Texture2D:
	if id.is_empty():
		return null
	var path: String = "res://assets/cards/artifact/%s.png" % id.capitalize()
	return load(path) if ResourceLoader.exists(path) else null
