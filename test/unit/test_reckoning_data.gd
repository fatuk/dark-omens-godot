extends GutTest

## Юнит-тесты слотов Расплаты в данных: onReckoning у монстров (MonsterCatalog) и
## активов (AssetCatalog). Данные — реальные data/*.json. Расплата Древнего больше
## не в data/ — она в CMS (ancientOne.onReckoning из библии), см. test_reckoning_flow.


func test_monster_reckoning_of() -> void:
	var prog: Array = MonsterCatalog.reckoning_of("avian_thrall")
	assert_false(prog.is_empty(), "у avian_thrall есть Расплата (пример)")
	assert_eq(String((prog[0] as Dictionary).get("do", "")), "loseSanity")


func test_monster_reckoning_absent_empty() -> void:
	assert_eq(MonsterCatalog.reckoning_of("byakhee"), [], "без onReckoning → []")
	assert_eq(MonsterCatalog.reckoning_of("nope"), [], "неизвестный монстр → []")


func test_asset_reckoning_of() -> void:
	var prog: Array = AssetCatalog.reckoning_of("conspiracy_theorist")
	assert_false(prog.is_empty(), "у conspiracy_theorist есть effect.onReckoning")


func test_asset_reckoning_absent_empty() -> void:
	assert_eq(AssetCatalog.reckoning_of("nope"), [], "неизвестный актив → []")
