extends GutTest

## Юнит-тесты RumorFlow (scripts/core/game/rumor_flow.gd) — жизненный цикл Слуха:
##   • on_enter: открыть врата-портал, инициализировать счётчик жетонов, запомнить локацию;
##   • reckon: тик жетонов вниз; на нуле — Рок +1 за каждые врата на поле;
##   • solve_on_gate_close: закрытие врат на локации портала развеивает ИМЕННО тот Слух.
## _gs — лёгкий мок (board.open_gate / gates / mythos_in_play / _apply_board_effect / doom).


class MockBoard:
	extends RefCounted
	var _gs: Node
	var next_loc: String = "portalLoc"  # что вернёт open_gate (или "" — нет гейт-локаций)

	func _init(gs: Node) -> void:
		_gs = gs

	func open_gate(_loc: String = "", _color: String = "") -> String:
		if next_loc.is_empty():
			return ""
		_gs.gates[next_loc] = "green"
		return next_loc


class MockGS:
	extends Node
	var gates: Dictionary = {}
	var mythos_in_play: Array = []
	var doom: int = 0
	var _board: MockBoard

	func _init() -> void:
		_board = MockBoard.new(self)

	func _is_host() -> bool:
		return true

	func _apply_board_effect(node: Dictionary) -> void:
		if String(node.get("do", "")) == "advanceDoom":
			doom += int(node.get("amount", 0))


var _gs: MockGS
var _rumor: RumorFlow


func before_each() -> void:
	_gs = autofree(MockGS.new())
	_rumor = RumorFlow.new(_gs)


func _rumor_card(tokens: int, name: String = "Слух") -> Dictionary:
	return {"name": name, "subtype": "rumor", "rumor": {"tokens": tokens}}


func test_is_rumor() -> void:
	assert_true(_rumor.is_rumor(_rumor_card(3)), "карта с блоком rumor — Слух")
	assert_false(_rumor.is_rumor({"name": "Обычный Миф", "onDraw": []}), "без rumor — не Слух")


func test_on_enter_inits_tokens_and_opens_portal() -> void:
	var card: Dictionary = _rumor_card(3)
	_rumor.on_enter(card)
	assert_eq(int(card.get("tokens", -1)), 3, "счётчик жетонов = rumor.tokens")
	assert_eq(String(card.get("rumorLocation", "")), "portalLoc", "локация портала записана")
	assert_true(_gs.gates.has("portalLoc"), "врата-портал открыты на локации")


func test_on_enter_no_gate_location_records_empty() -> void:
	_gs._board.next_loc = ""  # нет свободных гейт-локаций
	var card: Dictionary = _rumor_card(2)
	_rumor.on_enter(card)
	assert_eq(String(card.get("rumorLocation", "x")), "", "пустая локация портала")
	assert_eq(int(card.get("tokens", -1)), 2, "счётчик всё равно инициализирован")


func test_reckon_ticks_tokens_down() -> void:
	var card: Dictionary = _rumor_card(2)
	_rumor.on_enter(card)
	_rumor.reckon(card)
	assert_eq(int(card["tokens"]), 1, "первый тик: 2→1")
	_rumor.reckon(card)
	assert_eq(int(card["tokens"]), 0, "второй тик: 1→0")
	assert_eq(_gs.doom, 0, "пока жетоны были — Рок не растёт")


func test_reckon_at_zero_advances_doom_per_gate() -> void:
	var card: Dictionary = _rumor_card(0)
	_gs.gates = {"a": "green", "b": "red", "c": "blue"}  # 3 врат на поле
	_rumor.reckon(card)
	assert_eq(_gs.doom, 3, "на нуле жетонов — Рок +1 за каждые врата (3)")
	_rumor.reckon(card)
	assert_eq(_gs.doom, 6, "каждая Расплата на нуле снова +3")


func test_reckon_at_zero_no_gates_no_doom() -> void:
	var card: Dictionary = _rumor_card(0)
	_gs.gates = {}
	_rumor.reckon(card)
	assert_eq(_gs.doom, 0, "нет врат — Рок не растёт")


func test_solve_on_gate_close_removes_matching_rumor_only() -> void:
	var r1: Dictionary = _rumor_card(1, "Слух-1")
	r1["rumorLocation"] = "loc1"
	var r2: Dictionary = _rumor_card(1, "Слух-2")
	r2["rumorLocation"] = "loc2"
	_gs.mythos_in_play = [r1, r2]
	_rumor.solve_on_gate_close("loc1", "p1")
	assert_eq(_gs.mythos_in_play.size(), 1, "развеян ровно один Слух")
	assert_eq(
		String((_gs.mythos_in_play[0] as Dictionary).get("name", "")), "Слух-2", "остался Слух-2"
	)


func test_solve_on_gate_close_ignores_unrelated_location() -> void:
	var r1: Dictionary = _rumor_card(1, "Слух-1")
	r1["rumorLocation"] = "loc1"
	_gs.mythos_in_play = [r1]
	_rumor.solve_on_gate_close("elsewhere", "p1")
	assert_eq(_gs.mythos_in_play.size(), 1, "врата не на портале — Слух остаётся")
