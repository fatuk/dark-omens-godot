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

	# false → phase_controller идёт синхронным путём (host_run_condition_action),
	# который и проверяют эти тесты. Видимый CheckFlow-путь покрыт в test_condition_flow.
	func begin_action(_pid: String, _cid: String) -> bool:
		return false

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

	func begin_ritual(_pid: String, idx: int) -> bool:
		cast_calls.append(idx)
		return ok

	func prompt_trigger(_pid: String, event: String) -> bool:
		prompt_events.append(event)
		return prompt_returns

	func host_apply_trigger_spells(_pid: String, indices: Array, _flow: Dictionary = {}) -> bool:
		resolved.append(indices)
		return true


class StubDeath:
	extends RefCounted

	func clear_grace() -> void:
		pass


class MockGameState:
	extends Node
	signal phase_changed(phase: String)
	const ACTIONS_PER_ROUND := 2
	const MAX_TICKETS := 2
	const MAX_CONCENTRATION := 2
	const MAX_RESOURCES := 2
	var phase: String = "action"
	var players: Dictionary = {}
	var turn_order: Array = []
	var current_idx: int = 0
	var round_num: int = 1
	var active_check: Dictionary = {}
	var shop_reserve: Array = []
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
	var _death: StubDeath

	func _init() -> void:
		_cond = StubCond.new()
		_check = StubCheck.new()
		_mythos = StubFlow.new()
		_encounter = StubFlow.new()
		_spell = StubSpell.new()
		_death = StubDeath.new()

	func _current_pid() -> String:
		return String(turn_order[current_idx]) if current_idx < turn_order.size() else ""

	func _name_of(pid: String) -> String:
		return pid

	# Граф локаций: тесты задают связи через `locations`, а тип — отдельно через
	# `loc_types` (часто без записи в locations). Сливаем в одну картину на каждое
	# чтение, чтобы присваивания в тесте подхватывались без setup-хуков.
	var map: LocationGraph:
		get:
			var merged: Array = []
			var seen: Dictionary = {}
			for l_v: Variant in locations:
				var l: Dictionary = (l_v as Dictionary).duplicate()
				var lid: String = String(l.get("id", ""))
				if loc_types.has(lid):
					l["type"] = loc_types[lid]
				seen[lid] = true
				merged.append(l)
			for lid_v: Variant in loc_types:
				if not seen.has(lid_v):
					merged.append({"id": lid_v, "type": loc_types[lid_v], "connections": []})
			return LocationGraph.new(merged)

	func _refill_shop_reserve(_a: Array) -> void:
		pass

	func _refresh_items(_p: Dictionary) -> void:
		pass

	func _broadcast_sync() -> void:
		sync_count += 1

	func _emit_changed() -> void:
		pass

	func announce_action(_pid: String, _action_id: String, _params: Dictionary = {}) -> void:
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


func test_buy_ticket_rejected_at_ticket_cap() -> void:
	# Город с обеими дорогами; на руках уже 2 билета (1 ж/д + 1 корабль) → потолок.
	_gs.loc_types["c1"] = "city"
	_gs.locations = [
		{"id": "c1", "connections": [{"to": "x", "type": "train"}, {"to": "y", "type": "ship"}]}
	]
	_solo({"location": "c1", "train_tickets": 1, "ship_tickets": 1})
	assert_false(_pc.host_apply_action("p", "buy_ticket", {"type": "train"}), "потолок 2 билета")
	assert_eq(int(_gs.players["p"]["actions_left"]), 2, "действие не потрачено")
	assert_eq(int(_gs.players["p"].get("train_tickets", 0)), 1, "билет не добавлен")


func test_take_concentration_increments() -> void:
	_solo()
	assert_true(_pc.host_apply_action("p", "take_concentration"))
	assert_eq(int(_gs.players["p"]["concentration"]), 1)


func test_take_concentration_rejected_at_cap() -> void:
	# Потолок 2: на максимуме действие не тратится (как билеты).
	_solo({"concentration": 2})
	var actions: int = int(_gs.players["p"]["actions_left"])
	assert_false(_pc.host_apply_action("p", "take_concentration"), "нельзя больше 2 концентрации")
	assert_eq(int(_gs.players["p"]["concentration"]), 2, "не выросла")
	assert_eq(int(_gs.players["p"]["actions_left"]), actions, "действие не потрачено")


func test_take_resource_increments() -> void:
	_solo()
	assert_true(_pc.host_apply_action("p", "take_resource"))
	assert_eq(int(_gs.players["p"]["resources"]), 1)


