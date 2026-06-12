class_name SpellCatalog
extends RefCounted

## Статичный каталог заклинаний (data/spells.json). Зеркало AssetCatalog.
## Заклинание двустороннее: front (каст: trigger/test/modifier/onPass) + backs
## (набор рубашек; при касте тянется случайная, каждая — tiers по числу успехов).

const PATH := "res://data/spells.json"

static var _list: Array = []
static var _by_id: Dictionary = {}


static func all() -> Array:
	if _list.is_empty():
		_load()
	return _list


static func by_id(id: String) -> Dictionary:
	if _by_id.is_empty():
		_load()
	return _by_id.get(id, {})


## Заклинание ли это (есть в каталоге).
static func is_spell(id: String) -> bool:
	return not by_id(id).is_empty()


## Случайная рубашка заклинания (или форсированная по id — для детерминизма/тестов
## и replay). {} — у заклинания нет рубашек.
static func random_back(spell: Dictionary, forced_id: String = "") -> Dictionary:
	var backs: Array = spell.get("backs", [])
	if (backs as Array).is_empty():
		return {}
	if not forced_id.is_empty():
		for i in range(backs.size()):
			if String((backs[i] as Dictionary).get("id", "")) == forced_id:
				return backs[i]
	return backs[randi() % backs.size()]


## Payload карты заклинания для GameCard/веера (название/подтип/способность/арт).
static func card_payload(s: Dictionary) -> Dictionary:
	var payload: Dictionary = {
		"title": s.get("name", ""),
		"subtitle": "TRAIT_SPELL",
		"desc": (s.get("front", {}) as Dictionary).get("abilityKey", ""),
		"id": String(s.get("id", "")),
	}
	var art: Texture2D = card_art(String(s.get("id", "")))
	if art != null:
		payload["art"] = art
	return payload


## Арт заклинания: assets/spell-card/<Id Capitalized>.png. Нет файла → null.
static func card_art(id: String) -> Texture2D:
	if id.is_empty():
		return null
	var path: String = "res://assets/spell-card/%s.png" % id.capitalize()
	return load(path) if ResourceLoader.exists(path) else null


static func _load() -> void:
	_list = DataLoader.load_array(PATH)
	_by_id.clear()
	for s in _list:
		_by_id[String((s as Dictionary).get("id", ""))] = s
