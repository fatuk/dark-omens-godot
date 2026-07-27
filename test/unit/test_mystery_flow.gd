extends GutTest

## Юнит-тесты цикла Тайн (scripts/core/game/mystery_flow.gd): зачёт/решение/финал,
## data-хуки набора жетонов (реакции и встречи), оплата cost, onEnter, поражение.
## Детерминировано (без ГСЧ). Источник данных Тайны — стаб _campaign.current_mystery();
## board-эффекты пишутся в рекордер _gs.board_effects.

var _gs: MockGameState
var _m: MysteryFlow


class StubCampaign:
	extends RefCounted
	var mystery: Dictionary = {}

	func current_mystery() -> Dictionary:
		return mystery


class StubBoard:
	extends RefCounted
	var omen: String = "green"
	var gs: Node  # ссылка на MockGameState ради доступа к entities

	func current_omen_color() -> String:
		return omen

	func clear_eldritch_tokens() -> int:
		var removed: int = 0
		for lid: String in gs.entities.keys():
			var arr: Array = gs.entities[lid]
			if (arr as Array).has("eldritch_token"):
				arr.erase("eldritch_token")
				removed += 1
				gs.entities[lid] = arr
		return removed


class MockGameState:
	extends Node
	var host: bool = true
	var players: Dictionary = {}
	var turn_order: Array = []
	var current_idx: int = 0
	var entities: Dictionary = {}
	var campaign: Dictionary = {}
	var doom: int = 0
	var active_mystery: int = 0
	var mystery_progress: int = 0
	var mystery_claimed: Array = []
	var mystery_tokens_on_card: int = 0
	var _on_enter_applied_idx: int = -1
	var outcome: String = ""
	var board_effects: Array = []
	var _campaign: StubCampaign
	var _board: StubBoard

	func _init() -> void:
		_campaign = StubCampaign.new()
		_board = StubBoard.new()
		_board.gs = self

	func _is_host() -> bool:
		return host

	func _current_pid() -> String:
		return String(turn_order[current_idx]) if current_idx < turn_order.size() else ""

	func _name_of(pid: String) -> String:
		return pid

	func _apply_board_effect(node: Dictionary) -> void:
		board_effects.append(node)


func before_each() -> void:
	_gs = autofree(MockGameState.new())
	_m = MysteryFlow.new(_gs)


func _mystery(data: Dictionary) -> void:
	_gs._campaign.mystery = data


func _at(loc: String) -> void:
	_gs.turn_order = ["p"]
	_gs.current_idx = 0
	_gs.players["p"] = {"location": loc, "clues": 0}


# ── mystery_kind ──────────────────────────────────────────────────────────────


func test_mystery_kind_from_solve_condition() -> void:
	_mystery({"solveCondition": {"kind": "tokensOnCard"}})
	assert_eq(_m.mystery_kind(), "tokensOnCard")


func test_mystery_kind_empty_without_campaign() -> void:
	assert_eq(_m.mystery_kind(), "", "нет кампании → пустой kind")


# ── Зачёт прогресса / решение ─────────────────────────────────────────────────


func test_progress_increments_until_target() -> void:
	_mystery({"solveCondition": {"n": 2}, "mysteries": []})
	_gs.campaign = {"mysteries": [{}, {}]}
	_at("locA")
	_m.apply_mystery_progress()
	assert_eq(_gs.mystery_progress, 1, "первый зачёт")
	assert_eq(_gs.active_mystery, 0, "ещё не решена")


func test_progress_solves_at_target_and_advances() -> void:
	_mystery({"solveCondition": {"n": 2}})
	_gs.campaign = {"mysteries": [{}, {}]}
	_at("locA")
	_m.apply_mystery_progress()
	_gs.players["p"]["location"] = "locB"  # другая локация — второй зачёт
	_m.apply_mystery_progress()
	assert_eq(_gs.active_mystery, 1, "Тайна решена → следующий акт")
	assert_eq(_gs.mystery_progress, 0, "прогресс сброшен")
	assert_eq((_gs.mystery_claimed as Array).size(), 0, "зачтённые сброшены")


func test_progress_same_location_not_double_counted() -> void:
	_mystery({"solveCondition": {"n": 5}})
	_at("locA")
	_m.apply_mystery_progress()
	_m.apply_mystery_progress()  # та же локация
	assert_eq(_gs.mystery_progress, 1, "повторный зачёт той же локации игнорируется")


func test_progress_noop_without_active_player() -> void:
	_mystery({"solveCondition": {"n": 1}})
	_m.apply_mystery_progress()  # нет turn_order
	assert_eq(_gs.mystery_progress, 0)


func test_solving_last_mystery_is_victory() -> void:
	_mystery({"solveCondition": {"n": 1}})
	_gs.campaign = {"mysteries": [{}]}  # единственная Тайна
	_at("locA")
	_m.apply_mystery_progress()
	assert_eq(_gs.outcome, "victory", "решена последняя Тайна → победа")


