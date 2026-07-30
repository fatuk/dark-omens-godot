extends GutTest

## Юнит-тесты движка спас-броска на Пороге (scripts/core/game/death_save_flow.gd).
##
## DeathSaveFlow работает поверх per-player слота players[pid].death_save_check и
## настоящего CheckFlow (fixed_pool=1), поэтому исход резолвим детерминированно,
## задавая кубы слота напрямую (сам бросок Dice.roll рандомен — для open проверяем
## лишь размер пула и факт броска, для apply — заранее заданный passed).

var _gs: MockGameState
var _ds: DeathSaveFlow


# Мок GameState: DeathSaveFlow/CheckFlow обращаются к players, _check, _sync, _name_of.
class MockGameState:
	extends Node
	var players: Dictionary = {}
	var active_check: Dictionary = {}
	var outcome: String = ""
	var _check: CheckFlow
	var _board: StubBoard
	var _ghost_caches: Dictionary = {}
	var sync_count: int = 0

	func _init() -> void:
		_check = CheckFlow.new(self)
		_board = StubBoard.new()

	func _stash_belongings(loc: String, items: Array) -> void:
		var cache: Array = _ghost_caches.get(loc, [])
		cache.append_array(items)
		_ghost_caches[loc] = cache

	func _name_of(pid: String) -> String:
		return pid

	func _broadcast_sync() -> void:
		sync_count += 1

	func _emit_changed() -> void:
		pass


# Заглушка BoardState: считает вызовы place_clue (для flush_ghost_clues).
class StubBoard:
	extends RefCounted
	var placed: int = 0

	func place_clue() -> void:
		placed += 1


func before_each() -> void:
	_gs = autofree(MockGameState.new())
	_ds = DeathSaveFlow.new(_gs)


func _player(extra: Dictionary = {}) -> void:
	var base: Dictionary = {
		"investigator": "", "skill_mods": {}, "resources": 0, "hp": 0, "sanity": 0
	}
	for k_v: Variant in extra:
		base[k_v] = extra[k_v]
	_gs.players["p"] = base


# Готовый «брошенный» слот спас-броска с заданным исходом (для apply / reroll).
func _save_slot(stat: String, passed: bool) -> void:
	var skill: String = "strength" if stat == "hp" else "will"
	var val: int = 6 if passed else 2  # порог по умолчанию 5
	var c: Dictionary = _gs._check.make_check("deathSave", "p", skill, 0, "deathSave")
	c["fixed_pool"] = 1
	c["death_stat"] = stat
	c["rolled"] = true
	c["base"] = [val]
	c["dice"] = [val]
	c["successes"] = 1 if passed else 0
	c["passed"] = passed
	_gs.players["p"][PlayerKeys.DEATH_SAVE_CHECK] = c


# ── open: создание слота, 1 кубик, порог шрама ────────────────────────────────


func test_open_creates_death_save_with_one_die() -> void:
	_player({"hp": 0})
	assert_eq(_ds.open("p", "hp"), "save")
	var c: Dictionary = _ds.slot("p")
	assert_false(c.is_empty(), "слот спас-броска создан")
	assert_true(bool(c["rolled"]), "кубик брошен")
	assert_eq((c["base"] as Array).size(), 1, "ровно 1 кубик (fixed_pool)")
	assert_eq(String(c["death_stat"]), "hp")
	assert_eq(String(c["skill"]), "strength", "по здоровью страдает Сила")
	assert_gt(_gs.sync_count, 0, "результат разослан")


func test_open_sanity_targets_will() -> void:
	_player({"sanity": 0})
	assert_eq(_ds.open("p", "sanity"), "save")
	assert_eq(String(_ds.slot("p")["skill"]), "will", "по рассудку страдает Воля")
	assert_eq(String(_ds.slot("p")["death_stat"]), "sanity")


func test_open_is_idempotent_while_save_pending() -> void:
	_player({"hp": 0})
	_ds.open("p", "hp")
	assert_eq(_ds.open("p", "hp"), "", "второй open при живом слоте — no-op")


func test_open_on_dead_player_noop() -> void:
	_player({"hp": 0, "dead": true})
	assert_eq(_ds.open("p", "hp"), "")
	assert_true(_ds.slot("p").is_empty(), "слот не создаётся мёртвому")


func test_open_at_scar_cap_is_immediate_death() -> void:
	_player({"hp": 0, "skill_mods": {"strength": -2}})
	assert_eq(_ds.open("p", "hp"), "death", "на −2 цепляться нельзя")
	assert_true(bool(_gs.players["p"]["dead"]))
	assert_true(_ds.slot("p").is_empty(), "слот не создаётся")


# ── apply: успех (выжил + шрам) / провал (смерть) ─────────────────────────────


