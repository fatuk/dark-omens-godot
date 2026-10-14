extends GutTest

## Юнит-тест боевой резолюции (CombatFlow.resolution) — чистый расчёт
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
	var res: Dictionary = _ef.combat.resolution(enc, {"successes": 2, "dice": [5, 5]}, "p")
	assert_eq(int(res["dealt"]), 2, "без резиста — весь урон по монстру")
	assert_eq(int(res["health_after"]), 1, "3 − 2 = 1")


func test_combat_resolution_physical_resist_halves() -> void:
	# ghost = physical-резист → 4 успеха Силы наносят 2 монстру; защита игрока
	# (hp_loss) считается от сырых 4.
	var enc: Dictionary = {"monsterId": "ghost", "health": 3, "combat": {"damage": 3}}
	var res: Dictionary = _ef.combat.resolution(enc, {"successes": 4, "dice": [5, 5, 6, 6]}, "p")
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
	var res: Dictionary = ef.combat.resolution(enc, {"successes": 1, "dice": [5]}, "p")
	assert_eq(int(res["hp_loss"]), 1, "урон 3 − 1(fishing_net) = 2, минус 1 успех = 1")


# ── Боевой триггер карты (CombatFlow.try_trigger): Handcuffs — фокус → победа ──
# Использует РЕАЛЬНЫЙ актив "handcuffs" из data/assets.json (effect.triggered,
# on:combatEncounter → defeatMonster when monsterToughnessAtMost:2, cost spend:focus).


class MockCheck:
	extends RefCounted
	var cleared: bool = false
	var started: Array = []

	func clear() -> void:
		cleared = true

	func start(kind: String, pid: String, skill: String, mod: int, ctx: String) -> void:
		started.append({"kind": kind, "pid": pid, "skill": skill, "mod": mod, "ctx": ctx})


# Стабы подсистем, которых касается бой: размер партии (стойкость), мешок
# монстров (повержённый возвращается), Слухи (гибель монстра их развеивает).
class MockCampaign:
	extends RefCounted

	func balance_player_count() -> int:
		return 1


class MockBoard:
	extends RefCounted
	var bagged: Array = []

	func return_monster_to_bag(mid: String) -> void:
		bagged.append(mid)

	func count_gates_of_color(_c: String) -> int:
		return 0

	func current_omen_color() -> String:
		return "green"

	func monster_choices() -> Array:
		return []


class MockRumor:
	extends RefCounted

	func notify_monster_defeated(_loc: String) -> void:
		pass


class MockMystery:
	extends RefCounted

	func notify_monster_defeated(_mid: String, _pid: String) -> void:
		pass


class MockGS:
	extends Node
	var phase: String = "encounter"
	var active_mystery: int = 0
	var _mystery := MockMystery.new()
	var players: Dictionary = {}
	var current_encounter: Dictionary = {}
	var encounter_discard: Array = []
	var encounter_choices: Array = []
	var monsters: Dictionary = {}
	var entities: Dictionary = {}
	var gates: Dictionary = {}
	var campaign: Dictionary = {}
	var active_check: Dictionary = {}
	var turn_order: Array = ["p"]
	var map: RefCounted = null  # MockMap — граф локаций для move (ставит тест)
	var shop_reserve: Array = []  # витрина — для gainAsset from:"reserve"
	var board_effects: Array = []  # что ушло в apply_board_effect
	var _check := MockCheck.new()
	var _campaign := MockCampaign.new()
	var _board := MockBoard.new()
	var _rumor := MockRumor.new()

	func is_host() -> bool:
		return true

	var cur_pid: String = "p"  # чей сейчас ход (мок current_pid())

	func current_pid() -> String:
		return cur_pid

	func name_of(pid: String) -> String:
		return pid

	func monster_def(mid: String) -> Dictionary:
		return MonsterCatalog.resolve(MonsterCatalog.by_id(mid), campaign.get("ancientOne", {}))

	func broadcast_sync() -> void:
		pass

	func emit_changed() -> void:
		pass

	func announce_action(_pid: String, _id: String, _params: Dictionary = {}) -> void:
		pass

	func apply_board_effect(node: Dictionary) -> void:
		board_effects.append(node)


func _combat_ctx(tough: int, focus: int) -> EncounterFlow:
	var gs: MockGS = autofree(MockGS.new())
	gs.players["p"] = {"items": [{"id": "handcuffs"}], "concentration": focus}
	gs.current_encounter = {"kind": "combat", "monsterId": "ghost", "toughness": tough}
	return EncounterFlow.new(gs)


