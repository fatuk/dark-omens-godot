extends GutTest

## Юнит-тесты учёта ongoing-карт Мифов (MythosFlow._register_in_play / _has_ongoing):
## карта с whileInPlay/onReckoning-эффектом остаётся в игре, чистые event/триггер — нет.

var _gs: MockGS
var _m: MythosFlow


class MockGS:
	extends Node
	var mythos_in_play: Array = []
	var _rumor: RumorFlow
	# Поля/стабы для гейта «Прочитал» (mark_read/_all_read).
	var phase: String = Phases.MYTHOS
	var current_mythos: Dictionary = {"name": "Card"}
	var players: Dictionary = {}
	var mythos_read: Array = []
	var host: bool = true

	func _init() -> void:
		_rumor = RumorFlow.new(self)

	func _is_host() -> bool:
		return host

	func _broadcast_sync() -> void:
		pass

	func _emit_changed() -> void:
		pass


func before_each() -> void:
	_gs = autofree(MockGS.new())
	_m = MythosFlow.new(_gs)


func test_ongoing_reckoning_card_registered() -> void:
	_m._register_in_play({"name": "Bad Karma", "onReckoning": [{"dieRoll": []}]})
	assert_eq((_gs.mythos_in_play as Array).size(), 1, "карта с onReckoning-эффектом — в игре")


func test_while_in_play_card_registered() -> void:
	_m._register_in_play({"name": "Aura", "whileInPlay": [{"do": "cannotRecover"}]})
	assert_eq((_gs.mythos_in_play as Array).size(), 1, "карта с whileInPlay — в игре")


func test_pure_trigger_card_not_registered() -> void:
	_m._register_in_play({"name": "Trigger", "onReckoning": [{"do": "resolveReckoning"}]})
	assert_eq(
		(_gs.mythos_in_play as Array).size(), 0, "только триггер resolveReckoning — не в игре"
	)


func test_event_card_not_registered() -> void:
	_m._register_in_play({"name": "Event", "onDraw": [{"do": "gainClue", "count": 1}]})
	assert_eq((_gs.mythos_in_play as Array).size(), 0, "чистый event — не в игре")


func test_dedup_by_name() -> void:
	var c: Dictionary = {"name": "Bad Karma", "onReckoning": [{"dieRoll": []}]}
	_m._register_in_play(c)
	_m._register_in_play(c)
	assert_eq((_gs.mythos_in_play as Array).size(), 1, "повтор той же карты не дублируется")


# ── Гейт «Прочитал»: миф резолвится только когда отметились все ────────────────


func test_read_gate_partial_does_not_resolve() -> void:
	_gs.players = {"p1": {"connected": true}, "p2": {"connected": true}}
	_gs.current_mythos = {"name": "Card"}
	_gs.mythos_read = []
	_m.mark_read("p1")
	assert_eq(_gs.mythos_read, ["p1"], "p1 отмечен прочитавшим")
	assert_false(_gs.current_mythos.is_empty(), "карта НЕ резолвится — p2 ещё не прочитал")
	assert_false(_m._all_read(), "не все прочитали")


func test_read_gate_no_duplicate_marks() -> void:
	_gs.players = {"p1": {"connected": true}, "p2": {"connected": true}}
	_gs.mythos_read = []
	_m.mark_read("p1")
	_m.mark_read("p1")
	assert_eq((_gs.mythos_read as Array).size(), 1, "повторное «Прочитал» не копит дубли")


func test_read_gate_ignores_disconnected() -> void:
	_gs.players = {"p1": {"connected": true}, "p2": {"connected": false}}
	_gs.mythos_read = ["p1"]
	assert_true(_m._all_read(), "отключённый p2 не блокирует — все подключённые прочитали")


func test_read_gate_ignores_unknown_pid() -> void:
	_gs.players = {"p1": {"connected": true}}
	_gs.mythos_read = []
	_m.mark_read("ghost")  # нет в players — игнор
	assert_true((_gs.mythos_read as Array).is_empty(), "чужой pid не отмечается")
