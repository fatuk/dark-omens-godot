extends GutTest

## Юнит-тесты цикла фаз и шлюза действий (scripts/core/game/phase_controller.gd).
## Хост-only. PhaseController пишет напрямую в поля GameState и зовёт подмодули
## (_cond/_check/_encounter/_mythos), поэтому мок крупнее — но действия проверяются
## изолированно: даём 2 действия в запасе, чтобы применение одного не каскадировало
## в смену фазы (advance_action_turn), а handoff/переходы тестируем отдельно.

var _gs: MockGameState
var _pc: PhaseController


# Стабы подмодулей — возвращают настраиваемые значения, считают вызовы.
class StubCond:
	extends RefCounted
	var cannot: Dictionary = {}  # verb → bool (player_has_constraint)
	var constraints: Dictionary = {}  # player_constraints return
	var triggered: Array = []  # fire_triggered return
	var action_ok: bool = true  # host_run_condition_action return
	var granted: Array = []

	func player_has_constraint(_pid: String, verb: String) -> bool:
		return bool(cannot.get(verb, false))

	func player_constraints(_pid: String) -> Dictionary:
		return constraints

	func fire_triggered(_pid: String, _event: String) -> Array:
		return triggered

	func host_run_condition_action(_pid: String, _cid: String) -> bool:
		return action_ok

	func host_grant_asset(_pid: String, aid: String) -> void:
		granted.append(aid)


class StubCheck:
	extends RefCounted
	var started: Array = []
	var rolled: Array = []

	func start(owner: String, _pid: String, _skill: String, _mod: int, _ctx: String) -> void:
		started.append(owner)

	func roll(pid: String) -> bool:
		rolled.append(pid)
		return true

	func clear() -> void:
		pass


class StubFlow:
	extends RefCounted
	var entered: int = 0

	func enter_phase() -> void:
		entered += 1

	func begin_turn() -> void:
		pass


class StubSpell:
	extends RefCounted
	var ok: bool = true
	var cast_calls: Array = []
	var prompt_events: Array = []
	var prompt_returns: bool = false
	var resolved: Array = []

	func cast_ritual(_pid: String, idx: int) -> bool:
		cast_calls.append(idx)
		return ok

	func prompt_trigger(_pid: String, event: String) -> bool:
		prompt_events.append(event)
		return prompt_returns

	func host_apply_trigger_spells(_pid: String, indices: Array, _flow: Dictionary = {}) -> bool:
		resolved.append(indices)
		return true


class MockGameState:
	extends Node
	signal phase_changed(phase: String)
	const ACTIONS_PER_ROUND := 2
	var phase: String = "action"
	var players: Dictionary = {}
	var turn_order: Array = []
	var current_idx: int = 0
	var round_num: int = 1
	var active_check: Dictionary = {}
	var current_encounter: Dictionary = {}
	var pending_spell_cast: Dictionary = {}
	var locations: Array = []
	var loc_types: Dictionary = {}
	var sync_count: int = 0
	var _cond: StubCond
	var _check: StubCheck
	var _mythos: StubFlow
	var _encounter: StubFlow
	var _spell: StubSpell

	func _init() -> void:
		_cond = StubCond.new()
		_check = StubCheck.new()
		_mythos = StubFlow.new()
		_encounter = StubFlow.new()
		_spell = StubSpell.new()

	func _current_pid() -> String:
		return String(turn_order[current_idx]) if current_idx < turn_order.size() else ""

	func _name_of(pid: String) -> String:
		return pid

	func location_type(loc: String) -> String:
		return String(loc_types.get(loc, ""))

	func _load_locations() -> Array:
		return locations

	func available_ticket_types(loc_id: String) -> Array:
		if String(loc_types.get(loc_id, "")) != "city":
			return []
		var types: Array = []
		for loc in locations:
			if String((loc as Dictionary).get("id", "")) != loc_id:
				continue
			for c in (loc as Dictionary).get("connections", []):
				var t: String = String((c as Dictionary).get("type", ""))
				if (t == "train" or t == "ship") and not types.has(t):
					types.append(t)
			break
		return types

	func _refill_shop_reserve(_a: Array) -> void:
		pass

	func _refresh_items(_p: Dictionary) -> void:
		pass

	func _broadcast_sync() -> void:
		sync_count += 1

	func _emit_changed() -> void:
		pass