func test_take_resource_rejected_at_cap() -> void:
	# Потолок 2 (MAX_RESOURCES): на максимуме действие не тратится.
	_solo({"resources": 2})
	var actions: int = int(_gs.players["p"]["actions_left"])
	assert_false(_pc.host_apply_action("p", "take_resource"), "нельзя больше 2 ресурсов")
	assert_eq(int(_gs.players["p"]["resources"]), 2, "не выросла")
	assert_eq(int(_gs.players["p"]["actions_left"]), actions, "действие не потрачено")


func test_rest_heals_hp_and_sanity() -> void:
	_solo()
	_pc.host_apply_action("p", "rest")
	assert_eq(int(_gs.players["p"]["hp"]), 4, "+1 здоровья")
	assert_eq(int(_gs.players["p"]["sanity"]), 4, "+1 рассудка")


func test_rest_resources_heal_hp_and_sanity() -> void:
	# База +1 каждому (3→4), затем по ресурсу в hp и рассудок (4→5). Оба списаны.
	_solo({"resources": 2})
	_pc.host_apply_action("p", "rest", {"res_hp": 1, "res_san": 1})
	assert_eq(int(_gs.players["p"]["hp"]), 5, "база +1 и ресурс +1")
	assert_eq(int(_gs.players["p"]["sanity"]), 5, "база +1 и ресурс +1")
	assert_eq(int(_gs.players["p"]["resources"]), 0, "оба ресурса списаны")


func test_rest_resources_clamped_by_headroom() -> void:
	# hp достигает максимума базовым лечением (6→7) → ресурс на hp не тратится.
	_solo({"resources": 2, "hp": 6})
	_pc.host_apply_action("p", "rest", {"res_hp": 2, "res_san": 0})
	assert_eq(int(_gs.players["p"]["hp"]), 7, "hp не выше максимума")
	assert_eq(int(_gs.players["p"]["resources"]), 2, "ресурсы не списаны — некуда лечить")


func test_rest_resources_suppressed_by_cannot_recover() -> void:
	_solo({"resources": 1})
	_gs._cond.constraints = {"cannotRecover": ["health"]}
	_pc.host_apply_action("p", "rest", {"res_hp": 1, "res_san": 0})
	assert_eq(int(_gs.players["p"]["hp"]), 3, "cannotRecover — ресурс на hp не действует")
	assert_eq(int(_gs.players["p"]["resources"]), 1, "ресурс не списан")


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


# Цепочка A =train= B =train= C для проверки траты билетов на доп. хопы.
func _chain_abc() -> void:
	_gs.locations = [
		{"id": "A", "connections": [{"to": "B", "type": "train"}]},
		{"id": "B", "connections": [{"to": "A", "type": "train"}, {"to": "C", "type": "train"}]},
		{"id": "C", "connections": [{"to": "B", "type": "train"}]},
	]


func test_travel_multi_hop_spends_ticket() -> void:
	_solo({"location": "A", "train_tickets": 1, "ship_tickets": 0})
	_chain_abc()
	assert_true(_pc.host_apply_action("p", "travel", {"to": "C"}), "C достижим за 1 ж/д")
	assert_eq(String(_gs.players["p"]["location"]), "C")
	assert_eq(int(_gs.players["p"]["train_tickets"]), 0, "ж/д-билет списан")
	assert_eq(_gs.players["p"]["travel_path"], ["A", "B", "C"], "путь сохранён для анимации")


func test_travel_two_hops_rejected_without_ticket() -> void:
	_solo({"location": "A", "train_tickets": 0})
	_chain_abc()
	assert_false(_pc.host_apply_action("p", "travel", {"to": "C"}), "без билета 2-й хоп нельзя")
	assert_eq(String(_gs.players["p"]["location"]), "A", "остался на месте")


func test_travel_base_hop_keeps_tickets() -> void:
	_solo({"location": "A", "train_tickets": 1})
	_chain_abc()
	assert_true(_pc.host_apply_action("p", "travel", {"to": "B"}), "соседний B — базовый хоп")
	assert_eq(int(_gs.players["p"]["train_tickets"]), 1, "базовый хоп билет не тратит")


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


func test_skip_disconnected_advances_past_dead() -> void:
	# Погибший (Тень) не берёт обычный ход — пропускается как отключённый.
	_gs.turn_order = ["ghost", "p"]
	_gs.current_idx = 0
	_add_player("ghost", {"dead": true})
	_add_player("p")
	assert_true(_pc.skip_disconnected())
	assert_eq(_gs.current_idx, 1, "пропустили погибшего")


