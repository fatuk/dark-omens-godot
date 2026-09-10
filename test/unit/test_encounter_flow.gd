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


class MockRumor:
	extends RefCounted

	func notify_monster_defeated(_loc: String) -> void:
		pass


class MockGS:
	extends Node
	var phase: String = "encounter"
	var players: Dictionary = {}
	var current_encounter: Dictionary = {}
	var encounter_discard: Array = []
	var encounter_choices: Array = []
	var monsters: Dictionary = {}
	var entities: Dictionary = {}
	var gates: Dictionary = {}
	var campaign: Dictionary = {}
	var active_check: Dictionary = {}
	var _check := MockCheck.new()
	var _campaign := MockCampaign.new()
	var _board := MockBoard.new()
	var _rumor := MockRumor.new()

	func _is_host() -> bool:
		return true

	var current_pid: String = "p"

	func _current_pid() -> String:
		return current_pid

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
	ef._commit_combat("p")
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
	ef._commit_combat("p")
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
	ef._commit_combat("p")
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
	ef._commit_combat("p")
	var inst: Variant = ef._gs.monsters["loc"][0]
	assert_true(inst is Dictionary, "нормализован в словарь")
	assert_true(bool((inst as Dictionary).get("fought", false)))
	assert_eq(ef._unfought_indices("loc"), [1], "второй ещё не бит")


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
	ef._commit_combat("p")
	assert_false(ef.continue_encounter_turn("p"), "ход первого завершён")
	# Ход второго: пометка первого ему не мешает, а гуль встречает его раненым.
	ef._gs.current_pid = "q"
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
	ef._commit_combat("p")
	assert_true(ef.continue_encounter_turn("p"), "у первого остался гуль")
	# Первому — гуль; сдадимся ему и завершим ход.
	ef._gs.current_encounter["resolution"] = {"won": false, "hp_loss": 1, "health_after": 1}
	ef._commit_combat("p")
	assert_false(ef.continue_encounter_turn("p"))
	# Второму достаётся только гуль: выбора нет, бой сразу, культиста уже нет.
	ef._gs.current_pid = "q"
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
	ef._gs.current_encounter["resolution"] = {"won": false, "hp_loss": hp_loss, "health_after": 3}
	ef._gs.current_encounter["sanity_loss"] = sanity_loss
	return ef


func test_bandages_prevent_own_damage() -> void:
	var ef: EncounterFlow = _wounded([{"id": "bandages", "exhausted": false}], [], 3)
	assert_true(ef.play_prevent_loss("p", 0), "бинты сыграны")
	assert_eq(int(ef._gs.current_encounter.get("prevented_hp", 0)), 2, "предотвращено 2 из 3")
	assert_true((ef._gs.players["p"]["items"] as Array).is_empty(), "бинты сброшены")
	ef._commit_combat("p")
	assert_eq(int(ef._gs.players["p"]["hp"]), 4, "списана только оставшаяся 1")


func test_neighbour_bandages_prevent_damage_in_others_turn() -> void:
	# Ход p, бинты у q на той же клетке — q играет их со своего экрана.
	var ef: EncounterFlow = _wounded([], [{"id": "bandages", "exhausted": false}], 2)
	assert_true(ef.play_prevent_loss("q", 0), "сосед прикрыл")
	assert_true((ef._gs.players["q"]["items"] as Array).is_empty(), "бинты соседа сброшены")
	ef._commit_combat("p")
	assert_eq(int(ef._gs.players["p"]["hp"]), 5, "раненый не потерял ничего")


func test_prevent_loss_rejected_from_another_location() -> void:
	var ef: EncounterFlow = _wounded([], [{"id": "bandages", "exhausted": false}], 2)
	ef._gs.players["q"]["location"] = "far"
	assert_false(ef.play_prevent_loss("q", 0), "с другой клетки не дотянуться")
	assert_eq((ef._gs.players["q"]["items"] as Array).size(), 1, "карта цела")


func test_prevent_loss_rejected_before_roll_and_when_nothing_left() -> void:
	var ef: EncounterFlow = _wounded([{"id": "bandages", "exhausted": false}], [], 0)
	assert_false(ef.play_prevent_loss("p", 0), "терять нечего — карту не жжём")
	ef._gs.current_encounter.erase("resolution")
	assert_false(ef.play_prevent_loss("p", 0), "до броска потеря неизвестна")


func test_prevent_loss_does_not_overprevent_across_cards() -> void:
	# Две пары бинтов на потерю 3: первая снимает 2, вторая — только оставшуюся 1.
	var ef: EncounterFlow = _wounded(
		[{"id": "bandages", "exhausted": false}, {"id": "bandages", "exhausted": false}], [], 3
	)
	assert_true(ef.play_prevent_loss("p", 0))
	assert_true(ef.play_prevent_loss("p", 0), "вторая (сдвинулась на индекс 0)")
	assert_eq(int(ef._gs.current_encounter.get("prevented_hp", 0)), 3, "ровно потеря, не больше")
	ef._commit_combat("p")
	assert_eq(int(ef._gs.players["p"]["hp"]), 5)


func test_whiskey_prevents_sanity_loss() -> void:
	var ef: EncounterFlow = _wounded([{"id": "whiskey", "exhausted": false}], [], 0, 2)
	assert_true(ef.play_prevent_loss("p", 0), "виски — по рассудку")
	ef._commit_combat("p")
	assert_eq(int(ef._gs.players["p"]["sanity"]), 5, "рассудок цел")


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
