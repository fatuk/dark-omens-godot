## BotDriver: решения бота по состоянию игры (стаб GameState) и готовность в лобби.
extends GutTest

const Driver := preload("res://scripts/core/bots/bot_driver.gd")

const BOT := "bot-1"


# Минимальный GameState: поля, которые читает драйвер.
class StubGs:
	extends Node
	signal state_changed
	var active: bool = true
	var phase: String = "action"
	var players: Dictionary = {}
	var turn_order: Array = []
	var current_idx: int = 0
	var active_check: Dictionary = {}
	var pending_check: Dictionary = {}
	var mythos_decision: Dictionary = {}
	var encounter_choices: Array = []
	var current_encounter: Dictionary = {}
	var reckoning_results: Dictionary = {}
	var trade_offer: Dictionary = {}
	var last_cast_result: Dictionary = {}
	var current_mythos: Dictionary = {}
	var mythos_read: Array = []
	var entities: Dictionary = {}
	var monsters: Dictionary = {}
	var gates: Dictionary = {}
	var mystery_claimed: Array = []
	var mystery: Dictionary = {}
	var constraints: Dictionary = {}  # verb → true
	var map: LocationGraph = (
		LocationGraph
		. new(
			[
				{"id": "A", "type": "city", "connections": [{"to": "B"}, {"to": "C"}]},
				{"id": "B", "type": "city", "connections": [{"to": "A"}, {"to": "D"}]},
				{"id": "C", "type": "sea", "connections": [{"to": "A"}]},
				{"id": "D", "type": "wilderness", "connections": [{"to": "B"}]},
			]
		)
	)

	func current_pid() -> String:
		return turn_order[current_idx] if current_idx < turn_order.size() else ""

	func player_has_constraint(_pid: String, verb: String) -> bool:
		return constraints.has(verb)

	func current_mystery() -> Dictionary:
		return mystery

	func has_monster_at(loc_id: String) -> bool:
		return not (monsters.get(loc_id, []) as Array).is_empty()


class StubNm:
	extends Node
	signal relay_received(from_id: String, data: Dictionary)
	var players: Dictionary = {}


var _gs: StubGs
var _nm: StubNm
var _d: Node
var _out: Array = []


func before_each() -> void:
	_gs = add_child_autofree(StubGs.new())
	_nm = add_child_autofree(StubNm.new())
	_gs.players[BOT] = {
		"location": "A",
		"hp": 5,
		"hp_max": 5,
		"sanity": 5,
		"sanity_max": 5,
		"actions_left": 2,
		"actions_used": [],
		"concentration": 0,
	}
	_gs.turn_order = [BOT]
	_out.clear()
	_d = Driver.new()
	_d.rng.seed = 3
	_d.setup([BOT], _gs, _nm)
	_d.sender = func(from_id: String, msg: Dictionary) -> void:
		_out.append({"from": from_id, "msg": msg})
	add_child_autofree(_d)


func _act(role: String = "fighter") -> Dictionary:
	return _d.decide(BOT, role)


func test_waits_when_not_my_turn() -> void:
	_gs.turn_order = ["human", BOT]
	_gs.players["human"] = {"location": "B"}
	assert_eq(_act(), {})


func test_fighter_moves_toward_nearest_monster() -> void:
	_gs.monsters = {"D": [{"id": "cultist"}]}
	var a: Dictionary = _act("fighter")
	assert_eq(a["type"], GameActions.TRAVEL)
	assert_eq(a["payload"]["to"], "B", "первый шаг A→B→D")


func test_runner_prefers_clue_then_mystery_then_gate() -> void:
	_gs.gates = {"C": {}}
	_gs.mystery = {"locations": ["D"]}
	assert_eq(_act("runner")["payload"]["to"], "B", "Тайна важнее врат")
	_gs.entities = {"C": ["clue"]}
	assert_eq(_act("runner")["payload"]["to"], "C", "улика важнее всего")
	_gs.mystery_claimed = ["D"]
	_gs.entities = {}
	assert_eq(_act("runner")["payload"]["to"], "C", "зачищенная Тайна не цель → врата")


