extends GutTest

## Юнит-тесты слотов Расплаты в данных: onReckoning у монстров (MonsterCatalog),
## Древнего (AncientCatalog) и активов (AssetCatalog). Данные — реальные data/*.json.


func test_monster_reckoning_of() -> void:
	var prog: Array = MonsterCatalog.reckoning_of("avian_thrall")
	assert_false(prog.is_empty(), "у avian_thrall есть Расплата (пример)")
	assert_eq(String((prog[0] as Dictionary).get("do", "")), "loseSanity")


func test_monster_reckoning_absent_empty() -> void:
	assert_eq(MonsterCatalog.reckoning_of("byakhee"), [], "без onReckoning → []")
	assert_eq(MonsterCatalog.reckoning_of("nope"), [], "неизвестный монстр → []")


func test_ancient_reckoning_of() -> void:
	var prog: Array = AncientCatalog.reckoning_of("azathoth")
	assert_false(prog.is_empty(), "у Азатота есть Расплата (пример)")
	assert_eq(String((prog[0] as Dictionary).get("do", "")), "advanceDoom")


func test_ancient_reckoning_absent_empty() -> void:
	assert_eq(AncientCatalog.reckoning_of("cthulhu"), [], "без onReckoning → []")
	assert_eq(AncientCatalog.reckoning_of("nope"), [], "неизвестный Древний → []")


func test_asset_reckoning_of() -> void:
	var prog: Array = AssetCatalog.reckoning_of("conspiracy_theorist")
	assert_false(prog.is_empty(), "у conspiracy_theorist есть effect.onReckoning")


func test_asset_reckoning_absent_empty() -> void:
	assert_eq(AssetCatalog.reckoning_of("nope"), [], "неизвестный актив → []")