func test_combat_trigger_defeats_weak_monster_spends_focus() -> void:
	var ef: EncounterFlow = _combat_ctx(2, 1)  # стойкость 2 ≤ 2, фокус 1
	assert_true(ef.combat.try_trigger("p", 0), "Handcuffs применён")
	var enc: Dictionary = ef._gs.current_encounter
	assert_true(bool(enc.get("defeated_by_trigger", false)), "монстр помечен повержённым")
	assert_true(
		bool((enc.get("resolution", {}) as Dictionary).get("won", false)), "победная резолюция"
	)
	assert_eq(int(ef._gs.players["p"]["concentration"]), 0, "1 фокус потрачен")
	assert_true((ef._gs._check as MockCheck).cleared, "active_check снят")


func test_combat_trigger_rejects_tough_monster() -> void:
	var ef: EncounterFlow = _combat_ctx(3, 5)  # стойкость 3 > 2 → не подходит
	assert_false(ef.combat.try_trigger("p", 0), "крепкий монстр — триггер не применяется")
	assert_eq(
		int(ef._gs.players["p"]["concentration"]), 5, "фокус не потрачен (карта пойдёт в check-mod)"
	)


func test_combat_trigger_rejects_without_focus() -> void:
	var ef: EncounterFlow = _combat_ctx(2, 0)  # нечем платить
	assert_false(ef.combat.try_trigger("p", 0), "нет фокуса — триггер не применяется")
	assert_false(ef._gs.current_encounter.has("resolution"), "резолюция не выставлена")


func test_combat_trigger_false_outside_combat() -> void:
	var ef: EncounterFlow = _combat_ctx(2, 1)
	ef._gs.current_encounter["kind"] = "general"  # не бой
	assert_false(ef.combat.try_trigger("p", 0), "вне боя — false (роутер пробует check-mod)")


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
	var campaign: Dictionary = {}
	var _encounter: EncounterFlow

	func name_of(pid: String) -> String:
		return pid

	func monster_def(mid: String) -> Dictionary:
		return MonsterCatalog.resolve(MonsterCatalog.by_id(mid), campaign.get("ancientOne", {}))


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


# ── Бой со всеми монстрами клетки, порядок — выбор сыщика ────────────────────


# Клетка "loc" с монстрами; сыщик "p" стоит на ней.
func _arena(mons: Array) -> EncounterFlow:
	var gs: MockGS = autofree(MockGS.new())
	gs.players["p"] = {"location": "loc", "hp": 5, "sanity": 5, "items": []}
	gs.monsters = {"loc": mons}
	return EncounterFlow.new(gs)


func test_one_monster_fights_immediately() -> void:
	var ef: EncounterFlow = _arena([{"id": "ghoul", "health": 2}])
	ef.begin_turn()
	assert_eq(String(ef._gs.current_encounter.get("kind", "")), "combat", "бой начат сразу")
	assert_eq(int(ef._gs.current_encounter.get("monsterIndex", -1)), 0)
	assert_true((ef._gs.encounter_choices as Array).is_empty(), "выбирать не из чего")


func test_two_monsters_offer_order_choice() -> void:
	# Два монстра — сыщик выбирает, с кем драться первым; бой ещё не начат.
	var ef: EncounterFlow = _arena([{"id": "ghoul", "health": 2}, {"id": "cultist", "health": 1}])
	ef.begin_turn()
	assert_eq(ef._gs.encounter_choices, ["combat:0", "combat:1"], "варианты — индексы на клетке")
	assert_true(ef._gs.current_encounter.is_empty(), "до выбора боя нет")


func test_choose_combat_index_fights_that_monster() -> void:
	var ef: EncounterFlow = _arena([{"id": "ghoul", "health": 2}, {"id": "cultist", "health": 1}])
	ef.begin_turn()
	assert_true(ef.host_apply_choose("p", "combat:1"), "выбор принят")
	assert_eq(
		String(ef._gs.current_encounter.get("monsterId", "")), "cultist", "дерёмся с выбранным"
	)
	assert_eq(int(ef._gs.current_encounter.get("monsterIndex", -1)), 1)
	assert_true((ef._gs.encounter_choices as Array).is_empty(), "выбор потреблён")


func test_lost_fight_continues_to_next_monster() -> void:
	# Правило: поражение не освобождает от остальных. Проиграли культисту (idx 1) —
	# он помечен, а очередь сама ведёт к гулю: он единственный небитый, выбора нет.
	var ef: EncounterFlow = _arena([{"id": "ghoul", "health": 2}, {"id": "cultist", "health": 1}])
	ef.begin_turn()
	ef.host_apply_choose("p", "combat:1")
	ef._gs.current_encounter["resolution"] = {"won": false, "hp_loss": 1, "health_after": 1}
	ef.combat.commit("p")
	assert_true(
		bool((ef._gs.monsters["loc"][1] as Dictionary).get("fought", false)), "выживший помечен"
	)
	assert_eq((ef._gs.monsters["loc"] as Array).size(), 2, "никто не снят")
	assert_true(ef.continue_encounter_turn("p"), "ход продолжается")
	assert_eq(String(ef._gs.current_encounter.get("monsterId", "")), "ghoul", "следующий — гуль")
	assert_eq(int(ef._gs.current_encounter.get("monsterIndex", -1)), 0)


