extends GutTest

## Юнит-тесты сопротивления монстров (MonsterCatalog). Данные — реальный
## data/monsters.json: ghost = physical-резист, colour_out_of_space = magical,
## ghoul = без резиста.


func test_resists_physical() -> void:
	var m: Dictionary = MonsterCatalog.by_id("ghost")
	assert_true(MonsterCatalog.resists(m, "physical"), "ghost сопротивляется физ-урону")
	assert_false(MonsterCatalog.resists(m, "magical"), "но не магическому")


func test_resists_magical() -> void:
	assert_true(MonsterCatalog.resists(MonsterCatalog.by_id("colour_out_of_space"), "magical"))


func test_no_resist() -> void:
	var m: Dictionary = MonsterCatalog.by_id("ghoul")
	assert_false(MonsterCatalog.resists(m, "physical"))
	assert_false(MonsterCatalog.resists(m, "magical"))


func test_apply_resistance_halves_matching_floor() -> void:
	var ghost: Dictionary = MonsterCatalog.by_id("ghost")  # physical
	assert_eq(MonsterCatalog.apply_resistance(ghost, 4, "physical"), 2, "физ-резист: 4 → 2")
	assert_eq(MonsterCatalog.apply_resistance(ghost, 3, "physical"), 1, "округление вниз: 3 → 1")
	assert_eq(MonsterCatalog.apply_resistance(ghost, 4, "magical"), 4, "магия обходит физ-резист")


func test_apply_resistance_no_resist_unchanged() -> void:
	var ghoul: Dictionary = MonsterCatalog.by_id("ghoul")
	assert_eq(MonsterCatalog.apply_resistance(ghoul, 3, "physical"), 3)
	assert_eq(MonsterCatalog.apply_resistance(ghoul, 3, "magical"), 3)


func test_apply_resistance_zero_unchanged() -> void:
	assert_eq(MonsterCatalog.apply_resistance(MonsterCatalog.by_id("ghost"), 0, "physical"), 0)