func test_apply_survive_hp_sets_one_and_scars_strength() -> void:
	_player({"hp": 0})
	_save_slot("hp", true)
	assert_eq(_ds.apply("p"), "survive")
	var p: Dictionary = _gs.players["p"]
	assert_eq(int(p["hp"]), 1, "вырван с Порога на 1")
	assert_eq(int((p["skill_mods"] as Dictionary).get("strength", 0)), -1, "шрам −1 к Силе")
	assert_true(_ds.slot("p").is_empty(), "слот снят")
	assert_false(bool(p.get("dead", false)), "жив")


func test_apply_survive_sanity_scars_will() -> void:
	_player({"sanity": 0})
	_save_slot("sanity", true)
	assert_eq(_ds.apply("p"), "survive")
	assert_eq(int(_gs.players["p"]["sanity"]), 1)
	assert_eq(
		int((_gs.players["p"]["skill_mods"] as Dictionary).get("will", 0)), -1, "шрам −1 к Воле"
	)


func test_scar_accumulates_to_cap() -> void:
	_player({"hp": 0, "skill_mods": {"strength": -1}})
	_save_slot("hp", true)
	_ds.apply("p")
	assert_eq(
		int((_gs.players["p"]["skill_mods"] as Dictionary).get("strength", 0)), -2, "−1 → −2 (пол)"
	)


func test_apply_fail_is_death() -> void:
	_player({"hp": 0})
	_save_slot("hp", false)
	assert_eq(_ds.apply("p"), "death")
	assert_true(bool(_gs.players["p"]["dead"]))
	assert_true(_ds.slot("p").is_empty(), "слот снят")


func test_apply_without_slot_noop() -> void:
	_player()
	assert_eq(_ds.apply("p"), "", "нет слота — нечего применять")


# ── reroll_by_resource: сосед платит ресурсом ────────────────────────────────


func test_reroll_by_resource_spends_ally_resource() -> void:
	_player({"hp": 0})
	_save_slot("hp", false)  # провальный куб [2]
	_gs.players["ally"] = {"investigator": "", "resources": 1}
	assert_true(_ds.reroll_by_resource("ally", "p", 0))
	assert_eq(int(_gs.players["ally"]["resources"]), 0, "ресурс соседа списан")
	assert_eq(int(_ds.slot("p").get("reroll_nonce", 0)), 1, "куб переброшен (nonce)")


func test_reroll_by_resource_rejected_without_resource() -> void:
	_player({"hp": 0})
	_save_slot("hp", false)
	_gs.players["ally"] = {"investigator": "", "resources": 0}
	assert_false(_ds.reroll_by_resource("ally", "p", 0), "у соседа нет ресурса")


func test_reroll_by_resource_rejected_on_success_die() -> void:
	_player({"hp": 0})
	_save_slot("hp", true)  # куб [6] — успех
	_gs.players["ally"] = {"investigator": "", "resources": 1}
	assert_false(_ds.reroll_by_resource("ally", "p", 0), "успешный куб не перебрасывается")
	assert_eq(int(_gs.players["ally"]["resources"]), 1, "ресурс не тронут")


# ── sweep: централизованный триггер по 0 HP/SAN ───────────────────────────────


func test_sweep_opens_hp_save_at_zero_hp() -> void:
	_player({"hp": 0, "sanity": 5})
	assert_eq(_ds.sweep(), 1)
	assert_eq(String(_ds.slot("p")["death_stat"]), "hp")


func test_sweep_opens_sanity_save_at_zero_sanity() -> void:
	_player({"hp": 5, "sanity": 0})
	assert_eq(_ds.sweep(), 1)
	assert_eq(String(_ds.slot("p")["death_stat"]), "sanity")


func test_sweep_prioritizes_hp_when_both_zero() -> void:
	_player({"hp": 0, "sanity": 0})
	_ds.sweep()
	assert_eq(String(_ds.slot("p")["death_stat"]), "hp", "при обоих 0 — сперва Сила-Порог")


func test_sweep_skips_healthy_dead_and_pending() -> void:
	_gs.players["healthy"] = {"investigator": "", "skill_mods": {}, "hp": 5, "sanity": 5}
	_gs.players["gone"] = {"investigator": "", "skill_mods": {}, "hp": 0, "sanity": 0, "dead": true}
	_player({"hp": 0})
	_ds.open("p", "hp")  # уже в спасе
	assert_eq(_ds.sweep(), 0, "здоровый / мёртвый / уже-в-спасе пропущены")


func test_sweep_immediate_death_at_scar_cap() -> void:
	_player({"hp": 0, "skill_mods": {"strength": -2}})
	assert_eq(_ds.sweep(), 1, "мгновенная смерть тоже обработана")
	assert_true(bool(_gs.players["p"]["dead"]))


func test_sweep_counts_multiple_players() -> void:
	_gs.players["a"] = {"investigator": "", "skill_mods": {}, "hp": 0, "sanity": 5}
	_gs.players["b"] = {"investigator": "", "skill_mods": {}, "hp": 5, "sanity": 0}
	assert_eq(_ds.sweep(), 2)


