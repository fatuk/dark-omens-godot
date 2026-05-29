class_name AssetCatalog
extends RefCounted

## Статичный каталог имущества (data/assets.json). Зеркало MonsterCatalog.
## Поля записи: id, nameKey, set, cost, traits[], skill?, tags?, abilityKey, effect.

const PATH := "res://data/assets.json"

static var _list:  Array      = []
static var _by_id: Dictionary = {}


static func all() -> Array:
	if _list.is_empty():
		_load()
	return _list


static func by_id(id: String) -> Dictionary:
	if _by_id.is_empty():
		_load()
	return _by_id.get(id, {})


## Несколько ассетов для витрины магазина (пока — первые `count` из набора core).
## Позже заменится на «резерв» (выложенные лицом карты) из стейта.
static func shop_offer(count: int = 4) -> Array:
	var core: Array = []
	for a in all():
		if String((a as Dictionary).get("set", "")) == "core":
			core.append(a)
		if core.size() >= count:
			break
	return core


static func _load() -> void:
	_list = DataLoader.load_array(PATH)
	_by_id.clear()
	for a in _list:
		_by_id[String((a as Dictionary).get("id", ""))] = a
