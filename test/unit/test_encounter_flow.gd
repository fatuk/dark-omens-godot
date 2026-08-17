extends GutTest

## Юнит-тест боевой резолюции (EncounterFlow._combat_resolution) — чистый расчёт
## урона по монстру. Фокус: ФИЗИЧЕСКОЕ сопротивление — монстр с physical-резистом
## получает вдвое меньше боевого урона (успехов Силы), но защита игрока (hp_loss)
## считается от СЫРОГО броска. Плюс пассивная митигация урона (reduceMonsterDamage)
## по принадлежащим активам. Читает _gs.players[pid].items → MockGS.

var _ef: EncounterFlow


func before_each() -> void:
	var gs: MockGS = MockGS.new()
	gs.players["p"] = {"items": []}  # без предметов → без митигации
	_ef = EncounterFlow.new(autofree(gs))


func test_combat_resolution_no_resist() -> void:
	var enc: Dictionary = {"monsterId": "ghoul", "health": 3, "combat": {"damage": 2}}
	var res: Dictionary = _ef._combat_resolution(enc, {"successes": 2, "dice": [5, 5]}, "p")
	assert_eq(int(res["dealt"]), 2, "без резиста — весь урон по монстру")
	assert_eq(int(res["health_after"]), 1, "3 − 2 = 1")


func test_combat_resolution_physical_resist_halves() -> void:
	# ghost = physical-резист → 4 успеха Силы наносят 2 монстру; защита игрока
	# (hp_loss) считается от сырых 4.
	var enc: Dictionary = {"monsterId": "ghost", "health": 3, "combat": {"damage": 3}}
	var res: Dictionary = _ef._combat_resolution(enc, {"successes": 4, "dice": [5, 5, 6, 6]}, "p")
	assert_eq(int(res["dealt"]), 2, "physical-резист: 4 → 2 по монстру")
	assert_eq(int(res["health_after"]), 1, "3 − 2 = 1")
	assert_eq(int(res["hp_loss"]), 0, "hp_loss от сырого броска: max(0, 3 − 4) = 0")
	assert_eq(int((res["strength"] as Dictionary)["successes"]), 4, "сырой бросок сохранён в логе")


func test_combat_resolution_reduces_damage_with_owned_asset() -> void:
	# fishing_net (reduceMonsterDamage 1, min 1) → урон монстра 3 → 2 ДО вычитания успехов.
	var gs: MockGS = MockGS.new()
	gs.players["p"] = {"items": [{"id": "fishing_net", "exhausted": false}]}
	var ef: EncounterFlow = EncounterFlow.new(autofree(gs))
	var enc: Dictionary = {"monsterId": "ghoul", "health": 3, "combat": {"damage": 3}}
	var res: Dictionary = ef._combat_resolution(enc, {"successes": 1, "dice": [5]}, "p")
	assert_eq(int(res["hp_loss"]), 1, "урон 3 − 1(fishing_net) = 2, минус 1 успех = 1")


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
	var encounter_discard: Array = []
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

	func announce_action(_pid: String, _id: String, _params: Dictionary = {}) -> void:
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


# ── Сброс встреч ──────────────────────────────────────────────────────────────
#
# Карточка уходит в сброс в момент ВЫДАЧИ, а не по исходу: врата могли не
# закрыться, проверка — провалиться, встреча всё равно сыграна и повторно не
# выпадает. Сброс уезжает в реле полем exclude запроса.


func _discard_ctx() -> EncounterFlow:
	var gs: MockGS = autofree(MockGS.new())
	gs.players["p"] = {"items": []}
	return EncounterFlow.new(gs)


func test_discard_collects_source_id() -> void:
	var ef: EncounterFlow = _discard_ctx()
	ef._discard_encounter({"sourceId": "ow-dreamlands-01", "name": "Кошки Ултара"})
	assert_eq(ef._gs.encounter_discard, ["ow-dreamlands-01"], "карточка ушла в сброс")


func test_discard_ignores_repeat_and_stubs() -> void:
	var ef: EncounterFlow = _discard_ctx()
	ef._discard_encounter({"sourceId": "ow-abyss-03"})
	ef._discard_encounter({"sourceId": "ow-abyss-03"})
	assert_eq(ef._gs.encounter_discard.size(), 1, "повтор в сброс не дублируется")
	ef._discard_encounter({"name": "Заглушка"})
	assert_eq(ef._gs.encounter_discard.size(), 1, "заглушка без sourceId в сброс не идёт")


# ── Назначение встречи из debug-консоли ───────────────────────────────────────


class MockGSDebug:
	extends Node
	var players: Dictionary = {}
	var _encounter: EncounterFlow

	func _name_of(pid: String) -> String:
		return pid


func _debug_gs() -> MockGSDebug:
	var gs: MockGSDebug = autofree(MockGSDebug.new())
	gs.players["p"] = {}
	gs.players["q"] = {}
	gs._encounter = EncounterFlow.new(gs)
	return gs


func test_debug_assign_is_per_player() -> void:
	var gs: MockGSDebug = _debug_gs()
	gs._encounter.debug_assign("p", {"kind": "gate"})
	assert_eq(String(gs._encounter.debug_assigned("p").get("kind", "")), "gate", "назначено p")
	assert_true(gs._encounter.debug_assigned("q").is_empty(), "соседу ничего не назначено")


func test_debug_assign_local_maps_to_site_specific() -> void:
	# «local» — не отдельный kind, а general с привязкой к клетке.
	var gs: MockGSDebug = _debug_gs()
	DebugGrant.assign_encounter(gs, "p", "local", "")
	var spec: Dictionary = gs._encounter.debug_assigned("p")
	assert_eq(String(spec.get("kind", "")), "general", "kind запроса — general")
	assert_true(bool(spec.get("siteSpecific", false)), "с привязкой к клетке")


func test_debug_assign_world_only_for_gate() -> void:
	var gs: MockGSDebug = _debug_gs()
	var msg: String = DebugGrant.assign_encounter(gs, "p", "research", "Yuggoth")
	assert_string_contains(msg, "только для gate", "мир не для врат — отказ")
	assert_true(gs._encounter.debug_assigned("p").is_empty(), "ничего не назначено")
	DebugGrant.assign_encounter(gs, "p", "gate", "Yuggoth")
	assert_eq(String(gs._encounter.debug_assigned("p").get("world", "")), "Yuggoth", "мир врат лёг")


func test_debug_assign_rejects_unknown_kind_and_player() -> void:
	var gs: MockGSDebug = _debug_gs()
	assert_string_contains(
		DebugGrant.assign_encounter(gs, "p", "duel", ""), "вид встречи", "неизвестный вид"
	)
	assert_string_contains(
		DebugGrant.assign_encounter(gs, "nobody", "gate", ""), "нет игрока", "нет такого игрока"
	)