func before_each() -> void:
	_gs = autofree(MockGameState.new())
	_pc = PhaseController.new(_gs)


func _add_player(pid: String, extra: Dictionary = {}) -> void:
	var base: Dictionary = {
		"actions_left": 2,
		"actions_used": [],
		"tickets": 0,
		"concentration": 0,
		"hp": 3,
		"hp_max": 7,
		"sanity": 3,
		"sanity_max": 6,
		"location": "",
		"conditions": [],
		"connected": true,
	}
	for k_v: Variant in extra:
		base[k_v] = extra[k_v]
	_gs.players[pid] = base


# Один игрок «p» в свой ход в фазе action.
func _solo(extra: Dictionary = {}) -> void:
	_gs.turn_order = ["p"]
	_gs.current_idx = 0
	_add_player("p", extra)


# ── host_apply_action: гварды ─────────────────────────────────────────────────


func test_action_rejected_outside_action_phase() -> void:
	_solo()
	_gs.phase = "encounter"
	assert_false(_pc.host_apply_action("p", "buy_ticket"))


func test_action_rejected_out_of_turn() -> void:
	_gs.turn_order = ["p", "p2"]
	_gs.current_idx = 0  # ход p
	_add_player("p")
	_add_player("p2")
	assert_false(_pc.host_apply_action("p2", "buy_ticket"), "p2 ходит вне очереди")


func test_action_rejected_without_actions_left() -> void:
	_solo({"actions_left": 0})
	assert_false(_pc.host_apply_action("p", "buy_ticket"))


func test_action_cannot_act_blocks_regular_action() -> void:
	_solo()
	_gs._cond.cannot = {"cannotAct": true}
	assert_false(_pc.host_apply_action("p", "buy_ticket"), "whileHeld cannotAct запрещает действие")


func test_action_cannot_act_allows_pass() -> void:
	_gs.turn_order = ["p", "p2"]
	_add_player("p")
	_add_player("p2")
	_gs._cond.cannot = {"cannotAct": true}
	assert_true(_pc.host_apply_action("p", "pass"), "pass разрешён даже при cannotAct")


func test_action_repeat_rejected() -> void:
	_solo({"actions_used": ["buy_ticket"]})
	assert_false(_pc.host_apply_action("p", "buy_ticket"), "повтор действия в раунде запрещён")


# ── host_apply_action: эффекты действий ───────────────────────────────────────


func test_buy_ticket_grants_ticket_and_spends_action() -> void:
	# Город с морской дорогой → можно купить билет на корабль.
	_gs.loc_types["c1"] = "city"
	_gs.locations = [{"id": "c1", "connections": [{"to": "x", "type": "ship"}]}]
	_solo({"location": "c1"})
	assert_true(_pc.host_apply_action("p", "buy_ticket", {"type": "ship"}))
	assert_eq(int(_gs.players["p"].get("ship_tickets", 0)), 1)
	assert_eq(int(_gs.players["p"].get("train_tickets", 0)), 0, "куплен только морской")
	assert_eq(int(_gs.players["p"]["actions_left"]), 1, "действие потрачено")
	assert_true((_gs.players["p"]["actions_used"] as Array).has("buy_ticket"))


func test_buy_ticket_rejected_when_type_not_available() -> void:
	# Город только с морской дорогой → ж/д билет купить нельзя.
	_gs.loc_types["c1"] = "city"
	_gs.locations = [{"id": "c1", "connections": [{"to": "x", "type": "ship"}]}]
	_solo({"location": "c1"})
	assert_false(_pc.host_apply_action("p", "buy_ticket", {"type": "train"}))
	assert_eq(int(_gs.players["p"]["actions_left"]), 2, "действие не потрачено")


func test_buy_ticket_rejected_outside_city() -> void:
	_gs.loc_types["s1"] = "sea"
	_gs.locations = [{"id": "s1", "connections": [{"to": "x", "type": "ship"}]}]
	_solo({"location": "s1"})
	assert_false(_pc.host_apply_action("p", "buy_ticket", {"type": "ship"}))


