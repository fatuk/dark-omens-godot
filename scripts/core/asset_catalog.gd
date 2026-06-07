class_name AssetCatalog
extends RefCounted

## Статичный каталог имущества (data/assets.json). Зеркало MonsterCatalog.
## Поля записи: id, nameKey, set, cost, traits[], skill?, tags?, abilityKey, effect.

const PATH := "res://data/assets.json"

# Трейт карты → ключ перевода подзаголовка (берём последний трейт записи).
const _TRAIT_KEY := {
	"weapon": "TRAIT_WEAPON",
	"magical": "TRAIT_MAGICAL",
	"relic": "TRAIT_RELIC",
	"tome": "TRAIT_TOME",
	"teamwork": "TRAIT_TEAMWORK",
	"item": "TRAIT_ITEM",
	"trinket": "TRAIT_TRINKET",
	"task": "TRAIT_TASK",
	"service": "TRAIT_SERVICE",
	"ally": "TRAIT_ALLY",
}

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


# ── Карты для GameCard / веера (id → payload) ─────────────────────────────────


## Payload карты ассета для GameCard.set_card (название/трейт/способность/стоимость).
static func card_payload(a: Dictionary) -> Dictionary:
	var traits: Array = a.get("traits", [])
	var trait_id: String = String(traits[-1]) if not traits.is_empty() else "item"
	var payload: Dictionary = {
		"cost": int(a.get("cost", 0)),
		"title": a.get("nameKey", ""),
		"subtitle": _TRAIT_KEY.get(trait_id, trait_id.to_upper()),
		"desc": a.get("abilityKey", ""),
	}
	var art: Texture2D = card_art(String(a.get("id", "")))
	if art != null:
		payload["art"] = art
	return payload


## Арт ассета по конвенции имени файла: assets/asset-card/<Id Capitalized>.png
## (id "18_derringer" → "18 Derringer.png"). Нет файла → null (рамка без арта).
static func card_art(id: String) -> Texture2D:
	if id.is_empty():
		return null
	var path: String = "res://assets/asset-card/%s.png" % id.capitalize()
	return load(path) if ResourceLoader.exists(path) else null


## id ассета из элемента инвентаря: "id" | {"asset": id} | {"id": id}; иначе ""
## (токены вроде {"clue": N} — не карты).
static func entry_id(entry: Variant) -> String:
	if entry is String:
		return String(entry)
	if entry is Dictionary:
		var d: Dictionary = entry
		if d.has("asset"):
			return String(d["asset"])
		if d.has("id"):
			return String(d["id"])
	return ""


## Колода payload'ов карт по списку предметов игрока (пропускает не-ассеты и
## неизвестные id — напр. MVP-маркеры gainAsset).
static func deck_for_items(items: Array) -> Array:
	var out: Array = []
	for it: Variant in items:
		var aid: String = entry_id(it)
		if aid.is_empty():
			continue
		var a: Dictionary = by_id(aid)
		if not a.is_empty():
			out.append(card_payload(a))
	return out
