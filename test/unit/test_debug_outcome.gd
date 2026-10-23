extends GutTest

## Консоль `win` / `lose` / `outcome clear` → DebugGrant.set_outcome: ставит финал
## партии (его ловит OutcomeModal), снимает его и не принимает мусор.


class MockGSOutcome:
	extends Node
	var outcome: String = ""
	var syncs: int = 0

	func broadcast_and_emit() -> void:
		syncs += 1


func test_sets_and_clears_outcome() -> void:
	var gs: MockGSOutcome = autofree(MockGSOutcome.new())
	DebugGrant.set_outcome(gs, "victory")
	assert_eq(gs.outcome, "victory", "победа")
	DebugGrant.set_outcome(gs, "defeat")
	assert_eq(gs.outcome, "defeat", "поражение поверх победы — для повторной проверки")
	DebugGrant.set_outcome(gs, "")
	assert_eq(gs.outcome, "", "снят — партия продолжается")
	assert_eq(gs.syncs, 3, "каждая смена синкается всем")


func test_rejects_unknown_outcome() -> void:
	var gs: MockGSOutcome = autofree(MockGSOutcome.new())
	DebugGrant.set_outcome(gs, "draw")
	assert_eq(gs.outcome, "", "неизвестный исход не ставится")
	assert_eq(gs.syncs, 0, "и не синкается")
