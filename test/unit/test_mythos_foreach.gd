extends GutTest

## Юнит-тесты forEach-прохода фазы Мифов (MythosFlow._run_for_each /
## _run_player_subprogram): порядок сыщиков (Ведущий первым), маршрутизация
## относительных целей через dup-изоляцию, интерактивный per-player выбор ветки
## (резолв через сигнал mythos_decided). Мок-GameState — Node в дереве (нужен
## get_tree() для финального таймера); _target — реальный TargetResolver.

const _TargetResolver = preload("res://scripts/core/game/target_resolver.gd")

var _gs: MockGS
var _mythos: MythosFlow
var _done: bool = false


class StubCond:
	extends RefCounted

	func player_has_constraint(_pid: String, _c: String) -> bool:
		return false


# Стаб доски: forEach-драйвер запрашивает монстров для chosenMonster (здесь — пусто).
class StubBoard:
	extends RefCounted

	func monster_choices() -> Array:
		return []


class MockGS:
	extends Node
	var players: Dictionary = {}
	var turn_order: Array = []
	var current_idx: int = 0
	var mythos_decision: Dictionary = {}
	var locations: Array = []
	var _target: RefCounted
	var _cond := StubCond.new()
	var _board := StubBoard.new()

	signal mythos_decided(idx: int)

	func _is_host() -> bool:
		return true

	func _current_pid() -> String:
		return String(turn_order[current_idx]) if current_idx < turn_order.size() else ""

	func _name_of(pid: String) -> String:
		return pid

	func _load_locations() -> Array:
		return locations

	func _broadcast_sync() -> void:
		pass

	func _emit_changed() -> void:
		pass

	# Зеркало GameState._apply_board_effect: адресные эффекты — через TargetResolver.
	func _apply_board_effect(node: Dictionary) -> void:
		if _target.is_targeted_effect(node):
			_target.apply_targeted_effect(node)


func before_each() -> void:
	_gs = MockGS.new()
	add_child_autofree(_gs)
	_gs._target = _TargetResolver.new(_gs)
	_mythos = MythosFlow.new(_gs)
	_done = false


func _setup_players(ids: Array) -> void:
	for id_v: Variant in ids:
		var pid: String = String(id_v)
		_gs.players[pid] = {
			"hp": 5,
			"hp_max": 7,
			"sanity": 5,
			"sanity_max": 7,
			"clues": 0,
			"items": [],
			"conditions": [],
			"connected": true,
		}
		_gs.turn_order.append(pid)


# Запуск под-программы без await — корутина повиснет на первом выборе.
func _start(pid: String, sub: Array) -> void:
	_run_async(pid, sub)


func _run_async(pid: String, sub: Array) -> void:
	await _mythos._run_player_subprogram(pid, sub)
	_done = true


# ── Порядок прохода ───────────────────────────────────────────────────────────


func test_for_each_pids_lead_first() -> void:
	_setup_players(["p1", "p2", "p3"])
	# p1 = turn_order[0] = Ведущий → первым; только подключённые, в порядке стола.
	assert_eq(_mythos._for_each_pids("each"), ["p1", "p2", "p3"])


# ── Маршрутизация соседа (под-программа без выбора) ───────────────────────────


func test_subprogram_routes_neighbor_effects() -> void:
	_setup_players(["p1", "p2", "p3"])
	_gs.players["p2"]["items"] = [{"id": "a"}, {"id": "b"}]
	var sub: Array = [
		{"do": "loseHealth", "amount": 2, "target": "rightNeighbor"},
		{"do": "loseAllPossessions", "target": "rightNeighbor"},
	]
	await _mythos._run_player_subprogram("p1", sub)
	assert_eq(int(_gs.players["p2"]["hp"]), 3, "сосед справа (p2) −2 HP")
	assert_eq((_gs.players["p2"]["items"] as Array).size(), 0, "и всё имущество p2")
	assert_eq(int(_gs.players["p1"]["hp"]), 5, "якорь p1 не задет")
	assert_eq(int(_gs.players["p3"]["hp"]), 5, "p3 не задет")


# ── Интерактивный выбор ───────────────────────────────────────────────────────


func test_subprogram_choice_branch_b_hits_neighbor() -> void:
	_setup_players(["p1", "p2"])
	_gs.players["p2"]["items"] = [{"id": "a"}]
	var sub: Array = [
		{
			"choice":
			[
				{"do": "gainCondition", "condition": "darkPact", "target": "self"},
				{
					"group":
					[
						{"do": "loseHealth", "amount": 2, "target": "rightNeighbor"},
						{"do": "loseAllPossessions", "target": "rightNeighbor"},
					]
				},
			]
		}
	]
	_start("p1", sub)
	assert_true(bool(_gs.mythos_decision.get("active", false)), "повисли на выборе")
	assert_eq(String(_gs.mythos_decision.get("pid", "")), "p1", "выбор у p1")
	assert_eq((_gs.mythos_decision.get("options", []) as Array).size(), 2, "две ветки")
	_gs.mythos_decided.emit(1)  # ветка B — бьём соседа справа
	await get_tree().create_timer(0.6).timeout  # ждём полного завершения корутины
	assert_true(_done, "под-программа завершилась")
	assert_eq(int(_gs.players["p2"]["hp"]), 3, "сосед справа −2 HP")
	assert_eq((_gs.players["p2"]["items"] as Array).size(), 0, "и всё имущество соседа")
	assert_eq(_gs.mythos_decision, {}, "выбор очищен")


func test_subprogram_choice_branch_a_targets_self() -> void:
	_setup_players(["p1", "p2"])
	var sub: Array = [
		{
			"choice":
			[
				{"do": "gainCondition", "condition": "darkPact", "target": "self"},
				{"do": "loseHealth", "amount": 2, "target": "rightNeighbor"},
			]
		}
	]
	_start("p1", sub)
	_gs.mythos_decided.emit(0)  # ветка A — сам получает Dark Pact
	await get_tree().create_timer(0.6).timeout
	assert_true(_done, "под-программа завершилась")
	assert_true((_gs.players["p1"]["conditions"] as Array).has("darkPact"), "p1 получил darkPact")
	assert_eq(int(_gs.players["p2"]["hp"]), 5, "сосед не задет (выбрана ветка A)")