# ── grace: добор урона того же события впитывается ─────────────────────────────


func test_survive_sets_death_grace() -> void:
	_player({"hp": 0})
	_save_slot("hp", true)
	_ds.apply("p")
	assert_true(bool(_gs.players["p"].get("death_grace", false)), "выживший получает иммунитет")


func test_sweep_skips_player_in_grace() -> void:
	# Выжил (grace) и тот же мифос снова уронил hp в 0 → новый Порог НЕ открывается.
	_player({"hp": 0, "death_grace": true})
	assert_eq(_ds.sweep(), 0, "добор урона в grace впитан")
	assert_true(_ds.slot("p").is_empty())


func test_clear_grace_reenables_save() -> void:
	_player({"hp": 0, "death_grace": true})
	assert_eq(_ds.sweep(), 0)
	_ds.clear_grace()  # новый раунд
	assert_false(bool(_gs.players["p"].get("death_grace", false)), "grace снят")
	assert_eq(_ds.sweep(), 1, "повторный урон в новом раунде — снова Порог")


# ── поражение: не осталось живых сыщиков ──────────────────────────────────────


func test_death_of_last_investigator_is_defeat() -> void:
	_player({"hp": 0})
	_save_slot("hp", false)
	_ds.apply("p")  # провал → смерть; единственный сыщик → поражение
	assert_eq(_gs.outcome, "defeat")


func test_death_not_defeat_while_someone_alive() -> void:
	_player({"hp": 0})
	_save_slot("hp", false)
	_gs.players["ally"] = {"investigator": "", "skill_mods": {}, "hp": 6, "sanity": 6}
	_ds.apply("p")  # p погиб, ally жив → не поражение
	assert_eq(_gs.outcome, "", "жив хотя бы один сыщик — не поражение")


# ── смерть → состояние Тени (бюджет, сброс вещей) ─────────────────────────────


func test_death_sets_ghost_budget_to_living_count() -> void:
	_player({"hp": 0})
	_save_slot("hp", false)
	_gs.players["a"] = {"investigator": "", "skill_mods": {}, "hp": 6, "sanity": 6}
	_gs.players["b"] = {"investigator": "", "skill_mods": {}, "hp": 6, "sanity": 6}
	_ds.apply("p")  # p погиб; живы a и b → бюджет 2
	assert_eq(int(_gs.players["p"]["ghost_clue_budget"]), 2)
	assert_false(bool(_gs.players["p"]["ghost_acted_this_round"]), "акт доступен сразу")


func test_death_drops_items_to_cache_and_clears() -> void:
	_player({"hp": 0, "location": "arkham", "items": [{"id": "axe"}], "clues": 3})
	_save_slot("hp", false)
	_gs.players["ally"] = {"investigator": "", "skill_mods": {}, "hp": 6, "sanity": 6}
	_ds.apply("p")
	assert_eq((_gs._ghost_caches.get("arkham", []) as Array).size(), 1, "вещи в кэше локации")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "у Тени вещей нет")
	assert_eq(int(_gs.players["p"]["clues"]), 0, "улики обнулены (вернутся в пул)")


# ── Тень выкладывает улику (акт раунда) ───────────────────────────────────────


func _ghost(extra: Dictionary = {}) -> void:
	var base: Dictionary = {"dead": true, "ghost_clue_budget": 2, "ghost_acted_this_round": false}
	for k_v: Variant in extra:
		base[k_v] = extra[k_v]
	_gs.players["g"] = base


func test_ghost_place_clue_queues_and_spends_budget() -> void:
	_ghost()
	assert_true(_ds.ghost_place_clue("g"))
	assert_true(bool(_gs.players["g"]["ghost_acted_this_round"]), "акт израсходован в раунде")
	assert_eq(int(_gs.players["g"]["ghost_clue_budget"]), 1, "бюджет −1")


func test_ghost_place_clue_rejected_when_acted() -> void:
	_ghost({"ghost_acted_this_round": true})
	assert_false(_ds.ghost_place_clue("g"), "в этом раунде уже действовал")


func test_ghost_place_clue_rejected_without_budget() -> void:
	_ghost({"ghost_clue_budget": 0})
	assert_false(_ds.ghost_place_clue("g"), "бюджет улик исчерпан")


func test_ghost_place_clue_rejected_for_living() -> void:
	_gs.players["alive"] = {"dead": false, "ghost_clue_budget": 2, "ghost_acted_this_round": false}
	assert_false(_ds.ghost_place_clue("alive"), "живой не Тень")


func test_flush_ghost_clues_places_all_pending() -> void:
	_ghost({"ghost_clue_budget": 3})
	_ds.ghost_place_clue("g")
	_gs.players["g"]["ghost_acted_this_round"] = false  # эмулируем новый раунд
	_ds.ghost_place_clue("g")
	_ds.flush_ghost_clues()
	assert_eq(_gs._board.placed, 2, "обе отложенные улики выложены на доску")
