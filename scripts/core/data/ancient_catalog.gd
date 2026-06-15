class_name AncientCatalog
extends RefCounted

## Статичный каталог Древних (data/ancient_ones.json). Зеркало MonsterCatalog.
## Идентичность/флавор Древнего живут в relay-CMS (config/ancients.json) и приходят
## в кампанию; здесь — игровые правила Древнего (Расплата). Ключ — campaign.ancientOne.
## Поля записи: { id, nameKey, onReckoning?:[Effect-DSL] }.

const PATH := "res://data/ancient_ones.json"

static var _by_id: Dictionary = {}


## Определение Древнего по id ({} если нет).
static func by_id(id: String) -> Dictionary:
	if _by_id.is_empty():
		_load()
	return _by_id.get(id, {})


## Программа Расплаты Древнего (onReckoning) по id. [] — нет. Зовётся шагом Расплаты
## (ReckoningFlow) первым тиром.
static func reckoning_of(id: String) -> Array:
	return by_id(id).get("onReckoning", [])


static func _load() -> void:
	var list: Array = DataLoader.load_array(PATH)
	for i in range(list.size()):
		var a: Dictionary = list[i]
		_by_id[String(a.get("id", ""))] = a
