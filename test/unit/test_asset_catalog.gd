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


# ── is_supported: фильтр пула выдачи (только полностью рабочие карты) ──────────
func test_is_supported_classifies_cards() -> void:
	assert_true(
		AssetCatalog.is_supported(AssetCatalog.by_id("arcane_scholar")),
		"improveSkill+rerollDice без слепых слотов — поддержана"
	)
	assert_true(
		AssetCatalog.is_supported(AssetCatalog.by_id("handcuffs")),
		"только боевой триггер (defeatMonster) — поддержана"
	)
	assert_false(
		AssetCatalog.is_supported(AssetCatalog.by_id("bandages")), "preventLoss — не поддержана"
	)
	assert_false(
		AssetCatalog.is_supported(AssetCatalog.by_id("arcane_tome")),
		"triggered on:rest не диспатчится — не поддержана"
	)


func test_supported_ids_excludes_unsupported() -> void:
	var ids: Array = AssetCatalog.supported_ids()
	assert_has(ids, "arcane_scholar")
	assert_does_not_have(ids, "bandages")
	assert_does_not_have(ids, "arcane_tome")
	assert_true(ids.size() > 120, "большинство карт (131) поддержано: %d" % ids.size())


# ── fits_check: подходит ли карта конкретной проверке ──────────────────────────
#
# «Охотник на монстров» умеет ДВА разных розыгрыша: пассив whileOwned (+2 Силы в
# бою) и самостоятельное действие (монстр теряет 1 здоровье). В бою действие не
# потратить — там нет фазы действий, — но пассив применим. Веер и маршрут клика
# опирались только на has_standalone_action и считали карту неиграбельной.


func test_fits_check_ally_with_standalone_action() -> void:
	var a: Dictionary = AssetCatalog.by_id("monster_hunter")
	assert_true(AssetCatalog.has_standalone_action(a), "у карты есть и самостоятельное действие")
	assert_true(
		AssetCatalog.fits_check(a, "combatEncounter", "strength", false),
		"пассив +2 Силы подходит шагу Силы до броска"
	)


func test_fits_check_rejects_wrong_step_context_and_timing() -> void:
	var a: Dictionary = AssetCatalog.by_id("monster_hunter")
	assert_false(
		AssetCatalog.fits_check(a, "combatEncounter", "will", false),
		"на шаге Воли карта Силы не применима"
	)
	assert_false(
		AssetCatalog.fits_check(a, "combatEncounter", "strength", true),
		"усиление пула — только ДО броска"
	)
	assert_false(
		AssetCatalog.fits_check(a, "", "strength", false),
		"вне боевой встречи бонус не действует (context combatEncounter)"
	)
