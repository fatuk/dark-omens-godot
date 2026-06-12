extends GutTest

## Юнит-тесты каталога заклинаний (scripts/core/data/spell_catalog.gd) на реальном
## data/spells.json. Статический класс — инстанс не нужен.


func test_by_id_loads_spell() -> void:
	var s: Dictionary = SpellCatalog.by_id("shriveling")
	assert_false(s.is_empty(), "shriveling загружен")
	assert_eq(String(s["subtype"]), "ritual")
	assert_false((s["backs"] as Array).is_empty(), "есть рубашки")


func test_by_id_incantation() -> void:
	assert_eq(String(SpellCatalog.by_id("wither")["subtype"]), "incantation")


func test_by_id_unknown_is_empty() -> void:
	assert_true(SpellCatalog.by_id("no_such_spell").is_empty())


func test_is_spell() -> void:
	assert_true(SpellCatalog.is_spell("shriveling"))
	assert_false(SpellCatalog.is_spell("18_derringer"), "актив — не заклинание")


func test_random_back_forced() -> void:
	var s: Dictionary = SpellCatalog.by_id("shriveling")
	var back: Dictionary = SpellCatalog.random_back(s, "shriveling_b2")
	assert_eq(String(back["id"]), "shriveling_b2", "форс рубашки по id")


func test_random_back_within_set() -> void:
	var s: Dictionary = SpellCatalog.by_id("shriveling")
	var ids: Array = []
	for b_v: Variant in s["backs"]:
		ids.append(String((b_v as Dictionary)["id"]))
	var back: Dictionary = SpellCatalog.random_back(s)
	assert_has(ids, String(back["id"]), "случайная рубашка из набора заклинания")


func test_card_payload_shape() -> void:
	var s: Dictionary = SpellCatalog.by_id("shriveling")
	var p: Dictionary = SpellCatalog.card_payload(s)
	assert_eq(String(p["id"]), "shriveling")
	assert_eq(String(p["subtitle"]), "TRAIT_SPELL", "подзаголовок — заклинание")
	assert_eq(String(p["title"]), "SPELL_SHRIVELING_NAME", "ключ названия")


func test_is_glamour() -> void:
	assert_true(SpellCatalog.is_glamour("mind_s_eye"))
	assert_false(SpellCatalog.is_glamour("shriveling"), "ritual — не glamour")


func test_aura_check_mods() -> void:
	var mods: Array = SpellCatalog.aura_check_mods(
		SpellCatalog.by_id("mind_s_eye"), "combatEncounter"
	)
	assert_eq(mods.size(), 1, "anyTest-аура подходит любому контексту")
	assert_eq(String((mods[0] as Dictionary)["do"]), "rerollDice")