func test_won_fight_removes_the_right_instance() -> void:
	# Победа над ВТОРЫМ монстром снимает второго, а не первого (раньше индекс
	# был прибит к нулю).
	var ef: EncounterFlow = _arena([{"id": "ghoul", "health": 2}, {"id": "cultist", "health": 1}])
	ef.begin_turn()
	ef.host_apply_choose("p", "combat:1")
	ef._gs.current_encounter["resolution"] = {"won": true, "hp_loss": 0, "health_after": 0}
	ef.combat.commit("p")
	var left: Array = ef._gs.monsters["loc"]
	assert_eq(left.size(), 1, "снят один")
	assert_eq(String((left[0] as Dictionary).get("id", "")), "ghoul", "остался гуль")
	assert_eq(ef._gs._board.bagged, ["cultist"], "культист вернулся в мешок")


func test_all_fought_with_survivor_ends_turn() -> void:
	# Единственный монстр выжил — бои исчерпаны, но клетка занята: встречи в
	# локации не будет, ход завершается.
	var ef: EncounterFlow = _arena([{"id": "ghoul", "health": 3}])
	ef.begin_turn()
	ef._gs.current_encounter["resolution"] = {"won": false, "hp_loss": 2, "health_after": 2}
	ef.combat.commit("p")
	assert_false(ef.continue_encounter_turn("p"), "ход завершён — выживший запирает локацию")
	assert_eq((ef._gs.monsters["loc"] as Array).size(), 1, "монстр остался")
	assert_eq(
		int((ef._gs.monsters["loc"][0] as Dictionary).get("health", 0)), 2, "здоровье сохранено"
	)


func test_new_turn_clears_fought_marks() -> void:
	# Пометка «уже дрался» живёт один ход: на следующем с выжившим дерёмся снова.
	var ef: EncounterFlow = _arena([{"id": "ghoul", "health": 2, "fought": true}])
	ef.begin_turn()
	assert_false(
		bool((ef._gs.monsters["loc"][0] as Dictionary).get("fought", false)), "пометка снята"
	)
	assert_eq(String(ef._gs.current_encounter.get("kind", "")), "combat", "и бой начат")


func test_legacy_string_instance_can_be_marked() -> void:
	# Старый формат экземпляра — голая строка id; пометку в неё не положить,
	# поэтому проигрыш нормализует её в словарь.
	var ef: EncounterFlow = _arena(["ghoul", "cultist"])
	ef.begin_turn()
	ef.host_apply_choose("p", "combat:0")
	ef._gs.current_encounter["resolution"] = {"won": false, "hp_loss": 0, "health_after": 1}
	ef.combat.commit("p")
	var inst: Variant = ef._gs.monsters["loc"][0]
	assert_true(inst is Dictionary, "нормализован в словарь")
	assert_true(bool((inst as Dictionary).get("fought", false)))
	assert_eq(ef.combat.unfought_indices("loc"), [1], "второй ещё не бит")


# ── Несколько сыщиков на одной клетке с монстрами ────────────────────────────
#
# Фаза встреч идёт по сыщикам по очереди (PhaseController.advance_encounter_turn
# → begin_turn для каждого). Каждый обязан драться с каждым монстром клетки —
# пометки «уже дрался» принадлежат ХОДУ, а не монстру: begin_turn следующего
# сыщика их снимает. Здоровье монстра при этом общее: второй сыщик бьёт то, что
# осталось после первого, а поверженного первым не видит вовсе.


func _arena_two(mons: Array) -> EncounterFlow:
	var ef: EncounterFlow = _arena(mons)
	ef._gs.players["q"] = {"location": "loc", "hp": 5, "sanity": 5, "items": []}
	return ef


func test_second_investigator_fights_survivor_with_remaining_health() -> void:
	var ef: EncounterFlow = _arena_two([{"id": "ghoul", "health": 3}])
	# Первый сыщик проиграл: гуль ранен до 1 и помечен.
	ef.begin_turn()
	ef._gs.current_encounter["resolution"] = {"won": false, "hp_loss": 1, "health_after": 1}
	ef.combat.commit("p")
	assert_false(ef.continue_encounter_turn("p"), "ход первого завершён")
	# Ход второго: пометка первого ему не мешает, а гуль встречает его раненым.
	ef._gs.cur_pid = "q"
	ef.begin_turn()
	assert_eq(String(ef._gs.current_encounter.get("kind", "")), "combat", "второй тоже дерётся")
	assert_eq(int(ef._gs.current_encounter.get("health", -1)), 1, "здоровье общее — гуль ранен")
	assert_false(
		bool((ef._gs.monsters["loc"][0] as Dictionary).get("fought", false)),
		"пометка первого сыщика снята на ходу второго"
	)


