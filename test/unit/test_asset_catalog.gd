extends GutTest

## AssetCatalog: пассивная боевая митигация (reduceMonsterDamage/Horror) — авто-вычет
## урона/ужаса монстра по принадлежащим whileOwned-активам (Elder Sign / Fishing Net).


func test_owned_combat_reduce_reads_owned_asset() -> void:
	var items: Array = [{"id": "elder_sign", "exhausted": false}]
	var r: Dictionary = AssetCatalog.owned_combat_reduce(items, "reduceMonsterHorror")
	assert_eq(int(r["amount"]), 1, "elder_sign: reduceMonsterHorror amount 1")
	assert_eq(int(r["min"]), 1, "пол min 1")
	assert_eq(
		int(AssetCatalog.owned_combat_reduce(items, "reduceMonsterDamage")["amount"]),
		0,
		"другого verb'а у карты нет"
	)


func test_owned_combat_reduce_ignores_non_assets() -> void:
	var items: Array = [
		{"id": "elder_sign", "exhausted": false},
		{"id": "some_spell", "kind": "spell"},  # не актив → игнор
		{"id": "unknown_id", "exhausted": false},  # нет в каталоге → игнор
	]
	assert_eq(int(AssetCatalog.owned_combat_reduce(items, "reduceMonsterHorror")["amount"]), 1)


func test_apply_combat_reduce() -> void:
	assert_eq(AssetCatalog.apply_combat_reduce(3, {"amount": 1, "min": 1}), 2, "3 − 1 = 2")
	assert_eq(AssetCatalog.apply_combat_reduce(1, {"amount": 5, "min": 1}), 1, "не ниже пола min")
	assert_eq(
		AssetCatalog.apply_combat_reduce(3, {"amount": 0, "min": 1}), 3, "amount 0 → не трогаем"
	)