func test_on_goal_or_no_goal_focus_then_rest_then_pass() -> void:
	_gs.monsters = {"A": [{"id": "cultist"}]}
	assert_eq(_act()["type"], GameActions.TAKE_CONCENTRATION, "на цели — стоим и фокусируемся")
	_gs.players[BOT]["concentration"] = GameState.MAX_CONCENTRATION
	_gs.players[BOT]["actions_used"] = [GameActions.TRAVEL]
	assert_eq(_act()["type"], GameActions.PASS, "здоров, фокус полон, переезд был — пас")
	_gs.players[BOT]["hp"] = 4
	assert_eq(_act()["type"], GameActions.PASS, "ранен, но монстр на клетке — отдыхать нельзя")
	_gs.monsters = {}
	assert_eq(_act()["type"], GameActions.REST, "ранен, монстра нет — отдых")


func test_low_health_rests_first_and_cannot_move_skips_travel() -> void:
	_gs.monsters = {"D": [{"id": "x"}]}
	_gs.players[BOT]["sanity"] = 2
	assert_eq(_act()["type"], GameActions.REST)
	_gs.players[BOT]["sanity"] = 5
	_gs.constraints["cannotMove"] = true
	assert_eq(_act()["type"], GameActions.TAKE_CONCENTRATION)


func test_travel_anim_and_holds() -> void:
	_gs.players[BOT]["travel_anim"] = true
	assert_eq(_act()["action"], RelayActions.TRAVEL_ARRIVED)
	_gs.players[BOT].erase("travel_anim")
	_gs.players[BOT]["asset_acting"] = true
	assert_eq(_act(), {}, "ход держит актив — ждём")


func test_encounter_choice_and_flat_card_flow() -> void:
	_gs.phase = "encounter"
	_gs.encounter_choices = ["general", "research", "combat:1"]
	assert_eq(_act()["kind"], "combat:1", "порядок боёв — первым")
	_gs.encounter_choices = ["general", "research"]
	assert_eq(_act()["kind"], "research")
	_gs.encounter_choices = []
	assert_eq(_act(), {}, "карта генерится — ждём")
	_gs.current_encounter = {"kind": "general", "test": {"skill": "lore"}}
	assert_eq(_act()["action"], RelayActions.RESOLVE_ENCOUNTER)
	_gs.active_check = {"owner": "encounter", "rolled": true}
	assert_eq(_act()["action"], RelayActions.FINISH_ENCOUNTER)
	_gs.current_encounter["pending_choice"] = {"options": [{}, {}, {}]}
	var c: Dictionary = _act()
	assert_eq(c["action"], RelayActions.CHOOSE_EFFECT)
	assert_true(int(c["index"]) >= 0 and int(c["index"]) <= 2)
	_gs.current_encounter = {"kind": "belongings"}
	_gs.active_check = {}
	assert_eq(_act()["action"], RelayActions.FINISH_ENCOUNTER, "без проверки — сразу завершить")
	_gs.players[BOT]["encounter_done"] = true
	assert_eq(_act(), {})


func test_gate_and_combat_flow() -> void:
	_gs.phase = "encounter"
	_gs.current_encounter = {"kind": "gate", "stage": 0}
	assert_eq(_act()["action"], RelayActions.RESOLVE_ENCOUNTER)
	_gs.active_check = {"owner": "encounter", "rolled": true}
	assert_eq(_act()["action"], RelayActions.ADVANCE_STAGE)
	_gs.current_encounter["stage"] = 1
	assert_eq(_act()["action"], RelayActions.FINISH_ENCOUNTER)
	# Бой: Воля → применить → Сила → завершить.
	_gs.current_encounter = {"kind": "combat"}
	_gs.active_check = {"owner": "combat", "rolled": false}
	assert_eq(_act()["action"], RelayActions.RESOLVE_ENCOUNTER, "бросить Волю")
	_gs.active_check["rolled"] = true
	assert_eq(_act()["action"], RelayActions.RESOLVE_ENCOUNTER, "применить Волю")
	_gs.current_encounter["will"] = {}
	_gs.active_check["rolled"] = false
	assert_eq(_act()["action"], RelayActions.RESOLVE_ENCOUNTER, "бросить Силу")
	_gs.active_check["rolled"] = true
	assert_eq(_act()["action"], RelayActions.FINISH_ENCOUNTER, "Сила брошена — завершить")
	_gs.current_encounter = {"kind": "combat", "will": {}, "defeated_on_horror": true}
	_gs.active_check = {}
	assert_eq(_act()["action"], RelayActions.RESOLVE_ENCOUNTER, "без шага Силы — применить")
	_gs.current_encounter["resolution"] = {}
	assert_eq(_act()["action"], RelayActions.FINISH_ENCOUNTER)


