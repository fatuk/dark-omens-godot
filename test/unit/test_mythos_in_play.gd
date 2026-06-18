extends GutTest

## Юнит-тесты учёта ongoing-карт Мифов (MythosFlow._register_in_play / _has_ongoing):
## карта с whileInPlay/onReckoning-эффектом остаётся в игре, чистые event/триггер — нет.

var _gs: MockGS
var _m: MythosFlow


class MockGS:
	extends Node
	var mythos_in_play: Array = []
	var _rumor: RumorFlow

	func _init() -> void:
		_rumor = RumorFlow.new(self)


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