func test_second_investigator_does_not_see_defeated_monster() -> void:
	var ef: EncounterFlow = _arena_two(
		[{"id": "ghoul", "health": 1}, {"id": "cultist", "health": 1}]
	)
	# Первый выбрал культиста и победил — тот снят.
	ef.begin_turn()
	ef.host_apply_choose("p", "combat:1")
	ef._gs.current_encounter["resolution"] = {"won": true, "hp_loss": 0, "health_after": 0}
	ef.combat.commit("p")
	assert_true(ef.continue_encounter_turn("p"), "у первого остался гуль")
	# Первому — гуль; сдадимся ему и завершим ход.
	ef._gs.current_encounter["resolution"] = {"won": false, "hp_loss": 1, "health_after": 1}
	ef.combat.commit("p")
	assert_false(ef.continue_encounter_turn("p"))
	# Второму достаётся только гуль: выбора нет, бой сразу, культиста уже нет.
	ef._gs.cur_pid = "q"
	ef.begin_turn()
	assert_true((ef._gs.encounter_choices as Array).is_empty(), "один монстр — без выбора")
	assert_eq(String(ef._gs.current_encounter.get("monsterId", "")), "ghoul")
	assert_eq((ef._gs.monsters["loc"] as Array).size(), 1, "поверженный первым не воскрес")


# ── Предотвращение потери: бинты за себя и за соседа ──────────────────────────
#
# Окно — между броском и «Завершить»: resolution уже есть, commit ещё нет.


func _wounded(items_p: Array, items_q: Array, hp_loss: int, sanity_loss: int = 0) -> EncounterFlow:
	var ef: EncounterFlow = _arena([{"id": "ghoul", "health": 3}])
	ef._gs.players["p"]["items"] = items_p
	ef._gs.players["q"] = {
		"location": "loc", "hp": 5, "sanity": 5, "items": items_q, "concentration": 1
	}
	ef.begin_turn()
	# Состояние ровно как в игре после броска Силы: Воля заморожена (enc.will и
	# sanity_loss), Сила брошена с 0 успехов (active_check.rolled), resolution ещё
	# НЕТ — она появится только при «Завершить». hp_loss = урон монстра.
	var enc: Dictionary = ef._gs.current_encounter
	enc["combat"] = {"damage": hp_loss}
	enc["will"] = {"dice": [], "successes": 0}
	enc["sanity_loss"] = sanity_loss
	ef._gs.active_check = {"owner": "combat", "rolled": true, "successes": 0, "dice": [1]}
	return ef


func test_bandages_prevent_own_damage() -> void:
	var ef: EncounterFlow = _wounded([{"id": "bandages", "exhausted": false}], [], 3)
	assert_true(ef.play_prevent_loss("p", 0), "бинты сыграны")
	assert_eq(int(ef._gs.current_encounter.get("prevented_hp", 0)), 2, "предотвращено 2 из 3")
	assert_true((ef._gs.players["p"]["items"] as Array).is_empty(), "бинты сброшены")
	ef.combat.commit("p")
	assert_eq(int(ef._gs.players["p"]["hp"]), 4, "списана только оставшаяся 1")


func test_neighbour_bandages_prevent_damage_in_others_turn() -> void:
	# Ход p, бинты у q на той же клетке — q играет их со своего экрана.
	var ef: EncounterFlow = _wounded([], [{"id": "bandages", "exhausted": false}], 2)
	assert_true(ef.play_prevent_loss("q", 0), "сосед прикрыл")
	assert_true((ef._gs.players["q"]["items"] as Array).is_empty(), "бинты соседа сброшены")
	ef.combat.commit("p")
	assert_eq(int(ef._gs.players["p"]["hp"]), 5, "раненый не потерял ничего")


func test_prevent_loss_rejected_from_another_location() -> void:
	var ef: EncounterFlow = _wounded([], [{"id": "bandages", "exhausted": false}], 2)
	ef._gs.players["q"]["location"] = "far"
	assert_false(ef.play_prevent_loss("q", 0), "с другой клетки не дотянуться")
	assert_eq((ef._gs.players["q"]["items"] as Array).size(), 1, "карта цела")


func test_prevent_loss_rejected_before_roll_and_when_nothing_left() -> void:
	var ef: EncounterFlow = _wounded([{"id": "bandages", "exhausted": false}], [], 0)
	assert_false(ef.play_prevent_loss("p", 0), "терять нечего — карту не жжём")
	ef._gs.current_encounter["combat"] = {"damage": 2}
	ef._gs.active_check["rolled"] = false
	assert_false(ef.play_prevent_loss("p", 0), "до броска Силы потеря неизвестна")
	ef._gs.active_check["rolled"] = true
	assert_true(ef.play_prevent_loss("p", 0), "после броска — окно открыто")