func test_global_waits_have_priority() -> void:
	_gs.phase = "mythos"
	_gs.current_mythos = {"name": "x"}
	assert_eq(_act()["action"], RelayActions.RESOLVE_MYTHOS)
	_gs.mythos_read = [BOT]
	assert_eq(_act(), {})
	_gs.mythos_decision = {"active": true, "pid": BOT, "options": [1, 2]}
	assert_eq(_act()["action"], RelayActions.MYTHOS_DECIDE)
	_gs.mythos_decision = {"active": true, "pid": "human", "options": [1]}
	assert_eq(_act(), {}, "чужое решение")
	_gs.pending_check = {"pid": BOT, "driver": "condition"}
	assert_eq(_act()["action"], RelayActions.CHECK_ROLL)
	_gs.active_check = {"owner": "effectCheck", "rolled": true}
	assert_eq(_act()["action"], RelayActions.RESOLVE_PENDING_CHECK)
	_gs.players[BOT]["gains"] = {"clues": 1}
	assert_eq(_act()["action"], RelayActions.DISMISS_GAINS)
	_gs.reckoning_results[BOT] = {}
	assert_eq(_act()["action"], RelayActions.DISMISS_RECKONING)
	_gs.players[BOT]["reckoning_check"] = {"rolled": false}
	assert_eq(_act()["action"], RelayActions.RECKONING_ROLL)
	_gs.players[BOT]["reckoning_check"]["rolled"] = true
	assert_eq(_act()["action"], RelayActions.RECKONING_APPLY)
	_gs.players[BOT]["death_save_check"] = {"rolled": true}
	assert_eq(_act()["action"], RelayActions.DEATH_SAVE_APPLY)
	_gs.players[BOT]["dead"] = true
	assert_eq(_act(), {}, "Тень не ходит")


func test_tick_sends_one_action_with_pid_and_throttles_repeats() -> void:
	_gs.monsters = {"D": [{"id": "x"}]}
	_d._tick()
	assert_eq(_out.size(), 1)
	assert_eq(_out[0]["from"], BOT)
	assert_eq(_out[0]["msg"]["pid"], BOT)
	assert_eq(_out[0]["msg"]["action"], RelayActions.ACTION)
	_d._tick()
	assert_eq(_out.size(), 1, "то же намерение не шлём повторно сразу")
	_gs.active = false
	_gs.players[BOT]["actions_used"] = [GameActions.TRAVEL]
	_d._tick()
	assert_eq(_out.size(), 1, "игра не идёт — молчим")


func test_ready_bots_picks_free_investigator_after_human_ready() -> void:
	_nm.players = {
		"local-player": {"id": "local-player", "ready": true, "investigator": "Frank Dalton"},
		BOT: {"id": BOT, "ready": false, "investigator": ""},
	}
	_nm.relay_received.emit(BOT, {"action": "set_ready", "player_id": BOT})
	assert_eq(_out.size(), 0, "эхо своего set_ready не триггерит")
	_nm.relay_received.emit("local-player", {"action": "set_ready", "player_id": "local-player"})
	assert_eq(_out.size(), 1)
	var msg: Dictionary = _out[0]["msg"]
	assert_eq(msg["action"], "set_ready")
	assert_eq(msg["player_id"], BOT)
	assert_ne(msg["investigator"], "Frank Dalton")
	assert_false(String(msg["investigator"]).is_empty())
	_nm.players[BOT]["ready"] = true
	assert_eq(_d.ready_bots(), 0, "уже готов — не трогаем")


func test_fighter_goes_to_gate_and_picks_circle() -> void:
	_gs.gates = {"D": "green"}
	_gs.monsters = {"C": [{"id": "x"}]}
	assert_eq(_act("fighter")["payload"]["to"], "B", "врата открыты — к кругу, не к монстру")
	_gs.phase = "encounter"
	_gs.encounter_choices = ["general", "research", "gate"]
	assert_eq(_act("fighter")["kind"], "gate", "боец — в круг")
	assert_eq(_act("runner")["kind"], "research", "гонец — за уликой")