func test_take_concentration_increments() -> void:
	_solo()
	assert_true(_pc.host_apply_action("p", "take_concentration"))
	assert_eq(int(_gs.players["p"]["concentration"]), 1)


func test_rest_heals_hp_and_sanity() -> void:
	_solo()
	_pc.host_apply_action("p", "rest")
	assert_eq(int(_gs.players["p"]["hp"]), 4, "+1 здоровья")
	assert_eq(int(_gs.players["p"]["sanity"]), 4, "+1 рассудка")


func test_rest_respects_cannot_recover_health() -> void:
	_solo()
	_gs._cond.constraints = {"cannotRecover": ["health"]}
	_pc.host_apply_action("p", "rest")
	assert_eq(int(_gs.players["p"]["hp"]), 3, "лечение здоровья подавлено")
	assert_eq(int(_gs.players["p"]["sanity"]), 4, "рассудок всё равно лечится")


func test_rest_prompts_on_rest_spells() -> void:
	_solo()
	_pc.host_apply_action("p", "rest")
	assert_has(_gs._spell.prompt_events, "onRest", "отдых выставляет промпт onRest-заклинаний")


func test_rest_prompt_holds_turn_until_resolved() -> void:
	# Отдых последним действием + есть onRest-заклинания (prompt_returns=true) → ход
	# НЕ уходит, пока игрок не разрешит промпт; после резолва — уходит (solo → encounter).
	_solo()
	_gs._spell.prompt_returns = true
	_gs.players["p"]["actions_left"] = 1  # отдых станет последним действием
	_pc.host_apply_action("p", "rest")
	assert_eq(int(_gs.players["p"]["actions_left"]), 0, "действие потрачено")
	assert_true(bool(_gs.players["p"].get("spell_prompt", false)), "ход держится промптом")
	assert_eq(_gs.phase, "action", "ход не ушёл — фаза не сменилась")
	_pc.host_apply_cast_trigger_spells("p", [])
	assert_false(bool(_gs.players["p"].get("spell_prompt", false)), "промпт-флаг снят")
	assert_eq(_gs.phase, "encounter", "после резолва ход ушёл")


func test_travel_moves_when_connected() -> void:
	_solo({"location": "A"})
	_gs.locations = [{"id": "A", "connections": [{"to": "B"}]}, {"id": "B", "connections": []}]
	assert_true(_pc.host_apply_action("p", "travel", {"to": "B"}))
	assert_eq(String(_gs.players["p"]["location"]), "B")


func test_travel_rejected_when_not_connected() -> void:
	_solo({"location": "A"})
	_gs.locations = [{"id": "A", "connections": [{"to": "B"}]}]
	assert_false(_pc.host_apply_action("p", "travel", {"to": "Z"}), "Z недостижима")


# ── Обмен (trade) ─────────────────────────────────────────────────────────────


# Два игрока p (активный) и q на одной локации X с предметами/уликами.
func _two_traders() -> void:
	_gs.turn_order = ["p", "q"]
	_gs.current_idx = 0
	_gs.players["p"] = {
		"location": "X", "actions_left": 2, "actions_used": [], "items": [{"id": "a"}], "clues": 2
	}
	_gs.players["q"] = {
		"location": "X",
		"actions_left": 2,
		"actions_used": [],
		"items": [{"id": "b"}, {"id": "c"}],
		"clues": 1,
	}


func test_trade_moves_items_and_clues() -> void:
	_two_traders()
	# p отдаёт предмет 0 (a) и 1 улику, берёт предмет 1 у q (c) и 1 улику.
	var ok: bool = _pc.host_apply_action(
		"p", "trade", {"partner": "q", "give": [0], "take": [1], "giveClues": 1, "takeClues": 1}
	)
	assert_true(ok, "обмен выполнен")
	var p_items: Array = _gs.players["p"]["items"]
	assert_eq(p_items.size(), 1)
	assert_eq(String((p_items[0] as Dictionary)["id"]), "c", "p получил c")
	assert_eq(int(_gs.players["p"]["clues"]), 2, "p: 2 − 1 + 1")
	var q_items: Array = _gs.players["q"]["items"]
	assert_eq(q_items.size(), 2, "q: оставил b, получил a")
	assert_eq(String((q_items[0] as Dictionary)["id"]), "b")
	assert_eq(String((q_items[1] as Dictionary)["id"]), "a")
	assert_eq(int(_gs.players["q"]["clues"]), 1, "q: 1 − 1 + 1")
	assert_eq(int(_gs.players["p"]["actions_left"]), 1, "обмен потратил действие")