func test_prevent_loss_window_also_after_resolution_fixed() -> void:
	# Итог уже зафиксирован (триггер карты, победа по ужасу) — окно тоже открыто.
	var ef: EncounterFlow = _wounded([{"id": "bandages", "exhausted": false}], [], 0)
	ef._gs.active_check = {}
	ef._gs.current_encounter["resolution"] = {"won": false, "hp_loss": 2, "health_after": 3}
	assert_true(ef.play_prevent_loss("p", 0), "по зафиксированной resolution")


func test_prevent_loss_does_not_overprevent_across_cards() -> void:
	# Две пары бинтов на потерю 3: первая снимает 2, вторая — только оставшуюся 1.
	var ef: EncounterFlow = _wounded(
		[{"id": "bandages", "exhausted": false}, {"id": "bandages", "exhausted": false}], [], 3
	)
	assert_true(ef.play_prevent_loss("p", 0))
	assert_true(ef.play_prevent_loss("p", 0), "вторая (сдвинулась на индекс 0)")
	assert_eq(int(ef._gs.current_encounter.get("prevented_hp", 0)), 3, "ровно потеря, не больше")
	ef.combat.commit("p")
	assert_eq(int(ef._gs.players["p"]["hp"]), 5)


func test_whiskey_prevents_sanity_loss() -> void:
	var ef: EncounterFlow = _wounded([{"id": "whiskey", "exhausted": false}], [], 0, 2)
	assert_true(ef.play_prevent_loss("p", 0), "виски — по рассудку")
	ef.combat.commit("p")
	assert_eq(int(ef._gs.players["p"]["sanity"]), 5, "рассудок цел")


func test_whiskey_window_opens_with_will_roll_before_freeze() -> void:
	# Шаг 1: Воля брошена (0 успехов, ужас 2), «Дальше» ещё не нажато — рассудок
	# уже известен, виски играется; бинты (здоровье) — ещё нет.
	var ef: EncounterFlow = _wounded(
		[{"id": "whiskey", "exhausted": false}, {"id": "bandages", "exhausted": false}], [], 3
	)
	var enc: Dictionary = ef._gs.current_encounter
	enc.erase("will")
	enc.erase("sanity_loss")
	enc["horror"] = {"damage": 2}
	assert_false(ef.play_prevent_loss("p", 1), "здоровье до броска Силы неизвестно")
	assert_true(ef.play_prevent_loss("p", 0), "рассудок известен с броска Воли")
	assert_eq(int(enc.get("prevented_sanity", 0)), 2)
	# «Дальше»: заморозка Воли считает потерю тем же расчётом → 2, минус предотвращённое.
	enc["will"] = {"dice": [], "successes": 0}
	enc["sanity_loss"] = 2
	ef._gs.active_check = {"owner": "combat", "rolled": false}
	assert_eq(ef._remaining_loss(enc, "sanity"), 0, "терять больше нечего")
	ef._gs.active_check = {"owner": "combat", "rolled": true, "successes": 0, "dice": [1]}
	ef.combat.commit("p")
	assert_eq(int(ef._gs.players["p"]["sanity"]), 5, "рассудок цел")


func test_whiskey_window_stays_open_in_strength_preroll() -> void:
	# Шаг 2 до броска Силы: Воля заморожена (рассудок известен), Сила не брошена.
	var ef: EncounterFlow = _wounded([{"id": "whiskey", "exhausted": false}], [], 2, 2)
	ef._gs.active_check = {"owner": "combat", "rolled": false}
	assert_true(ef.play_prevent_loss("p", 0), "рассудок известен — окно открыто")


func test_totem_is_exhausted_not_discarded_and_covers_only_owner() -> void:
	# Оберег: без цены, oncePerRound, без площадной цели — за соседа сыграть нельзя,
	# за себя — раз в раунд (карта истощается, а не сбрасывается).
	var ef: EncounterFlow = _wounded(
		[{"id": "protective_totem", "exhausted": false}],
		[{"id": "protective_totem", "exhausted": false}],
		2
	)
	assert_false(ef.play_prevent_loss("q", 0), "чужого оберег не прикрывает")
	assert_true(ef.play_prevent_loss("p", 0), "свой — да")
	var it: Dictionary = ef._gs.players["p"]["items"][0]
	assert_true(bool(it.get("exhausted", false)), "истощён до конца раунда")
	assert_false(ef.play_prevent_loss("p", 0), "второй раз в раунд — нет")


func test_jewelry_from_while_owned_spends_focus() -> void:
	# Зачарованные украшения: узел в whileOwned, цена — фокус, карта остаётся.
	var ef: EncounterFlow = _wounded([{"id": "enchanted_jewelry", "exhausted": false}], [], 0, 2)
	ef._gs.players["p"]["concentration"] = 1
	assert_true(ef.play_prevent_loss("p", 0))
	assert_eq(int(ef._gs.players["p"]["concentration"]), 0, "фокус потрачен")
	assert_eq((ef._gs.players["p"]["items"] as Array).size(), 1, "карта не сброшена")
	ef._gs.players["p"]["concentration"] = 0
	assert_false(ef.play_prevent_loss("p", 0), "без фокуса — нечем платить")