func test_branch_without_test_finishes_at_once() -> void:
	_gs.phase = "encounter"
	_gs.current_encounter = {
		"kind": "gate", "stage": 1, "branch": "success", "branches": {"success": {}}
	}
	_gs.active_check = {}
	assert_eq(_act()["action"], RelayActions.FINISH_ENCOUNTER)


func test_bot_always_accepts_trade_offer() -> void:
	_gs.trade_offer = {"from": "human", "to": BOT}
	assert_eq(_act(), {"action": RelayActions.TRADE_RESPOND, "accept": true})
	_gs.trade_offer = {"from": BOT, "to": "human"}
	assert_ne(_act().get("action", ""), RelayActions.TRADE_RESPOND, "своё предложение не принимает")


func test_bot_waits_while_human_reads_its_encounter() -> void:
	_gs.phase = "encounter"
	var text: String = "Ж".repeat(90)  # 90 знаков → 5 с чтения
	_gs.current_encounter = {"kind": "general", "test": {"skill": "lore"}, "mainText": text}
	assert_almost_eq(Driver.reading_time(text), 5.0, 0.01)
	assert_eq(Driver.reading_time(""), 0.0, "нечего читать — не ждём")
	assert_eq(Driver.reading_time("Да."), Driver.READ_MIN, "короткий — минимум")
	_d._tick()
	assert_eq(_out.size(), 0, "текст только появился — бот ждёт")
	assert_gt(_d.reading_wait(BOT), 0.0)
	_d._read_since -= 6.0  # прошло достаточно времени
	_d._tick()
	assert_eq(_out.size(), 1, "прочитано — бот бросает")
	assert_eq(_out[0]["msg"]["action"], RelayActions.RESOLVE_ENCOUNTER)
	# После броска исход наблюдателю ещё не виден (только после «Завершить»; время на
	# него даёт пауза хоста) — бот не ждёт чтения исхода перед «Завершить».
	_gs.current_encounter["failureText"] = "Ж".repeat(200)
	_gs.active_check = {"owner": "encounter", "rolled": true, "passed": false}
	assert_eq(_d.watched_text(BOT), text, "в окне — по-прежнему текст встречи")
	# Бой наблюдателю не показывается — ждать нечего.
	_gs.current_encounter = {"kind": "combat", "mainText": text}
	assert_eq(_d.watched_text(BOT), "")


# ── Заключение и пр. (cannotAct): только действие состояния или пас ───────────


func test_detained_bot_uses_condition_action_then_passes() -> void:
	# Регрессия: бот с Заключением просил отдых, хост отклонял — партия вставала.
	_gs.constraints["cannotAct"] = true
	_gs.players[BOT]["hp"] = 3  # ранен — раньше это вело к вечному «отдыху»
	_gs.players[BOT]["conditions"] = ["detained"]
	var a: Dictionary = _act()
	assert_eq(a["type"], GameActions.CONDITION_ACTION, "попытка выйти из заключения")
	assert_eq(String(a["payload"].get("condition", "")), "detained")
	_gs.players[BOT]["actions_used"] = [GameActions.CONDITION_ACTION]
	assert_eq(_act()["type"], GameActions.PASS, "попытка в раунде была — пас")


func test_cannot_act_without_condition_action_passes() -> void:
	_gs.constraints["cannotAct"] = true
	_gs.players[BOT]["conditions"] = ["lostInTimeAndSpace"]
	assert_eq(_act()["type"], GameActions.PASS)


func test_rejected_action_falls_back_to_pass() -> void:
	# Хост раз за разом не принимает действие (состояние не меняется) — бот пасует.
	var rest: Dictionary = {"action": RelayActions.ACTION, "type": GameActions.REST, "payload": {}}
	for i in range(Driver.STUCK_REPEATS + 1):
		_d.set(
			"_last",
			{BOT: (_d.get("_last") as Dictionary).get(BOT, {}).merged({"at": -100.0}, true)}
		)
		assert_true(_d.call("_send", BOT, rest), "отправка %d" % i)
	var types: Array = []
	for e: Dictionary in _out:
		types.append(String((e["msg"] as Dictionary).get("type", "")))
	assert_eq(
		types.slice(0, Driver.STUCK_REPEATS), [GameActions.REST, GameActions.REST, GameActions.REST]
	)
	assert_eq(types[Driver.STUCK_REPEATS], GameActions.PASS, "после трёх отказов — пас")


# ── Помощник проверки: карты и перебросы ─────────────────────────────────────


