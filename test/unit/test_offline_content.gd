## OfflineContent: офлайн-выборка встреч и библии повторяют серверные правила.
extends GutTest

const OC := preload("res://scripts/core/data/offline_content.gd")

# Тайна с afterDefeat.encounterTag делает тег «особым»: такие карты только по назначению.
const MYSTERIES := [
	{"title": "I", "afterDefeat": {"encounterTag": "demo-final", "holderOf": "sheaf"}}
]
const BIBLE_RU := {
	"id": "camp-ru-2",
	"ancientOne": {"id": "sheaf", "name": "Братство"},
	"doomClock": 8,
	"mysteries": MYSTERIES,
}
const BIBLE_EN := {
	"id": "camp-en-2",
	"ancientOne": {"id": "sheaf", "name": "Brotherhood"},
	"doomClock": 8,
	"mysteries": MYSTERIES,
}


func _card(id: String, kind: String, tags: Array, extra: Dictionary = {}) -> Dictionary:
	var data: Dictionary = {
		"test": {"skill": "lore", "modifier": 0},
		"onSuccess": [{"do": "gainClue", "count": 1}],
		"onFailure": [],
	}
	if kind == "gate":
		data = {
			"stage1": {"test": {"skill": "lore"}},
			"successBranch": {"test": {"skill": "will"}, "onSuccess": [], "onFailure": []},
			"failureBranch": {"test": {"skill": "will"}, "onSuccess": [], "onFailure": []},
		}
	data.merge(extra)
	return {
		"id": id,
		"kind": kind,
		"tags": tags,
		"data": data,
		"i18n":
		{
			"ru": {"name": id + " ru", "mainText": "текст"},
			"en": {"name": id + " en", "mainText": "text"},
		},
	}


func before_each() -> void:
	OC.reset()
	OC.rng.seed = 7
	(
		OC
		. set_corpus(
			[
				_card("city-any", "general", ["loc:city"]),
				_card("sea-any", "general", ["loc:sea"]),
				_card("arkham-pinned", "general", ["loc:city", "location:Arkham"]),
				_card("sheaf-city", "general", ["loc:city", "ancient:sheaf"]),
				_card("other-ancient", "general", ["loc:city", "ancient:cthulhu"]),
				_card("res-5", "research", ["location:5"]),
				_card("res-any", "research", []),
				_card("gate-dream", "gate", ["world:Dreamlands"]),
				_card("gate-yug", "gate", ["world:Yuggoth"]),
				_card("final-1", "general", ["demo-final"]),
				_card("final-2", "general", ["demo-final"], {"requires": {"hasSpell": true}}),
			]
		)
	)
	OC.set_campaigns({"sheaf": {"ru": {"2": BIBLE_RU}, "en": {"2": BIBLE_EN}}})


func _draw(req: Dictionary) -> Array:
	var res: Dictionary = OC.draw(req)
	assert_true(res["ok"], "draw ok")
	return res["encounters"]


func _ids(cards: Array) -> Array:
	var out: Array = []
	for i: int in range(cards.size()):
		out.append(String((cards[i] as Dictionary).get("sourceId", "")))
	return out


func _req(kind: String, loc: String, type: String, extra: Dictionary = {}) -> Dictionary:
	var r: Dictionary = {
		"kind": kind,
		"realLocation": {"id": loc, "name": loc, "locationType": type},
		"count": 1,
		"language": "Russian",
	}
	r.merge(extra)
	return r


func test_general_unpinned_only_by_location_type() -> void:
	var seen: Dictionary = {}
	for i: int in range(30):
		seen[_ids(_draw(_req("general", "Rome", "city")))[0]] = true
	assert_true(seen.has("city-any"))
	assert_false(seen.has("sea-any"), "чужой тип локации")
	assert_false(seen.has("arkham-pinned"), "привязка к другой клетке")
	assert_false(seen.has("other-ancient"), "карта чужого Древнего")
	assert_false(seen.has("final-1"), "теговые карты — только по тегу")


func test_site_specific_general_takes_pinned_card() -> void:
	assert_eq(
		_ids(_draw(_req("general", "Arkham", "city", {"siteSpecific": true}))), ["arkham-pinned"]
	)
	var ids: Array = _ids(_draw(_req("general", "Arkham", "city")))
	assert_ne(ids[0], "arkham-pinned", "без siteSpecific — общая")