# ── Призрак: успехи Воли ранят монстра, атаки (Силы) нет ──
# horror.damageWithSuccesses + combat.skill "none": итог боя фиксируется сразу после
# шага Воли, сыщик урона не получает, резист (physical) урон Волей не режет.


func _ghost_ctx(health: int, will_succ: int, dice: Array) -> EncounterFlow:
	var gs: MockGS = autofree(MockGS.new())
	gs.players["p"] = {"items": [], "sanity": 5}
	gs.current_encounter = {
		"kind": "combat",
		"monsterId": "ghost",
		"toughness": 2,
		"health": health,
		"horror": {"skill": "will", "modifier": -1, "damage": 2, "damageWithSuccesses": true},
		"combat": {"skill": "none", "modifier": 0, "damage": 0},
	}
	gs.active_check = {
		"rolled": true, "successes": will_succ, "dice": dice, "passed": will_succ > 0
	}
	return EncounterFlow.new(gs)


func test_ghost_will_successes_damage_monster_and_end_combat() -> void:
	var ef: EncounterFlow = _ghost_ctx(2, 2, [5, 6])
	assert_true(ef.combat.resolve("p"), "шаг Воли принят")
	var enc: Dictionary = ef._gs.current_encounter
	assert_true(enc.has("resolution"), "атаки нет — итог сразу")
	assert_true(bool(enc["no_strength_step"]), "шаг Силы помечен пропущенным")
	var r: Dictionary = enc["resolution"]
	assert_eq(int(r["dealt"]), 2, "2 успеха Воли → −2 (резист не режет)")
	assert_eq(int(r["health_after"]), 0, "2 − 2 = 0")
	assert_true(bool(r["won"]), "монстр повержен")
	assert_eq(int(r["hp_loss"]), 0, "атаки нет — сыщик цел")
	assert_true((ef._gs._check as MockCheck).cleared, "проверка Силы не стартует")


func test_ghost_zero_successes_keeps_monster() -> void:
	var ef: EncounterFlow = _ghost_ctx(2, 0, [1, 2])
	ef.combat.resolve("p")
	var r: Dictionary = ef._gs.current_encounter["resolution"]
	assert_false(bool(r["won"]), "0 успехов — монстр стоит")
	assert_eq(int(r["health_after"]), 2, "здоровье не тронуто")
	assert_eq(int(ef._gs.current_encounter["sanity_loss"]), 2, "ужас 2 − 0 успехов = −2 рассудка")


func test_will_damage_adds_to_strength_resolution() -> void:
	# Гипотетический монстр с damageWithSuccesses И атакой: урон Волей суммируется
	# с уроном Силы (после резиста).
	var enc: Dictionary = {
		"monsterId": "ghoul", "health": 4, "combat": {"damage": 1}, "will_dealt": 1
	}
	var res: Dictionary = _ef.combat.resolution(enc, {"successes": 2, "dice": [5, 5]}, "p")
	assert_eq(int(res["dealt"]), 3, "2 Силы + 1 Волей")
	assert_eq(int(res["health_after"]), 1, "4 − 3 = 1")


# ── Кубик способности (horror.defeatOnDie) и монстры без ужаса (horror.skill none) ──


func test_defeat_on_die_wins_when_face_matches() -> void:
	seed(7)
	var won := 0
	var lost := 0
	for _i in range(60):
		var gs: MockGS = autofree(MockGS.new())
		gs.players["p"] = {"items": [], "sanity": 5}
		gs.current_encounter = {
			"kind": "combat",
			"monsterId": "colour_out_of_space",
			"toughness": 2,
			"health": 2,
			"horror": {"skill": "will", "modifier": 0, "damage": 2, "defeatOnDie": "5-6"},
			"combat": {"skill": "none", "modifier": 0, "damage": 0},
		}
		gs.active_check = {"rolled": true, "successes": 1, "dice": [5], "passed": true}
		var ef := EncounterFlow.new(gs)
		ef.combat.resolve("p")
		var enc: Dictionary = gs.current_encounter
		var die: int = int(enc["ability_die"])
		var r: Dictionary = enc["resolution"]
		if die >= 5:
			assert_true(bool(r["won"]), "грань %d → повержен" % die)
			won += 1
		else:
			assert_false(bool(r["won"]), "грань %d → уцелел (атаки нет — итог сразу)" % die)
			lost += 1
	assert_gt(won, 0, "за 60 бросков хоть раз выпало 5-6")
	assert_gt(lost, 0, "за 60 бросков хоть раз выпало 1-4")


