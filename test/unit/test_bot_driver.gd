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
	assert_eq(_act()["type"], GameActions.REST, "ранен — отдых")


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