func test_trade_rejected_different_location() -> void:
	_two_traders()
	_gs.players["q"]["location"] = "Y"
	assert_false(_pc.host_apply_action("p", "trade", {"partner": "q", "give": [0]}))
	assert_eq((_gs.players["p"]["items"] as Array).size(), 1, "ничего не перенесено")
	assert_eq(int(_gs.players["p"]["actions_left"]), 2, "действие не потрачено")


func test_trade_rejected_unknown_partner() -> void:
	_two_traders()
	assert_false(_pc.host_apply_action("p", "trade", {"partner": "zzz", "give": [0]}))


func test_trade_rejected_insufficient_clues() -> void:
	_two_traders()
	assert_false(_pc.host_apply_action("p", "trade", {"partner": "q", "giveClues": 9}))
	assert_eq(int(_gs.players["p"]["clues"]), 2, "улики не списаны")


func test_trade_rejected_bad_item_index() -> void:
	_two_traders()
	assert_false(
		_pc.host_apply_action("p", "trade", {"partner": "q", "give": [5]}), "индекс вне инвентаря"
	)
	assert_eq((_gs.players["p"]["items"] as Array).size(), 1, "инвентарь цел")


func test_condition_action_succeeds() -> void:
	_solo()
	_gs._cond.action_ok = true
	assert_true(_pc.host_apply_action("p", "condition_action", {"condition": "detained"}))
	assert_eq(int(_gs.players["p"]["actions_left"]), 1)


func test_condition_action_rejected_when_no_action() -> void:
	_solo()
	_gs._cond.action_ok = false
	assert_false(_pc.host_apply_action("p", "condition_action", {"condition": "poisoned"}))


func test_condition_action_allowed_under_cannot_act() -> void:
	_solo()
	_gs._cond.cannot = {"cannotAct": true}
	_gs._cond.action_ok = true
	assert_true(_pc.host_apply_action("p", "condition_action", {"condition": "detained"}), "escape")


func test_acquire_assets_opens_shop_and_rolls() -> void:
	_solo({"location": "arkham"})
	_gs.loc_types = {"arkham": "city"}
	assert_true(_pc.host_apply_action("p", "acquire_assets"))
	assert_true(bool(_gs.players["p"]["shopping"]), "флаг shopping выставлен")
	assert_has(_gs._check.started, "shop", "проверка магазина стартована")
	assert_has(_gs._check.rolled, "p", "бросок Влияния сделан")


func test_pass_hands_turn_to_next_player() -> void:
	_gs.turn_order = ["p", "p2"]
	_gs.current_idx = 0
	_add_player("p")
	_add_player("p2")
	assert_true(_pc.host_apply_action("p", "pass"))
	assert_eq(int(_gs.players["p"]["actions_left"]), 0, "pass обнуляет действия")
	assert_eq(_gs.current_idx, 1, "ход передан следующему игроку")


func test_pass_last_player_enters_encounter_phase() -> void:
	_solo()
	assert_true(_pc.host_apply_action("p", "pass"))
	assert_eq(_gs.phase, "encounter", "после последнего игрока — фаза встреч")


# ── can_travel ────────────────────────────────────────────────────────────────


func test_can_travel_rejects_empty_dest() -> void:
	_solo({"location": "A"})
	assert_false(_pc.can_travel("p", ""))


func test_can_travel_blocked_by_cannot_move() -> void:
	_solo({"location": "A"})
	_gs.locations = [{"id": "A", "connections": [{"to": "B"}]}]
	_gs._cond.cannot = {"cannotMove": true}
	assert_false(_pc.can_travel("p", "B"), "whileHeld cannotMove запрещает travel")


func test_can_travel_rejects_same_location() -> void:
	_solo({"location": "A"})
	_gs.locations = [{"id": "A", "connections": [{"to": "B"}]}]
	assert_false(_pc.can_travel("p", "A"), "перемещение на месте бессмысленно")