# ── Хуки: нормализация / поиск ────────────────────────────────────────────────


func test_progress_hooks_array_format() -> void:
	_mystery({"progress": [{"on": "a"}, {"on": "b"}]})
	assert_eq(_m.mystery_progress_hooks().size(), 2)


func test_progress_hooks_legacy_single() -> void:
	_mystery({"progressHook": {"on": "x"}})
	assert_eq(
		_m.mystery_progress_hooks().size(), 1, "одиночный progressHook нормализуется в массив"
	)


func test_progress_hooks_none() -> void:
	_mystery({})
	assert_eq(_m.mystery_progress_hooks().size(), 0)


func test_hook_for_requires_tokens_on_card() -> void:
	_mystery({"solveCondition": {"kind": "monsterDefeated"}, "progress": [{"on": "gateClosed"}]})
	assert_true(_m.mystery_hook_for("gateClosed").is_empty(), "хуки только для tokensOnCard")


func test_hook_for_matches_event() -> void:
	_mystery(
		{
			"solveCondition": {"kind": "tokensOnCard"},
			"progress": [{"on": "monsterDefeated"}, {"on": "gateClosed", "effect": []}],
		}
	)
	var h: Dictionary = _m.mystery_hook_for("gateClosed")
	assert_eq(String(h.get("on", "")), "gateClosed")


func test_hook_for_omen_match_gate() -> void:
	_mystery(
		{
			"solveCondition": {"kind": "tokensOnCard"},
			"progress": [{"on": "gateClosed", "when": {"omenMatch": true}}],
		}
	)
	_gs._board.omen = "green"
	assert_false(_m.mystery_hook_for("gateClosed", {"color": "green"}).is_empty(), "цвет совпал")
	assert_true(_m.mystery_hook_for("gateClosed", {"color": "red"}).is_empty(), "цвет не совпал")


# ── Встречи-хуки ──────────────────────────────────────────────────────────────


func test_encounter_hook_at_eldritch_token() -> void:
	_mystery(
		{
			"solveCondition": {"kind": "tokensOnCard"},
			"progress": [{"on": "encounterAtEldritchToken"}]
		}
	)
	_gs.entities = {"locA": ["eldritch_token"]}
	assert_false(_m.mystery_encounter_hook("locA", "p").is_empty(), "хук на клетке с жетоном")


func test_encounter_hook_at_marked_location() -> void:
	# Помеченная локация = тот же жетон Знамения: encounterAtEldritchToken срабатывает
	# и на ней (без entity-жетона на клетке).
	_mystery(
		{
			"solveCondition": {"kind": "tokensOnCard"},
			"locations": ["locM"],
			"progress": [{"on": "encounterAtEldritchToken"}],
		}
	)
	assert_false(_m.mystery_encounter_hook("locM", "p").is_empty(), "хук на помеченной локации")


func test_encounter_hook_none_on_plain_location() -> void:
	_mystery(
		{
			"solveCondition": {"kind": "tokensOnCard"},
			"progress": [{"on": "encounterAtEldritchToken"}]
		}
	)
	assert_true(_m.mystery_encounter_hook("plain", "p").is_empty())


func test_encounter_hook_skips_claimed_marked_location() -> void:
	# Снятую (mystery_claimed) помеченную локацию — метка ушла на карту — встреча
	# больше не предлагает (иначе можно было бы фармить одну клетку).
	_mystery(
		{
			"solveCondition": {"kind": "tokensOnCard"},
			"locations": ["locM"],
			"progress": [{"on": "encounterAtEldritchToken"}],
		}
	)
	_gs.mystery_claimed = ["locM"]
	assert_true(_m.mystery_encounter_hook("locM", "p").is_empty(), "снятая метка — встречи нет")


# ── Оплата / применение ───────────────────────────────────────────────────────


func test_can_pay_without_cost() -> void:
	assert_true(_m.mystery_can_pay({}, "p"), "без cost — всегда можно")


func test_can_pay_checks_resource() -> void:
	_at("locA")
	_gs.players["p"]["clues"] = 1
	var hook: Dictionary = {"cost": {"spend": "clue", "amount": 2}}
	assert_false(_m.mystery_can_pay(hook, "p"), "улик не хватает")
	_gs.players["p"]["clues"] = 2
	assert_true(_m.mystery_can_pay(hook, "p"))


func test_apply_hook_spends_and_applies_effect() -> void:
	_at("locA")
	_gs.players["p"]["clues"] = 2
	var hook: Dictionary = {
		"cost": {"spend": "clue", "amount": 1},
		"effect": [{"do": "placeEldritchToken", "where": "self"}],
	}
	assert_true(_m.mystery_apply_hook(hook, "p"))
	assert_eq(int(_gs.players["p"]["clues"]), 1, "списана улика")
	assert_eq(_gs.board_effects.size(), 1, "effect применён на доску")