func test_no_horror_step_starts_strength_immediately() -> void:
	var gs: MockGS = autofree(MockGS.new())
	gs.players["p"] = {"items": [], "location": "L1", "sanity": 5}
	gs.monsters["L1"] = [{"id": "riot", "health": 3}]
	var ef := EncounterFlow.new(gs)
	ef._begin_combat("p", 0)
	var enc: Dictionary = gs.current_encounter
	assert_true(bool(enc.get("no_horror_step", false)), "ужаса нет — шаг Воли пропущен")
	assert_eq(int((enc["will"] as Dictionary)["successes"]), 0, "Воля заморожена пустой")
	assert_eq(int(enc["sanity_loss"]), 0, "рассудок не теряется")
	var st: Dictionary = (gs._check as MockCheck).started[0]
	assert_eq(String(st["skill"]), "strength", "сразу стартует проверка Силы")


func test_dice_face_matches() -> void:
	assert_true(Dice.face_matches("5-6", 5))
	assert_true(Dice.face_matches("5-6", 6))
	assert_false(Dice.face_matches("5-6", 4))
	assert_true(Dice.face_matches("1", 1))
	assert_true(Dice.face_matches("1,2", 2))
	assert_false(Dice.face_matches("1,2", 3))


# ── move в эффектах встречи: выбор назначения через pending_choice ──
# Юггот «Перелёт на крыльях»: onSuccess [move, gainClue, closeGate]. Раньше в ctx
# встречи не было графа локаций, и move молча пропадал.


class MockMap:
	extends RefCounted
	var _locs: Array = [
		{"id": "A", "name": "LOC_A", "connections": ["B"]},
		{"id": "B", "name": "LOC_B", "connections": ["A", "C"]},
		{"id": "C", "name": "LOC_C", "connections": ["B"]},
	]

	func all() -> Array:
		return _locs

	func by_id(id: String) -> Dictionary:
		for l_v: Variant in _locs:
			if String((l_v as Dictionary).get("id", "")) == id:
				return l_v
		return {}

	func type_of(_id: String) -> String:
		return "city"


func _move_ctx() -> EncounterFlow:
	var gs: MockGS = autofree(MockGS.new())
	gs.map = MockMap.new()
	gs.players["p"] = {"items": [], "location": "A", "clues": 0, "investigator": ""}
	gs.turn_order = ["p"]
	gs.current_encounter = {
		"kind": "general",
		"onSuccess": [{"do": "move"}, {"do": "gainClue", "count": 1}],
		"onFailure": [],
	}
	gs.active_check = {"passed": true, "rolled": true, "successes": 1, "dice": [5]}
	return EncounterFlow.new(gs)


func test_encounter_move_pends_destination_then_moves() -> void:
	var ef: EncounterFlow = _move_ctx()
	ef._commit_outcome("p")
	var enc: Dictionary = ef._gs.current_encounter
	var pending: Dictionary = enc.get("pending_choice", {})
	assert_eq(String(pending.get("kind", "")), "destination", "move → выбор назначения")
	var refs: Array = []
	for o_v: Variant in pending.get("options", []):
		refs.append(String((o_v as Dictionary).get("ref", "")))
	assert_true(
		refs.has("B") and refs.has("C"), "без amount — куда угодно, кроме себя: %s" % str(refs)
	)
	assert_false(bool(enc.get("committed", false)), "ход замер до решения")
	assert_eq(String(ef._gs.players["p"]["location"]), "A", "до решения сыщик на месте")
	# Выбор C
	var idx: int = refs.find("C")
	assert_true(ef.record_effect_choice("p", idx), "выбор записан")
	ef._commit_outcome("p")
	assert_true(bool(ef._gs.current_encounter.get("committed", false)), "коммит доигран")
	assert_eq(String(ef._gs.players["p"]["location"]), "C", "сыщик перемещён")
	assert_eq(int(ef._gs.players["p"]["clues"]), 1, "остальные эффекты ветки применились")


func test_encounter_move_then_close_gate_closes_origin() -> void:
	var ef: EncounterFlow = _move_ctx()
	ef._gs.current_encounter["onSuccess"] = [{"do": "move"}, {"do": "closeGate"}]
	ef._commit_outcome("p")
	var pending: Dictionary = ef._gs.current_encounter["pending_choice"]
	var idx: int = -1
	var opts: Array = pending["options"]
	for i in range(opts.size()):
		if String((opts[i] as Dictionary)["ref"]) == "C":
			idx = i
	ef.record_effect_choice("p", idx)
	ef._commit_outcome("p")
	var closed: Array = (ef._gs as MockGS).board_effects
	assert_eq(closed.size(), 1, "один board-эффект (closeGate)")
	assert_eq(String((closed[0] as Dictionary)["do"]), "closeGate")
	assert_eq(
		String((closed[0] as Dictionary)["_origin_loc"]), "A", "врата закрываются на исходной A"
	)
	assert_eq(String(ef._gs.players["p"]["location"]), "C", "а сыщик уже в C")


# ── Встреча без проверки: кубов нет, эффекты успеха применяются по «Завершить» ──


