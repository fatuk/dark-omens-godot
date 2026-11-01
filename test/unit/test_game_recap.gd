extends GutTest

## Итоги партии (scripts/core/game/game_recap.gd): счётчики из ленты действий,
## вехи из стейта (гибель, решённые Тайны) и сброс между партиями.

var _gs: Mock
var _r: GameRecap


class Mock:
	extends "res://test/unit/helpers/mock_game_state.gd"
	var active: bool = true
	var outcome: String = ""
	var round_num: int = 1
	var active_mystery: int = 0
	var doom: int = 3


func before_each() -> void:
	_gs = autofree(Mock.new())
	_gs.players = {
		"me": {"name": "Аня", "investigator": "Frank Dalton"},
		"bot-1": {"name": "Механический Турок", "investigator": "Ada Fairfax"},
	}
	_gs.turn_order = ["me", "bot-1"]
	_gs.campaign = {"doomClock": 15, "mysteries": [{"title": "А"}, {"title": "Б"}, {"title": "В"}]}
	_r = GameRecap.new()
	_r.observe(_gs, 0)  # партия началась


func _row(s: Dictionary, pid: String) -> Dictionary:
	for r_v: Variant in s["players"]:
		if String((r_v as Dictionary)["pid"]) == pid:
			return r_v
	return {}


func test_counts_feed_actions() -> void:
	_r.on_action("me", "combat_won", {"monster": "MON_X"})
	_r.on_action("me", "combat_lost", {})
	_r.on_action("me", "hurt", {"amount": "2"})
	_r.on_action("me", "sanity_hit", {"amount": "1"})
	_r.on_action("me", "got_clue", {"amount": "2"})
	_r.on_action("me", "got_clue", {})  # старый формат без amount — 1
	_r.on_action("me", "research", {})
	_r.on_action("me", "gate", {})
	_r.on_action("me", "travel", {"place": "LOC_X"})
	_r.on_action("me", "cast_spell", {})
	var st: Dictionary = _row(_r.summary(_gs, 0), "me")["stats"]
	assert_eq(st["kills"], 1)
	assert_eq(st["wounds"], 3, "урон + ужас")
	assert_eq(st["clues"], 3)
	assert_eq(st["encounters"], 2)
	assert_eq(st["travels"], 1)
	assert_eq(st["spells"], 1)


func test_marks_bots_and_order() -> void:
	var rows: Array = _r.summary(_gs, 0)["players"]
	assert_eq(rows.map(func(r: Dictionary) -> String: return r["pid"]), ["me", "bot-1"])
	assert_false(_row(_r.summary(_gs, 0), "me")["bot"])
	assert_true(_row(_r.summary(_gs, 0), "bot-1")["bot"])


func test_tracks_fallen_round_and_solved_mysteries() -> void:
	_gs.round_num = 3
	_gs.active_mystery = 1
	_r.observe(_gs, 1000)
	_gs.round_num = 5
	_gs.players["bot-1"]["dead"] = true
	_r.observe(_gs, 2000)
	_gs.round_num = 6
	_r.observe(_gs, 3000)  # гибель не переписывается следующими снапшотами
	var s: Dictionary = _r.summary(_gs, 3000)
	assert_eq(_row(s, "bot-1")["fell_round"], 5)
	assert_true(_row(s, "bot-1")["dead"])
	assert_eq(s["mysteries_solved"], 1)
	assert_eq(s["mysteries_total"], 3)
	assert_eq(
		s["moments"],
		[
			{"round": 3, "kind": "mystery", "index": 0},
			{"round": 5, "kind": "fallen", "pid": "bot-1"},
		]
	)


func test_minutes_freeze_at_outcome() -> void:
	_r.observe(_gs, 1)  # уже идёт с t=0
	_gs.outcome = "defeat"
	_r.observe(_gs, 25 * 60000)
	assert_eq(
		_r.summary(_gs, 90 * 60000)["minutes"], 25, "время — до финала, а не до открытия итогов"
	)
	assert_eq(_r.summary(_gs, 0)["doom_clock"], 15)


func test_new_game_resets() -> void:
	_r.on_action("me", "combat_won", {})
	_gs.active = false  # вернулись в лобби
	_r.observe(_gs, 10)
	_gs.active = true
	_r.observe(_gs, 20)  # новая партия
	assert_eq(_row(_r.summary(_gs, 20), "me")["stats"]["kills"], 0)