func test_skip_disconnected_false_when_all_dead() -> void:
	_gs.turn_order = ["g1", "g2"]
	_gs.current_idx = 0
	_add_player("g1", {"dead": true})
	_add_player("g2", {"dead": true})
	assert_false(_pc.skip_disconnected(), "все — Тени, ходить некому")


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


func test_shop_spend_resource_adds_coin_and_deducts() -> void:
	_solo({"location": "arkham", "resources": 2})
	_gs.loc_types = {"arkham": "city"}
	_gs.active_check = {"owner": "shop", "pid": "p"}
	assert_true(_pc.host_apply_shop_spend_resource("p"))
	assert_eq(int(_gs.players["p"]["resources"]), 1, "ресурс списан")
	assert_eq(int(_gs.active_check.get("shop_resource_coins", 0)), 1, "монета добавлена")


func test_shop_spend_resource_rejected_without_resources() -> void:
	_solo({"location": "arkham", "resources": 0})
	_gs.active_check = {"owner": "shop", "pid": "p"}
	assert_false(_pc.host_apply_shop_spend_resource("p"), "нет ресурсов — отказ")


func test_shop_spend_resource_rejected_when_not_shopper() -> void:
	_solo({"resources": 2})
	_gs.active_check = {"owner": "shop", "pid": "other"}
	assert_false(_pc.host_apply_shop_spend_resource("p"), "не активный покупатель — отказ")
	assert_eq(int(_gs.players["p"]["resources"]), 2, "ресурс не тронут")


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


func test_cast_spell_begins_spends_action_and_holds_turn() -> void:
	_solo()
	_gs._spell.ok = true
	assert_true(_pc.host_apply_action("p", "cast_spell", {"item": 0}))
	assert_eq(int(_gs.players["p"]["actions_left"]), 1, "каст потратил действие")
	assert_eq(_gs._spell.cast_calls, [0], "begin_ritual вызван с item_index")
	assert_true(bool(_gs.players["p"].get("casting", false)), "ход держится до «Применить»")


func test_cast_spell_rejected_when_invalid() -> void:
	_solo()
	_gs._spell.ok = false
	assert_false(_pc.host_apply_action("p", "cast_spell", {"item": 0}))
	assert_eq(int(_gs.players["p"]["actions_left"]), 2, "невалидный каст — действие не тратится")
	assert_false(bool(_gs.players["p"].get("casting", false)), "невалидный каст — не держим ход")


func test_cast_as_last_action_holds_turn_until_release() -> void:
	# Каст последним действием НЕ передаёт ход, пока игрок не нажал «Применить».
	_gs.turn_order = ["p", "p2"]
	_gs.current_idx = 0
	_add_player("p", {"actions_left": 1})
	_add_player("p2")
	_gs._spell.ok = true
	_pc.host_apply_action("p", "cast_spell", {"item": 0})
	assert_eq(int(_gs.players["p"]["actions_left"]), 0, "действие потрачено")
	assert_eq(_gs.current_idx, 0, "ход держится (casting), хотя действий 0")
	_pc.release_cast_turn("p")
	assert_false(bool(_gs.players["p"].get("casting", false)), "casting снят")
	assert_eq(_gs.current_idx, 1, "после применения отложенный ход передан")


func test_cast_spell_not_blocked_by_repeat_guard() -> void:
	# Каст — исключение из «один раз за раунд»: можно скастить ещё, пока есть действия.
	_solo({"actions_used": ["cast_spell"]})
	_gs._spell.ok = true
	assert_true(_pc.host_apply_action("p", "cast_spell", {"item": 0}), "повторный каст разрешён")
	assert_true(bool(_gs.players["p"].get("casting", false)), "каст начат")
	assert_eq(
		(_gs.players["p"]["actions_used"] as Array).count("cast_spell"),
		1,
		"cast_spell не дублируется в actions_used"
	)


# ── host_apply_shop_grant: валидация витрины и оплаты ─────────────────────────
# Реальные ассеты из data/assets.json: 18_derringer=1, 45_automatic=2, arcane_tome=3.