func test_test_less_encounter_skips_check_and_applies_success() -> void:
	var gs: MockGS = autofree(MockGS.new())
	gs.map = MockMap.new()
	gs.players["p"] = {"items": [], "location": "A", "resources": 0, "investigator": ""}
	gs.turn_order = ["p"]
	gs.current_encounter = {
		"kind": "general",
		"onSuccess": [{"do": "gainResource", "amount": 2}],
		"onFailure": [{"do": "loseHealth", "amount": 5}],
	}
	gs.active_check = {"owner": "encounter", "rolled": true, "passed": false}  # хвост прошлой
	var ef := EncounterFlow.new(gs)
	ef._start_check_for_encounter("p")
	var mc: MockCheck = gs._check
	assert_true(mc.cleared, "старая проверка снята")
	assert_eq(mc.started.size(), 0, "новая проверка не стартует — кубов нет")
	ef._commit_outcome("p")
	assert_true(bool(gs.current_encounter.get("committed", false)), "коммит прошёл")
	assert_eq(int(gs.players["p"]["resources"]), 2, "применена ветка успеха")


# ── untouchableWhile: Старшего нельзя атаковать, пока на поле культисты ───────


class MockGSElder:
	extends MockGS

	func monster_def(mid: String) -> Dictionary:
		if mid == "elder":
			return {"id": "elder", "toughness": 3, "untouchableWhile": {"monster": "cultist"}}
		return super(mid)


func test_untouchable_monster_is_skipped_while_guard_on_board() -> void:
	var gs: MockGSElder = autofree(MockGSElder.new())
	gs.players["p"] = {"location": "loc", "hp": 5, "sanity": 5, "items": []}
	gs.monsters = {"loc": [{"id": "elder", "health": 3}], "far": [{"id": "cultist", "health": 1}]}
	var ef := EncounterFlow.new(gs)
	assert_true(ef.combat.is_untouchable("elder"), "культист на поле → Старший неуязвим")
	assert_eq(ef.combat.unfought_indices("loc"), [], "в очередь боя не попадает")
	assert_eq(ef.combat.next_or_choice("p"), CombatFlow.NEXT_LOCKED, "клетка заперта, боя нет")
	gs.monsters.erase("far")
	assert_false(ef.combat.is_untouchable("elder"), "культистов нет → можно")
	assert_eq(ef.combat.unfought_indices("loc"), [0])


# ── Липкая особая встреча Тайны: повтор каждый ход, пока Тайна та же ───────────


func test_sticky_rearms_until_mystery_changes() -> void:
	var gs: MockGS = autofree(MockGS.new())
	gs.players["p"] = {"location": "loc", "hp": 5, "sanity": 5, "items": []}
	var ef := EncounterFlow.new(gs)
	ef.assign_sticky("p", {"kind": "general", "tag": "demo-final", "mystery_idx": 0})
	assert_eq(String(ef.debug_assigned("p").get("tag", "")), "demo-final", "назначена")
	ef._forced.erase("p")  # «сыграна» (generate снимает назначение)
	ef._rearm_sticky("p")
	assert_eq(
		String(ef.debug_assigned("p").get("tag", "")), "demo-final", "повтор на следующий ход"
	)
	gs.active_mystery = 1  # Тайна решена → следующая
	ef._forced.erase("p")
	ef._rearm_sticky("p")
	assert_true(ef.debug_assigned("p").is_empty(), "Тайна сменилась — повтора нет")
	ef.assign_sticky("p", {"kind": "general", "tag": "x", "mystery_idx": 1})
	ef.clear_sticky()
	assert_true(ef.debug_assigned("p").is_empty(), "clear_sticky снимает и несыгранное")


func test_investigator_flags() -> void:
	var gs: MockGS = autofree(MockGS.new())
	var ef := EncounterFlow.new(gs)
	assert_eq(ef._investigator_flags({"items": []}), [])
	var flags: Array = ef._investigator_flags(
		{"items": [{"id": "wither", "kind": "spell"}, {"id": "lantern", "exhausted": false}]}
	)
	assert_eq(flags, ["hasSpell"], "заклинание → hasSpell; обычный актив флага не даёт")


func test_branch_without_test_is_test_less_only_on_stage_two() -> void:
	var enc := {
		"kind": "gate",
		"stage": 0,
		"branch": "success",
		"stage1": {"test": {"skill": "will", "modifier": -1}},
		"branches":
		{
			"success": {"onSuccess": [{"do": "closeGate"}]},
			"failure": {"test": {"skill": "observation"}, "onSuccess": [], "onFailure": []},
		},
	}
	assert_false(EncounterFlow._is_test_less(enc), "первая проверка обязательна")
	enc["stage"] = 1
	assert_true(EncounterFlow._is_test_less(enc), "ветка успеха без проверки")
	enc["branch"] = "failure"
	assert_false(EncounterFlow._is_test_less(enc), "ветка провала с проверкой")
