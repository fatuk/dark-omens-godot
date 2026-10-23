extends GutTest

## Финал партии: консоль `win` / `lose [причина]` / `outcome clear` →
## DebugGrant.set_outcome; GameOutcome — один финал на партию и выбор концовки
## Древнего по причине (своё поле → «Пробуждение» → общий текст).


class MockGSOutcome:
	extends Node
	var outcome: String = ""
	var outcome_reason: String = ""
	var syncs: int = 0

	func broadcast_and_emit() -> void:
		syncs += 1


func _gs() -> MockGSOutcome:
	return autofree(MockGSOutcome.new())


func test_sets_and_clears_outcome() -> void:
	var gs := _gs()
	DebugGrant.set_outcome(gs, "victory")
	assert_eq(gs.outcome, "victory", "победа")
	assert_eq(gs.outcome_reason, GameOutcome.MYSTERIES, "причина по умолчанию — Тайны")
	DebugGrant.set_outcome(gs, "defeat", GameOutcome.DEAD)
	assert_eq(gs.outcome, "defeat", "поражение поверх победы — для повторной проверки")
	assert_eq(gs.outcome_reason, GameOutcome.DEAD)
	DebugGrant.set_outcome(gs, "defeat")
	assert_eq(gs.outcome_reason, GameOutcome.DOOM, "поражение по умолчанию — Рок")
	DebugGrant.set_outcome(gs, "")
	assert_eq(gs.outcome, "", "снят — партия продолжается")
	assert_eq(gs.outcome_reason, "")
	assert_eq(gs.syncs, 4, "каждая смена синкается всем")


func test_rejects_unknown_outcome_and_reason() -> void:
	var gs := _gs()
	DebugGrant.set_outcome(gs, "draw")
	DebugGrant.set_outcome(gs, "defeat", "boredom")
	assert_eq(gs.outcome, "", "неизвестный исход/причина не ставится")
	assert_eq(gs.syncs, 0, "и не синкается")


func test_finish_only_once() -> void:
	var gs := _gs()
	assert_true(GameOutcome.finish(gs, GameOutcome.DEFEAT, GameOutcome.MYTHOS))
	assert_false(GameOutcome.finish(gs, GameOutcome.VICTORY, GameOutcome.MYSTERIES))
	assert_eq(gs.outcome, "defeat", "первый финал побеждает")
	assert_eq(gs.outcome_reason, GameOutcome.MYTHOS)


func test_ancient_ending_by_reason_with_fallbacks() -> void:
	var ao := {"victory": "V", "awakening": "A", "timeUp": "T"}
	assert_eq(GameOutcome.body_text(ao, "victory", GameOutcome.MYSTERIES), "V")
	assert_eq(GameOutcome.body_text(ao, "defeat", GameOutcome.DOOM), "A")
	assert_eq(GameOutcome.body_text(ao, "defeat", GameOutcome.MYTHOS), "T", "своя концовка")
	assert_eq(GameOutcome.body_text(ao, "defeat", GameOutcome.DEAD), "A", "нет своей → Пробуждение")
	assert_eq(
		GameOutcome.body_text({}, "defeat", GameOutcome.DEAD),
		"OUTCOME_FALLEN_BODY",
		"у Древнего пусто → общий текст причины"
	)
	assert_eq(GameOutcome.body_text({"victory": "  "}, "victory", ""), "OUTCOME_VICTORY_BODY")


func test_title_by_reason() -> void:
	assert_eq(GameOutcome.title_key("victory", GameOutcome.MYSTERIES), "OUTCOME_VICTORY_TITLE")
	assert_eq(GameOutcome.title_key("defeat", GameOutcome.DOOM), "OUTCOME_DEFEAT_TITLE")
	assert_eq(GameOutcome.title_key("defeat", GameOutcome.MYTHOS), "OUTCOME_TIMEUP_TITLE")
	assert_eq(GameOutcome.title_key("defeat", GameOutcome.DEAD), "OUTCOME_FALLEN_TITLE")
	assert_eq(GameOutcome.title_key("defeat", GameOutcome.EFFECT), "OUTCOME_LOST_TITLE")