# Игрок в разгар похода в магазин: в городе, «acquire_assets» уже потрачено,
# активна проверка магазина с заданными успехами, витрина = reserve.
func _shopper(successes: int, reserve: Array, extra: Dictionary = {}) -> void:
	_gs.loc_types = {"arkham": "city"}
	var base: Dictionary = {"actions_used": ["acquire_assets"], "location": "arkham"}
	for k_v: Variant in extra:
		base[k_v] = extra[k_v]
	_solo(base)
	_gs.active_check = {"owner": "shop", "successes": successes}
	_gs.shop_reserve = reserve


func test_shop_grant_rejects_item_not_in_reserve() -> void:
	_shopper(9, ["18_derringer"])  # монет вдоволь, но axe нет на витрине
	assert_false(_pc.host_apply_shop_grant("p", ["axe"]), "товар не с витрины — отказ")
	assert_eq(_gs._cond.granted, [], "ничего не выдано")


func test_shop_grant_rejects_insufficient_coins() -> void:
	_shopper(2, ["arcane_tome"])  # tome стоит 3, успехов только 2
	assert_false(_pc.host_apply_shop_grant("p", ["arcane_tome"]), "не хватает монет — отказ")
	assert_eq(_gs._cond.granted, [], "ничего не выдано")


func test_shop_grant_debt_adds_two_coins() -> void:
	# tome=3; успехов 1, но состояние «debt» даёт +2 → ровно хватает.
	_shopper(1, ["arcane_tome"], {"conditions": ["debt"]})
	assert_true(_pc.host_apply_shop_grant("p", ["arcane_tome"]), "1 успех + Долг(+2) = 3")
	assert_eq(_gs._cond.granted, ["arcane_tome"], "товар выдан")


func test_shop_grant_success_within_budget() -> void:
	_shopper(3, ["18_derringer", "45_automatic"])  # 1 + 2 = 3 ровно
	assert_true(_pc.host_apply_shop_grant("p", ["18_derringer", "45_automatic"]))
	assert_eq(_gs._cond.granted, ["18_derringer", "45_automatic"], "оба товара выданы")


func test_shop_grant_rejects_without_active_shop_check() -> void:
	_shopper(9, ["18_derringer"])
	_gs.active_check = {}  # проверка магазина уже снята — монеты неизвестны
	assert_false(_pc.host_apply_shop_grant("p", ["18_derringer"]), "нет активной проверки — отказ")


# ── host_apply_shop_sell_asset: продажа актива за монету ──────────────────────
#
# Любой актив стоит одну монету, как потраченный ресурс. За заход в магазин
# продать можно ровно один: флаг живёт на active_check, а он создаётся заново
# каждым SHOP_OPEN.


func _shopper_with(items: Array) -> void:
	_solo({"location": "arkham", "items": items})
	_gs.loc_types = {"arkham": "city"}
	_gs.active_check = {"owner": "shop", "pid": "p"}


func test_shop_sell_asset_gives_coin_and_removes_card() -> void:
	_shopper_with([{"id": "ancient_manuscript"}, {"id": "monster_hunter"}])
	assert_true(_pc.host_apply_shop_sell_asset("p", 0))
	assert_eq((_gs.players["p"]["items"] as Array).size(), 1, "карта ушла из имущества")
	assert_eq(
		String((_gs.players["p"]["items"] as Array)[0]["id"]), "monster_hunter", "ушла именно та"
	)
	assert_eq(int(_gs.active_check.get("shop_resource_coins", 0)), 1, "монета добавлена")


func test_shop_sell_asset_only_once_per_visit() -> void:
	_shopper_with([{"id": "ancient_manuscript"}, {"id": "monster_hunter"}])
	assert_true(_pc.host_apply_shop_sell_asset("p", 0))
	assert_false(_pc.host_apply_shop_sell_asset("p", 0), "второй актив за заход не продать")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 1, "вторая карта на месте")
	assert_eq(int(_gs.active_check.get("shop_resource_coins", 0)), 1, "монета всё ещё одна")


func test_shop_sell_asset_rejects_non_asset_and_bad_index() -> void:
	_shopper_with([{"id": "не-актив", "kind": "spell"}])
	assert_false(_pc.host_apply_shop_sell_asset("p", 0), "не актив — отказ")
	assert_false(_pc.host_apply_shop_sell_asset("p", 5), "индекс вне списка — отказ")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 1, "имущество не тронуто")


func test_shop_sell_asset_rejected_when_not_shopper() -> void:
	_shopper_with([{"id": "ancient_manuscript"}])
	_gs.active_check = {"owner": "shop", "pid": "other"}
	assert_false(_pc.host_apply_shop_sell_asset("p", 0), "не активный покупатель — отказ")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 1, "карта на месте")
