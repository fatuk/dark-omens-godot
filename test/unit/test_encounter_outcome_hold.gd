## После «Завершить» встречу ход уходит не сразу: зрители (телеграмма) должны получить
## встречу ЗАФИКСИРОВАННОЙ — с исходом в current_encounter.passed. Раньше фиксация и
## передача хода шли одной рассылкой, и исход до зрителей не доходил вовсе.
extends GutTest

var _nm: Node
var _was_host: bool
var _hold: float


func before_each() -> void:
	_nm = get_node("/root/NetworkManager")
	_was_host = bool(_nm.get("_is_host_flag"))
	_nm.set("_is_host_flag", true)
	_hold = PhaseController.ENCOUNTER_OUTCOME_HOLD
	PhaseController.ENCOUNTER_OUTCOME_HOLD = 0.3  # короткая пауза — окно проверяем сразу
	GameState.reset_session()
	GameState.players = {
		"a": GameState._make_player_dict("a", "A", "Frank Dalton", "5", 5, 5),
		"b": GameState._make_player_dict("b", "B", "Frank Dalton", "5", 5, 5),
	}
	GameState.turn_order = ["a", "b"]
	GameState.current_idx = 0
	GameState.phase = Phases.ENCOUNTER
	GameState.active = true


func after_each() -> void:
	PhaseController.ENCOUNTER_OUTCOME_HOLD = _hold
	GameState.reset_session()  # отложенная передача хода увидит чужое состояние и выйдет
	_nm.set("_is_host_flag", _was_host)


func test_finished_encounter_stays_visible_before_turn_passes() -> void:
	# Карта без проверки («Почтовый самолёт»): исход — успех, эффекты onSuccess.
	GameState.current_encounter = {"kind": "general", "name": "Почтовый самолёт", "onSuccess": []}
	assert_true(GameState._phase.host_apply_finish_encounter("a"), "встреча завершена")
	assert_true(bool(GameState.current_encounter.get("committed", false)), "зафиксирована")
	assert_true(bool(GameState.current_encounter.get("passed", false)), "исход — успех")
	assert_eq(GameState.current_pid(), "a", "ход ещё не ушёл — зрители видят исход")
	assert_true(bool(GameState.players["a"]["encounter_done"]), "а встреча сыщика закрыта")
	# Дать отложенной передаче хода отработать: фаза сменилась — она выходит, ничего
	# не трогая (и не висит таймером после теста).
	GameState.phase = Phases.MYTHOS
	await wait_seconds(0.5)
	assert_eq(GameState.current_pid(), "a", "после смены фазы ход не передан")


func test_hold_follows_outcome_text_length() -> void:
	PhaseController.ENCOUNTER_OUTCOME_HOLD = 2.5
	var enc: Dictionary = {"kind": "general", "passed": false, "successText": "Да."}
	enc["failureText"] = "Ж".repeat(90)  # 90 знаков при 18/с — 5 с
	assert_almost_eq(PhaseController.outcome_hold(enc), 5.0, 0.01, "читаем выпавший исход")
	enc["passed"] = true
	assert_eq(PhaseController.outcome_hold(enc), 2.5, "короткий — минимум")
	enc["successText"] = "Ж".repeat(1000)
	assert_eq(
		PhaseController.outcome_hold(enc),
		PhaseController.ENCOUNTER_OUTCOME_HOLD_MAX,
		"длинный — потолок"
	)


# «Находка в борозде»: без проверки, «можете потратить 1 улику: артефакт».
func _offer_card() -> Dictionary:
	return {
		"kind": "general",
		"name": "Находка в борозде",
		"successText": "…и он с облегчением отдаёт вам находку.",
		"onSuccess":
		[
			{
				"do": "gainArtifact",
				"optional": true,
				"cost": {"spend": "clue", "amount": 1},
			}
		],
	}


