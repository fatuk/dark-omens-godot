extends GutTest

## Юнит-тесты шага Расплаты (ReckoningFlow): глобальные тиры (Древний/карты Мифов/
## монстры), фильтр scope, сбор карт Расплаты сыщика, обход сыщиков. Флип состояний
## застаблен (StubCond) ради детерминизма. _target — реальный TargetResolver; board-
## эффекты применяет mock (advanceDoom → doom; адресные → TargetResolver).

const _TargetResolver = preload("res://scripts/core/game/target_resolver.gd")

var _gs: MockGS
var _r: ReckoningFlow
var _done: bool = false


class StubCond:
	extends RefCounted
	var reckoned: Array = []  # [{pid, cid}]

	func reckon_condition(pid: String, cid: String, _flow: Dictionary = {}) -> void:
		reckoned.append({"pid": pid, "cid": cid})


class MockGS:
	extends Node
	var host: bool = true
	var campaign: Dictionary = {}
	var mythos_in_play: Array = []
	var monsters: Dictionary = {}
	var players: Dictionary = {}
	var turn_order: Array = []
	var doom: int = 0
	var locations: Array = []
	var mythos_decision: Dictionary = {}
	var _target: RefCounted
	var _cond := StubCond.new()

	signal mythos_decided(idx: int)

	func _is_host() -> bool:
		return host

	func _current_pid() -> String:
		return ""

	func _name_of(pid: String) -> String:
		return pid

	func _load_locations() -> Array:
		return locations

	func _broadcast_sync() -> void:
		pass

	func _emit_changed() -> void:
		pass

	# Зеркало GameState._apply_board_effect (минимум для теста): адресные — через
	# TargetResolver; advanceDoom — в счётчик doom.
	func _apply_board_effect(node: Dictionary) -> void:
		if _target.is_targeted_effect(node):
			_target.apply_targeted_effect(node)
		elif String(node.get("do", "")) == "advanceDoom":
			doom += int(node.get("amount", node.get("count", 1)))


func before_each() -> void:
	_gs = autofree(MockGS.new())
	add_child(_gs)
	_gs._target = _TargetResolver.new(_gs)
	_r = ReckoningFlow.new(_gs)


func _player(pid: String, extra: Dictionary = {}) -> void:
	var base: Dictionary = {
		"hp": 5,
		"hp_max": 7,
		"sanity": 5,
		"sanity_max": 7,
		"clues": 0,
		"items": [],
		"conditions": [],
		"conditions_flipped": {},
		"connected": true,
		"investigator": "",
	}
	for k_v: Variant in extra:
		base[k_v] = extra[k_v]
	_gs.players[pid] = base
	_gs.turn_order.append(pid)


func test_run_reckoning_global_tiers() -> void:
	_gs.campaign = {"ancientOne": "azathoth"}  # onReckoning: advanceDoom 1
	_gs.mythos_in_play = [{"name": "X", "onReckoning": [{"do": "advanceDoom", "amount": 1}]}]
	_gs.monsters = {"loc": [{"id": "avian_thrall"}]}  # onReckoning: loseSanity 1 each
	_player("p1")
	_player("p2")
	await _r.run_reckoning("")
	assert_eq(_gs.doom, 2, "Древний (+1) + карта Мифов в игре (+1)")
	assert_eq(int(_gs.players["p1"]["sanity"]), 4, "монстр: −1 рассудок каждому")
	assert_eq(int(_gs.players["p2"]["sanity"]), 4)


func test_run_reckoning_scope_mythos_only() -> void:
	_gs.campaign = {"ancientOne": "azathoth"}
	_gs.mythos_in_play = [{"name": "X", "onReckoning": [{"do": "advanceDoom", "amount": 1}]}]
	_gs.monsters = {"loc": [{"id": "avian_thrall"}]}
	_player("p1")
	await _r.run_reckoning("mythosInPlay")
	assert_eq(_gs.doom, 1, "только карта Мифов в игре (+1); Древний не сработал")
	assert_eq(int(_gs.players["p1"]["sanity"]), 5, "монстр не сработал")


func test_mythos_in_play_skips_trigger_node() -> void:
	# onReckoning с триггером resolveReckoning + эффектом — триггер отбрасывается.
	_gs.mythos_in_play = [
		{
			"name": "X",
			"onReckoning": [{"do": "resolveReckoning"}, {"do": "advanceDoom", "amount": 1}],
		}
	]
	await _r.run_reckoning("mythosInPlay")
	assert_eq(_gs.doom, 1, "эффект применён, триггер resolveReckoning пропущен (без рекурсии)")


func test_mythos_card_self_discards() -> void:
	# Карта A: эффект + discardCard → применяется и уходит из игры. Карта B остаётся.
	_gs.mythos_in_play = [
		{"name": "A", "onReckoning": [{"do": "advanceDoom", "amount": 1}, {"do": "discardCard"}]},
		{"name": "B", "onReckoning": [{"do": "advanceDoom", "amount": 1}]},
	]
	await _r.run_reckoning("mythosInPlay")
	assert_eq(_gs.doom, 2, "обе карты применили эффект (+1 каждая)")
	assert_eq((_gs.mythos_in_play as Array).size(), 1, "карта A сброшена, B осталась")
	assert_eq(String((_gs.mythos_in_play[0] as Dictionary).get("name", "")), "B")


func test_collect_reckoning_cards() -> void:
	_player(
		"p1", {"conditions": ["debt"], "items": [{"id": "conspiracy_theorist", "exhausted": false}]}
	)
	var cards: Array = _r._collect_reckoning_cards("p1")
	assert_eq(cards.size(), 2, "состояние с onReckoning + актив с effect.onReckoning")
	var kinds: Array = []
	for c_v: Variant in cards:
		kinds.append(String((c_v as Dictionary).get("kind", "")))
	assert_true(kinds.has("condition"), "есть карта-состояние")
	assert_true(kinds.has("asset"), "есть карта-актив")


func test_collect_skips_flipped_condition() -> void:
	_player("p1", {"conditions": ["debt"], "conditions_flipped": {"debt": "x"}})
	assert_eq(_r._collect_reckoning_cards("p1").size(), 0, "перевёрнутое состояние не берём")


func test_investigator_single_condition_auto() -> void:
	_player("p1", {"conditions": ["debt"]})  # одна карта — без выбора порядка
	await _r.run_reckoning("")
	assert_eq(
		(_gs._cond.reckoned as Array).size(), 1, "единственное состояние разрешено без выбора"
	)


# Фоновый запуск Расплаты — повиснет на первом выборе порядка.
func _run_async(scope: String) -> void:
	_done = false
	await _r.run_reckoning(scope)
	_done = true


func test_investigator_ordering_resolves_chosen_first() -> void:
	_player("p1", {"conditions": ["debt", "darkPact"]})  # 2 карты → выбор порядка
	_run_async("")
	assert_true(bool(_gs.mythos_decision.get("active", false)), "повисли на выборе порядка")
	assert_eq(String(_gs.mythos_decision.get("pid", "")), "p1")
	assert_eq((_gs.mythos_decision.get("options", []) as Array).size(), 2, "две карты Расплаты")
	_gs.mythos_decided.emit(1)  # выбрал вторую (darkPact) первой
	await get_tree().create_timer(1.0).timeout  # дать корутине доиграть оба резолва
	assert_true(_done, "Расплата сыщика завершилась")
	assert_eq((_gs._cond.reckoned as Array).size(), 2, "оба состояния разрешены")
	assert_eq(
		String((_gs._cond.reckoned[0] as Dictionary).get("cid", "")),
		"darkPact",
		"выбранное — первым"
	)