func test_ancient_cards_preferred_when_campaign_known() -> void:
	for i: int in range(10):
		var ids: Array = _ids(_draw(_req("general", "Rome", "city", {"campaignId": "camp-ru-2"})))
		assert_eq(ids, ["sheaf-city"])


func test_research_prefers_pinned_to_this_cell() -> void:
	assert_eq(_ids(_draw(_req("research", "5", "city"))), ["res-5"])
	assert_eq(_ids(_draw(_req("research", "Arkham", "city"))), ["res-any"])


func test_exclude_skips_discard_until_pool_is_empty() -> void:
	var req: Dictionary = _req("general", "Rome", "city", {"exclude": ["city-any"]})
	# city-any — единственная общая городская без Древнего → сброс возвращается в колоду.
	assert_eq(_ids(_draw(req)), ["city-any"])
	req["campaignId"] = "camp-ru-2"
	assert_eq(_ids(_draw(req)), ["sheaf-city"], "свежая карта Древнего вместо сброшенной")


func test_gate_any_world_or_explicit_world() -> void:
	var seen: Dictionary = {}
	for i: int in range(30):
		var card: Dictionary = _draw({"kind": "gate", "language": "English"})[0]
		seen[card["otherWorld"]] = true
		assert_true(card.has("stage1") and card.has("branches"), "двухфазная форма")
	assert_true(seen.has("Dreamlands") and seen.has("Yuggoth"))
	var yug: Dictionary = _draw({"kind": "gate", "otherWorld": "Yuggoth", "language": "English"})[0]
	assert_eq(yug["sourceId"], "gate-yug")
	assert_eq(yug["name"], "gate-yug en", "локаль по языку запроса")


func test_tag_and_requires_flags() -> void:
	var seen: Dictionary = {}
	for i: int in range(20):
		seen[_ids(_draw(_req("general", "Rome", "city", {"tag": "demo-final"})))[0]] = true
	assert_eq(seen.keys(), ["final-1"], "без флага hasSpell вторая карта недоступна")
	seen.clear()
	for i: int in range(30):
		var r: Dictionary = _req(
			"general", "Rome", "city", {"tag": "demo-final", "flags": ["hasSpell"]}
		)
		seen[_ids(_draw(r))[0]] = true
	assert_true(seen.has("final-2"))


func test_stub_when_nothing_matches() -> void:
	var card: Dictionary = _draw(_req("general", "Pole", "wilderness"))[0]
	assert_true(card["mechanical"])
	assert_false(card.has("sourceId"))
	assert_eq(card["onSuccess"], [{"do": "gainClue", "count": 1}])


func test_assemble_picks_language_and_nearest_player_count() -> void:
	var res: Dictionary = OC.assemble(
		{"ancientOne": "sheaf", "playerCount": 3, "language": "English"}
	)
	assert_true(res["ok"])
	assert_eq(res["campaign"]["id"], "camp-en-2", "ближайший размер снизу")
	res = OC.assemble({"ancientOne": "sheaf", "playerCount": 1, "language": "Russian"})
	assert_eq(res["campaign"]["id"], "camp-ru-2", "меньше запечённого — наименьший")
	res = OC.assemble({"ancientOne": "", "playerCount": 2, "language": "Russian"})
	assert_true(res["ok"], "без Древнего — первый запечённый")
	assert_false(OC.assemble({"ancientOne": "nope", "playerCount": 2})["ok"])


func test_assemble_returns_copy() -> void:
	var a: Dictionary = (
		OC.assemble({"ancientOne": "sheaf", "playerCount": 2, "language": "ru"})["campaign"]
	)
	a["doomClock"] = 1
	var b: Dictionary = (
		OC.assemble({"ancientOne": "sheaf", "playerCount": 2, "language": "ru"})["campaign"]
	)
	assert_eq(b["doomClock"], 8)


func test_get_campaign_and_ancients() -> void:
	assert_eq(OC.get_campaign("camp-en-2")["campaign"]["doomClock"], 8)
	assert_false(OC.get_campaign("zzz")["ok"])
	assert_eq(OC.ancients("ru"), [{"id": "sheaf", "name": "Братство"}])
	assert_eq(OC.ancients("en_US"), [{"id": "sheaf", "name": "Brotherhood"}])


func test_nearest_count() -> void:
	assert_eq(OC._nearest_count(["1", "2", "4"], 3), "2")
	assert_eq(OC._nearest_count(["2", "4"], 1), "2")
	assert_eq(OC._nearest_count(["1", "2", "4"], 9), "4")
	assert_eq(OC._nearest_count([], 2), "")
