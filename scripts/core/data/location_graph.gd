class_name LocationGraph
extends RefCounted

## Граф локаций поля (data/locations.json): чистые запросы по id — тип, i18n-ключ
## имени, цвет врат, виды билетов, случайная клетка. Единственный экземпляр живёт в
## GameState.map (лениво читает файл); тесты подсовывают свой через
## LocationGraph.new([{id, type, connections, …}, …]) — без обращения к диску.
##
## До этого каждый модуль сам крутил цикл «найти запись по id» по массиву из
## GameState._load_locations() (девять копий), а UI лез в приватный метод через
## call(). Здесь — один индекс и один набор запросов.

const PATH := "res://data/locations.json"

var _locs: Array = []
var _by_id: Dictionary = {}  # id → запись
var _loaded: bool = false


func _init(locations: Array = []) -> void:
	if not locations.is_empty():
		_index(locations)


## Все записи локаций в порядке файла (для планировщика пути, запроса библии,
## консоли). Не мутировать.
func all() -> Array:
	_ensure()
	return _locs


## id всех локаций в порядке файла (пустые id отфильтрованы).
func ids() -> Array:
	_ensure()
	return _by_id.keys()


## Запись локации по id ({} — нет такой).
func by_id(loc_id: String) -> Dictionary:
	_ensure()
	return _by_id.get(loc_id, {})


func has(loc_id: String) -> bool:
	_ensure()
	return _by_id.has(loc_id)


## Тип локации (city|wilderness|sea), "" если не найдена.
func type_of(loc_id: String) -> String:
	return String(by_id(loc_id).get("type", ""))


func is_city(loc_id: String) -> bool:
	return type_of(loc_id) == "city"


## i18n-ключ игрового имени (LOC_*_NAME); нет в данных (номерной спейс без записи) —
## сам id. Ключ, а не текст: лента действий шлёт его, клиент сам tr() в своей локали.
func name_key(loc_id: String) -> String:
	return String(by_id(loc_id).get("name", loc_id))


## Цвет врат гейт-спейса ("" — не гейт-спейс).
func gate_color(loc_id: String) -> String:
	return String(by_id(loc_id).get("gateColor", ""))


## Какие билеты продаются в локации — по типам исходящих дорог, ТОЛЬКО в городах:
## дорога "train" → ж/д билет, "ship" → билет на корабль. Подмножество
## ["train", "ship"] (пусто — не город или нет таких дорог). Источник для кнопок
## сайдбара и валидации buy_ticket.
func ticket_types(loc_id: String) -> Array:
	if not is_city(loc_id):
		return []
	var types: Array = []
	for c: Variant in by_id(loc_id).get("connections", []):
		var t: String = String((c as Dictionary).get("type", ""))
		if (t == "train" or t == "ship") and not types.has(t):
			types.append(t)
	return types


## Случайный id ("" — локаций нет). Для Слухов и жетонов Древнего.
func random_id() -> String:
	_ensure()
	if _locs.is_empty():
		return ""
	return String((_locs[randi() % _locs.size()] as Dictionary).get("id", ""))


func _ensure() -> void:
	if not _loaded:
		_index(DataLoader.load_array(PATH))


func _index(locations: Array) -> void:
	_locs = locations
	_by_id = {}
	for l_v: Variant in locations:
		if l_v is Dictionary:
			var lid: String = String((l_v as Dictionary).get("id", ""))
			if not lid.is_empty():
				_by_id[lid] = l_v
	_loaded = true
