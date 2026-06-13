extends GutTest

## Юнит-тест боевой резолюции (EncounterFlow._combat_resolution) — чистый расчёт
## урона по монстру. Фокус: ФИЗИЧЕСКОЕ сопротивление — монстр с physical-резистом
## получает вдвое меньше боевого урона (успехов Силы), но защита игрока (hp_loss)
## считается от СЫРОГО броска. _combat_resolution не трогает _gs → dummy-Node.

var _ef: EncounterFlow


func before_each() -> void:
	_ef = EncounterFlow.new(autofree(Node.new()))


func test_combat_resolution_no_resist() -> void:
	var enc: Dictionary = {"monsterId": "ghoul", "health": 3, "combat": {"damage": 2}}
	var res: Dictionary = _ef._combat_resolution(enc, {"successes": 2, "dice": [5, 5]})
	assert_eq(int(res["dealt"]), 2, "без резиста — весь урон по монстру")
	assert_eq(int(res["health_after"]), 1, "3 − 2 = 1")


func test_combat_resolution_physical_resist_halves() -> void:
	# ghost = physical-резист → 4 успеха Силы наносят 2 монстру; защита игрока
	# (hp_loss) считается от сырых 4.
	var enc: Dictionary = {"monsterId": "ghost", "health": 3, "combat": {"damage": 3}}
	var res: Dictionary = _ef._combat_resolution(enc, {"successes": 4, "dice": [5, 5, 6, 6]})
	assert_eq(int(res["dealt"]), 2, "physical-резист: 4 → 2 по монстру")
	assert_eq(int(res["health_after"]), 1, "3 − 2 = 1")
	assert_eq(int(res["hp_loss"]), 0, "hp_loss от сырого броска: max(0, 3 − 4) = 0")
	assert_eq(int((res["strength"] as Dictionary)["successes"]), 4, "сырой бросок сохранён в логе")
