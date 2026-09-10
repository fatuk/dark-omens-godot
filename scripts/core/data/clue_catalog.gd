class_name ClueCatalog
extends RefCounted

## Каталог улик Древнего для веера/карточек. Определения приходят из библии в
## campaign.ancientOne.clues (синкаются всем): [{location, title, description}].
## Ключ улики = ЛОКАЦИЯ. Арт — по имени файла = id локации (как AssetCatalog):
## res://assets/cards/clue/<Location>.png; нет файла → null (рамка без арта).
##
## Идентичности на руках сыщика — в player.clue_ids (ключи-локации). Раздачу/пул
## держит GameState (host-only); здесь — только чтение контента для отрисовки.

const ART_DIR := "res://assets/cards/clue/"


## Все определения улик текущего Древнего (или [] — кампания не готова).
static func all() -> Array:
	return (GameState.campaign.get("ancientOne", {}) as Dictionary).get("clues", [])


## Определение улики по ключу-локации ({} — нет такой).
static func by_location(loc: String) -> Dictionary:
	for c: Variant in all():
		if c is Dictionary and String((c as Dictionary).get("location", "")) == loc:
			return c
	return {}


## Арт улики по конвенции имени файла (id локации, как арт ассета). Нет файла → null.
static func card_art(loc: String) -> Texture2D:
	if loc.is_empty():
		return null
	var path: String = "%s%s.png" % [ART_DIR, loc.capitalize()]
	return load(path) if ResourceLoader.exists(path) else null


## Payload карточки улики для веера/GameCard (title/description/art) по ключу-локации.
## Нет описания (улика не заведена или поле пустое) → подставляем имя локации.
static func card_payload(loc: String) -> Dictionary:
	var d: Dictionary = by_location(loc)
	var desc: String = String(d.get("description", ""))
	if desc.strip_edges().is_empty():
		desc = TranslationServer.translate(GameState.map.name_key(loc))
	var payload: Dictionary = {
		"id": loc,
		"title": d.get("title", ""),
		"desc": desc,
	}
	var art: Texture2D = card_art(loc)
	if art != null:
		payload["art"] = art
	return payload


## Колода payload'ов по списку ключей улик на руках (player.clue_ids). clue_index —
## позиция в списке (для активации/сноса из веера).
static func deck_for_clue_ids(ids: Array) -> Array:
	var out: Array = []
	for i in range(ids.size()):
		var p: Dictionary = card_payload(String(ids[i]))
		p["clue_index"] = i
		out.append(p)
	return out
