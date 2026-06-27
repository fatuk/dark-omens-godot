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


# ── Боевой триггер карты (try_combat_trigger): Handcuffs — фокус → победа ──
# Использует РЕАЛЬНЫЙ актив "handcuffs" из data/assets.json (effect.triggered,
# on:combatEncounter → defeatMonster when monsterToughnessAtMost:2, cost spend:focus).


class MockCheck:
	extends RefCounted
	var cleared: bool = false

	func clear() -> void:
		cleared = true


class MockGS:
	extends Node
	var phase: String = "encounter"
	var players: Dictionary = {}
	var current_encounter: Dictionary = {}
	var _check := MockCheck.new()

	func _is_host() -> bool:
		return true

	func _current_pid() -> String:
		return "p"

	func _name_of(pid: String) -> String:
		return pid

	func _broadcast_sync() -> void:
		pass

	func _emit_changed() -> void:
		pass


func _combat_ctx(tough: int, focus: int) -> EncounterFlow:
	var gs: MockGS = autofree(MockGS.new())
	gs.players["p"] = {"items": [{"id": "handcuffs"}], "concentration": focus}
	gs.current_encounter = {"kind": "combat", "monsterId": "ghost", "toughness": tough}
	return EncounterFlow.new(gs)


func test_combat_trigger_defeats_weak_monster_spends_focus() -> void:
	var ef: EncounterFlow = _combat_ctx(2, 1)  # стойкость 2 ≤ 2, фокус 1
	assert_true(ef.try_combat_trigger("p", 0), "Handcuffs применён")
	var enc: Dictionary = ef._gs.current_encounter
	assert_true(bool(enc.get("defeated_by_trigger", false)), "монстр помечен повержённым")
	assert_true(
		bool((enc.get("resolution", {}) as Dictionary).get("won", false)), "победная резолюция"
	)
	assert_eq(int(ef._gs.players["p"]["concentration"]), 0, "1 фокус потрачен")
	assert_true((ef._gs._check as MockCheck).cleared, "active_check снят")


func test_combat_trigger_rejects_tough_monster() -> void:
	var ef: EncounterFlow = _combat_ctx(3, 5)  # стойкость 3 > 2 → не подходит
	assert_false(ef.try_combat_trigger("p", 0), "крепкий монстр — триггер не применяется")
	assert_eq(
		int(ef._gs.players["p"]["concentration"]), 5, "фокус не потрачен (карта пойдёт в check-mod)"
	)


func test_combat_trigger_rejects_without_focus() -> void:
	var ef: EncounterFlow = _combat_ctx(2, 0)  # нечем платить
	assert_false(ef.try_combat_trigger("p", 0), "нет фокуса — триггер не применяется")
	assert_false(ef._gs.current_encounter.has("resolution"), "резолюция не выставлена")


func test_combat_trigger_false_outside_combat() -> void:
	var ef: EncounterFlow = _combat_ctx(2, 1)
	ef._gs.current_encounter["kind"] = "general"  # не бой
	assert_false(ef.try_combat_trigger("p", 0), "вне боя — false (роутер пробует check-mod)")
