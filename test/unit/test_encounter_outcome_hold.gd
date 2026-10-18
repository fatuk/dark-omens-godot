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