func test_offer_unaffordable_is_declined() -> void:
	# Улик нет — предложение отсечено ценой, ничего не взято: исход «ни с чем».
	GameState.players["a"]["clues"] = 0
	GameState.current_encounter = _offer_card()
	assert_true(GameState._phase.host_apply_finish_encounter("a"), "встреча завершена")
	assert_true(EncounterFlow.declined(GameState.current_encounter), "платить нечем — отказ")
	GameState.phase = Phases.MYTHOS
	await wait_seconds(0.5)


func test_offer_skipped_is_declined() -> void:
	GameState.players["a"]["clues"] = 1
	GameState.current_encounter = _offer_card()
	GameState._phase.host_apply_finish_encounter("a")
	assert_false(
		(GameState.current_encounter.get("pending_choice", {}) as Dictionary).is_empty(),
		"улика есть — выбор «взять / пропустить»"
	)
	GameState._phase.host_apply_effect_choice("a", 1)  # пропустить
	assert_true(bool(GameState.current_encounter.get("committed", false)))
	assert_true(EncounterFlow.declined(GameState.current_encounter), "пропустил — отказ")
	assert_eq(int(GameState.players["a"]["clues"]), 1, "улика не потрачена")
	GameState.phase = Phases.MYTHOS
	await wait_seconds(0.5)


func test_offer_taken_is_not_declined() -> void:
	GameState.players["a"]["clues"] = 1
	GameState.current_encounter = _offer_card()
	GameState._phase.host_apply_finish_encounter("a")
	GameState._phase.host_apply_effect_choice("a", 0)  # заплатить
	assert_eq(int(GameState.players["a"]["clues"]), 0, "улика потрачена")
	assert_false(EncounterFlow.declined(GameState.current_encounter), "взял — флейвор успеха")
	GameState.phase = Phases.MYTHOS
	await wait_seconds(0.5)


func test_offer_affordability() -> void:
	var offers: Array = EncounterFlow.offer_nodes(_offer_card()["onSuccess"])
	assert_eq(offers.size(), 1, "optional-узел — предложение")
	assert_false(EncounterFlow.can_afford_offer(offers, {"clues": 0}))
	assert_true(EncounterFlow.can_afford_offer(offers, {"clues": 2}))
	assert_true(EncounterFlow.offer_nodes([{"do": "gainClue"}]).is_empty(), "без optional — нет")


func test_linked_trade_remote_without_action_and_swap() -> void:
	# «Мозг ми-го в банке»: связь a→b; они на разных клетках, действий у a не осталось.
	GameState.phase = Phases.ACTION
	GameState.players["a"]["location"] = "arkham"
	GameState.players["b"]["location"] = "tokyo"
	GameState.players["a"]["actions_left"] = 0
	GameState.players["a"]["items"] = [{"id": "18_derringer", "exhausted": false}]
	GameState.players["a"]["trade_link"] = "b"
	var b_had: int = (GameState.players["b"].get("items", []) as Array).size()
	var offer: Dictionary = {"partner": "b", "give": [0], "take": [], "giveClues": 0}
	assert_true(GameState._phase.host_apply_trade_offer("a", offer), "обмен на расстоянии")
	assert_true(bool(GameState.trade_offer.get("link", false)), "партнёру — галка мест")
	assert_true(GameState._phase.host_apply_trade_response("b", true, true))
	assert_eq((GameState.players["b"]["items"] as Array).size(), b_had + 1, "предмет у партнёра")
	assert_eq(String(GameState.players["b"]["location"]), "arkham", "партнёр пришёл к a")
	assert_eq(String(GameState.players["a"]["location"]), "tokyo", "a — на его место")
	assert_false(GameState.players["a"].has("trade_link"), "связь отыграна")


func test_trade_without_link_still_needs_same_space() -> void:
	GameState.phase = Phases.ACTION
	GameState.players["a"]["location"] = "arkham"
	GameState.players["b"]["location"] = "tokyo"
	GameState.players["a"]["actions_left"] = 2
	var offer: Dictionary = {"partner": "b", "give": [], "take": [], "giveClues": 0}
	assert_false(GameState._phase.host_apply_trade_offer("a", offer), "без связи — только рядом")
