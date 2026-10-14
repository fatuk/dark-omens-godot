extends GutTest

## Состояния сценария (scenarioOnly в data/conditions.json): Одержимость «Братства
## Колоса» — madness, но в случайный пул вида не входит; выдаётся только явным id.
## Каталог — боевой data/conditions.json.

const EffectRunner = preload("res://scripts/core/game/effect_runner.gd")


func _player() -> Dictionary:
	return {
		"hp": 5,
		"hp_max": 7,
		"sanity": 5,
		"sanity_max": 6,
		"clues": 1,
		"concentration": 0,
		"conditions": [],
		"conditions_flipped": {},
		"items": [],
		"skill_mods": {},
		"passive_mods": [],
	}


func test_only_obsession_is_scenario_only() -> void:
	# Голод (hunger) — общее безумие из базовой библиотеки (его дают встречи Азатота).
	var flagged: Array = []
	for id_v: Variant in Conditions.all_ids():
		if Conditions.is_scenario_only(String(id_v)):
			flagged.append(String(id_v))
	assert_eq(flagged, ["obsession"], "scenarioOnly — только Одержимость")


func test_kind_pool_skips_scenario_only() -> void:
	var madness: Array = Conditions.ids_of_kinds(["madness"])
	assert_does_not_have(madness, "obsession", "Одержимость не в пуле безумий")
	assert_has(madness, "hunger", "Голод остаётся в пуле")
	assert_has(madness, "paranoia", "обычные безумия на месте")
	assert_does_not_have(Conditions.ids_of_kinds([]), "obsession", "и не в пуле «любого вида»")


func test_random_madness_never_hands_obsession() -> void:
	# Все обычные безумия на руках — единственным «свободным» остаётся Одержимость,
	# но выдавать её случайно нельзя: verb ничего не делает.
	var p: Dictionary = _player()
	var pool: Array = Conditions.ids_of_kinds(["madness"])
	p["conditions"] = pool.duplicate()
	EffectRunner.run([{"do": "gainCondition", "kind": "madness"}], p)
	assert_does_not_have(p["conditions"], "obsession", "Одержимость случайно не выдана")
	assert_eq((p["conditions"] as Array).size(), pool.size(), "состав не изменился")


func test_explicit_id_still_grants_obsession() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainCondition", "condition": "obsession"}], p)
	assert_has(p["conditions"], "obsession", "явный id сценария выдаёт состояние")
	assert_eq(Conditions.kind_of("obsession"), "madness", "вид не тронут")