func _will_check(extra: Dictionary = {}) -> void:
	_gs.phase = "encounter"
	_gs.current_encounter = {"kind": "general", "test": {"skill": "will"}}
	var c: Dictionary = {
		"owner": "encounter",
		"pid": BOT,
		"skill": "will",
		"modifier": 0,
		"context": "generalEncounter",
		"rolled": false,
		"active_mods": [],
		"exhausted_cards": [],
		"add_targets": [],
		"reroll_allowance": 0,
		"rerolls_used": 0,
	}
	for k: String in extra:
		c[k] = extra[k]
	_gs.active_check = c


func test_bot_plays_fitting_card_before_roll() -> void:
	# Фонарь: +1 куб в любой проверке, без цены — играется до броска.
	_gs.players[BOT]["items"] = [{"id": "kerosene"}, {"id": "lantern"}]
	_will_check()
	var a: Dictionary = _act()
	assert_eq(a["action"], RelayActions.ACTIVATE_CARD, "сначала карта, потом бросок")
	assert_eq(int(a["index"]), 1, "Фонарь, а не Керосин (бой/Сила)")


func test_bot_skips_unfitting_card_and_rolls() -> void:
	# Керосин — только бой и Сила: в проверке Воли встречи не подходит.
	_gs.players[BOT]["items"] = [{"id": "kerosene"}]
	_will_check()
	assert_eq(_act()["action"], RelayActions.RESOLVE_ENCOUNTER, "подходящих карт нет — бросаем")


func test_bot_does_not_replay_card_used_this_check() -> void:
	_gs.players[BOT]["items"] = [{"id": "lantern"}]
	_will_check({"exhausted_cards": [0]})
	assert_eq(_act()["action"], RelayActions.RESOLVE_ENCOUNTER, "Фонарь уже в этой проверке")


func test_bot_rerolls_failed_die_with_concentration() -> void:
	_gs.players[BOT]["concentration"] = 1
	_will_check({"rolled": true, "passed": false, "base": [4, 2], "dice": [4, 2]})
	var a: Dictionary = _act()
	assert_eq(a["action"], RelayActions.REROLL_ENCOUNTER)
	assert_eq(int(a["die"]), 1, "перебрасываем самый слабый провальный куб")
	assert_eq(String(a["currency"]), "concentration")


func test_bot_stops_rerolling_once_passed() -> void:
	_gs.players[BOT]["concentration"] = 2
	_will_check({"rolled": true, "passed": true, "base": [5, 2], "dice": [5, 2]})
	assert_eq(_act()["action"], RelayActions.FINISH_ENCOUNTER, "прошла — фокус бережём")


func test_bot_keeps_clue_reserve() -> void:
	# Улик ровно запас — на переброс не тратит (их ждут Тайны).
	_gs.players[BOT]["clues"] = BotDriver.CLUE_RESERVE
	_will_check({"rolled": true, "passed": false, "base": [2], "dice": [2]})
	assert_eq(_act()["action"], RelayActions.FINISH_ENCOUNTER)
	_gs.players[BOT]["clues"] = BotDriver.CLUE_RESERVE + 1
	var a: Dictionary = _act()
	assert_eq(a["action"], RelayActions.REROLL_ENCOUNTER, "улика сверх запаса — тратит")
	assert_eq(String(a["currency"]), "clue")


func test_bot_does_not_retry_rejected_assist() -> void:
	# Хост отклонил переброс (состояние не сдвинулось) — бот не залипает, а идёт дальше.
	_gs.players[BOT]["concentration"] = 1
	_will_check({"rolled": true, "passed": false, "base": [2], "dice": [2]})
	assert_eq(_act()["action"], RelayActions.REROLL_ENCOUNTER)
	assert_eq(_act()["action"], RelayActions.FINISH_ENCOUNTER, "повтор при том же состоянии — нет")


func test_bot_assists_reckoning_slot() -> void:
	_gs.players[BOT]["items"] = [{"id": "lantern"}]
	_gs.players[BOT]["reckoning_check"] = {
		"owner": "reckoning",
		"pid": BOT,
		"skill": "will",
		"context": "",
		"rolled": false,
		"active_mods": [],
		"exhausted_cards": [],
	}
	var a: Dictionary = _act()
	assert_eq(a["action"], RelayActions.RECKONING_ACTIVATE_CARD, "в слоте Расплаты — свой маршрут")