func test_apply_hook_non_host_rejected() -> void:
	_gs.host = false
	assert_false(_m.mystery_apply_hook({"effect": []}, "p"))


func test_try_mystery_hook_applies_reaction() -> void:
	_mystery(
		{
			"solveCondition": {"kind": "tokensOnCard"},
			"progress":
			[{"on": "gateClosed", "effect": [{"do": "placeEldritchToken", "where": "self"}]}],
		}
	)
	_at("locA")
	_m.try_mystery_hook("gateClosed", {}, "p")
	assert_eq(_gs.board_effects.size(), 1, "реакция-хук применил effect")


# ── Решение по жетонам / onEnter / поражение ──────────────────────────────────


func test_check_tokens_solve_at_target() -> void:
	_mystery({"solveCondition": {"kind": "tokensOnCard", "n": 2}})
	_gs.campaign = {"mysteries": [{}, {}]}
	_gs.mystery_tokens_on_card = 2
	_m.check_mystery_tokens_solve()
	assert_eq(_gs.active_mystery, 1, "набрано жетонов → Тайна решена")
	assert_eq(_gs.mystery_tokens_on_card, 0, "счётчик сброшен")


func test_solve_clears_eldritch_tokens_from_board() -> void:
	_mystery({"solveCondition": {"kind": "tokensOnCard", "n": 1}})
	_gs.campaign = {"mysteries": [{}, {}]}
	_gs.entities = {"loc_a": ["eldritch_token"], "loc_b": ["clue", "eldritch_token"]}
	_gs.mystery_tokens_on_card = 1
	_m.check_mystery_tokens_solve()
	assert_eq(_gs.active_mystery, 1, "Тайна решена")
	assert_false(
		(_gs.entities.get("loc_a", []) as Array).has("eldritch_token"), "жетон снят с loc_a"
	)
	assert_false(
		(_gs.entities.get("loc_b", []) as Array).has("eldritch_token"), "жетон снят с loc_b"
	)
	assert_true((_gs.entities.get("loc_b", []) as Array).has("clue"), "прочие сущности целы")


func test_check_tokens_solve_non_host_noop() -> void:
	_gs.host = false
	_mystery({"solveCondition": {"kind": "tokensOnCard", "n": 1}})
	_gs.mystery_tokens_on_card = 5
	_m.check_mystery_tokens_solve()
	assert_eq(_gs.active_mystery, 0, "не-хост не решает")


func test_apply_on_enter_runs_once() -> void:
	_mystery({"onEnter": [{"do": "placeEldritchToken"}]})
	_m.apply_mystery_on_enter()
	assert_eq(_gs.board_effects.size(), 1, "onEnter применён")
	_m.apply_mystery_on_enter()  # повторно
	assert_eq(_gs.board_effects.size(), 1, "идемпотентно — второй раз не применяется")


func test_check_defeat_at_doom_clock() -> void:
	_gs.campaign = {"doomClock": 10}
	_gs.doom = 10
	_m.check_defeat()
	assert_eq(_gs.outcome, "defeat", "doom достиг clock → поражение")


func test_check_defeat_below_clock() -> void:
	_gs.campaign = {"doomClock": 10}
	_gs.doom = 9
	_m.check_defeat()
	assert_eq(_gs.outcome, "", "doom ниже clock → партия продолжается")


func test_check_defeat_clamps_overshoot() -> void:
	# Дум перешагнул doomClock (напр. дум от омена сразу +3) — поражение + кламп к clock.
	_gs.campaign = {"doomClock": 15}
	_gs.doom = 18
	_gs.outcome = ""
	_m.check_defeat()
	assert_eq(_gs.outcome, "defeat", "перешаг тоже даёт поражение")
	assert_eq(_gs.doom, 15, "дум склампен к doomClock — трек не переполняется")


func test_check_defeat_idempotent_reclamps() -> void:
	_gs.campaign = {"doomClock": 15}
	_gs.doom = 20
	_gs.outcome = ""
	_m.check_defeat()
	assert_eq(_gs.doom, 15)
	_gs.doom = 17  # ещё прибавка после поражения (напр. следующий шаг омена)
	_m.check_defeat()
	assert_eq(_gs.doom, 15, "повторный вызов снова клампит")


func test_check_defeat_noop_without_clock() -> void:
	_gs.campaign = {}  # нет doomClock (0)
	_gs.doom = 99
	_gs.outcome = ""
	_m.check_defeat()
	assert_eq(_gs.outcome, "", "без doomClock проверка не срабатывает")
	assert_eq(_gs.doom, 99, "дум не клампится без clock")