func test_can_travel_true_when_connected() -> void:
	_solo({"location": "A"})
	_gs.locations = [{"id": "A", "connections": [{"to": "B"}, {"to": "C"}]}]
	assert_true(_pc.can_travel("p", "C"))


func test_can_travel_false_when_not_connected() -> void:
	_solo({"location": "A"})
	_gs.locations = [{"id": "A", "connections": [{"to": "B"}]}]
	assert_false(_pc.can_travel("p", "C"))


# ── skip_disconnected ─────────────────────────────────────────────────────────


func test_skip_disconnected_stops_on_connected() -> void:
	_gs.turn_order = ["p"]
	_gs.current_idx = 0
	_add_player("p")
	assert_true(_pc.skip_disconnected())
	assert_eq(_gs.current_idx, 0, "уже на подключённом — не двигаемся")


func test_skip_disconnected_advances_past_disconnected() -> void:
	_gs.turn_order = ["d", "p"]
	_gs.current_idx = 0
	_add_player("d", {"connected": false})
	_add_player("p")
	assert_true(_pc.skip_disconnected())
	assert_eq(_gs.current_idx, 1, "пропустили отключённого")


func test_skip_disconnected_false_when_all_gone() -> void:
	_gs.turn_order = ["d"]
	_gs.current_idx = 0
	_add_player("d", {"connected": false})
	assert_false(_pc.skip_disconnected(), "ходить некому")


# ── start_new_round ───────────────────────────────────────────────────────────


func test_start_new_round_resets_state() -> void:
	_gs.turn_order = ["p"]
	_add_player("p", {"actions_left": 0, "actions_used": ["rest"], "encounter_done": true})
	_pc.start_new_round()
	assert_eq(_gs.round_num, 2, "раунд увеличен")
	assert_eq(_gs.phase, "action")
	var p: Dictionary = _gs.players["p"]
	assert_eq(int(p["actions_left"]), 2, "окно действий восстановлено (ACTIONS_PER_ROUND)")
	assert_eq((p["actions_used"] as Array).size(), 0, "использованные сброшены")
	assert_false(bool(p["encounter_done"]), "встречи закрыты")


# ── host_apply_shop_debt ──────────────────────────────────────────────────────


func test_shop_debt_adds_condition() -> void:
	_solo({"location": "arkham"})
	_gs.loc_types = {"arkham": "city"}
	assert_true(_pc.host_apply_shop_debt("p"))
	assert_true((_gs.players["p"]["conditions"] as Array).has("debt"))


func test_shop_debt_rejected_out_of_turn() -> void:
	_gs.turn_order = ["p", "p2"]
	_gs.current_idx = 1  # ход p2
	_add_player("p", {"location": "arkham"})
	_add_player("p2")
	_gs.loc_types = {"arkham": "city"}
	assert_false(_pc.host_apply_shop_debt("p"), "не свой ход")


func test_shop_debt_rejected_outside_city() -> void:
	_solo({"location": "wild"})
	_gs.loc_types = {"wild": "wilderness"}
	assert_false(_pc.host_apply_shop_debt("p"), "Долг берут только в городе")


func test_shop_debt_duplicate_rejected() -> void:
	_solo({"location": "arkham", "conditions": ["debt"]})
	_gs.loc_types = {"arkham": "city"}
	assert_false(_pc.host_apply_shop_debt("p"), "повторный Долг игнорируется")


# ── cast_spell (Ritual = действие) ────────────────────────────────────────────


func test_cast_spell_spends_action_on_success() -> void:
	_solo()
	_gs._spell.ok = true
	assert_true(_pc.host_apply_action("p", "cast_spell", {"item": 0}))
	assert_eq(int(_gs.players["p"]["actions_left"]), 1, "каст потратил действие")
	assert_eq(_gs._spell.cast_calls, [0], "cast_ritual вызван с item_index")


func test_cast_spell_rejected_when_invalid() -> void:
	_solo()
	_gs._spell.ok = false
	assert_false(_pc.host_apply_action("p", "cast_spell", {"item": 0}))
	assert_eq(int(_gs.players["p"]["actions_left"]), 2, "невалидный каст — действие не тратится")
