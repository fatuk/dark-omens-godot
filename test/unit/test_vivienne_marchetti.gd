## Вивьен Маркетти (Ясновидящая): стартовая «Защита плоти», действие «обмен уликами с
## сыщиком на любой клетке», пассив «Предвидение» (оборот чужого состояния + улика).
extends GutTest

var _nm: Node
var _was_host: bool


func before_each() -> void:
	_nm = get_node("/root/NetworkManager")
	_was_host = bool(_nm.get("_is_host_flag"))
	_nm.set("_is_host_flag", true)
	GameState.reset_session()
	GameState.players = {
		"v": GameState._make_player_dict("v", "V", "Vivienne Marchetti", "5", 4, 8),
		"b": GameState._make_player_dict("b", "B", "Frank Dalton", "Rome", 8, 4),
	}
	GameState.players["v"]["clues"] = 2
	GameState.players["b"]["clues"] = 1
	GameState.players["v"]["actions_left"] = 2
	GameState.turn_order = ["v", "b"]
	GameState.current_idx = 0
	GameState.phase = Phases.ACTION
	GameState.active = true


func after_each() -> void:
	GameState.reset_session()
	_nm.set("_is_host_flag", _was_host)


func test_starts_with_flesh_ward() -> void:
	var items: Array = Investigators.get_data("Vivienne Marchetti").get("startingItems", [])
	assert_has(items, {"spell": "flesh_ward"})


func _link() -> void:
	assert_true(
		GameState._phase.host_apply_action("v", GameActions.INVESTIGATOR_ABILITY, {"partner": "b"})
	)


func test_clue_trade_with_far_investigator() -> void:
	_link()
	assert_eq(int(GameState.players["v"]["actions_left"]), 1, "способность — действие")
	var offer := {"partner": "b", "give": [], "take": [], "giveClues": 2, "takeClues": 0}
	assert_true(GameState._phase.host_apply_trade_offer("v", offer), "Рим далеко — по связи можно")
	assert_false(bool(GameState.trade_offer.get("swap", true)), "местами не меняются")
	assert_true(GameState._phase.host_apply_trade_response("b", true, true))
	assert_eq(int(GameState.players["v"]["clues"]), 0)
	assert_eq(int(GameState.players["b"]["clues"]), 3)
	assert_eq(String(GameState.players["b"]["location"]), "Rome", "swap проигнорирован")
	assert_false(GameState.players["v"].has(PlayerKeys.TRADE_LINK), "связь отыграна")


func test_clue_link_rejects_items() -> void:
	GameState.players["v"]["items"] = [{"id": "38_revolver", "exhausted": false}]
	_link()
	var offer := {"partner": "b", "give": [0], "take": [], "giveClues": 0, "takeClues": 0}
	assert_false(GameState._phase.host_apply_trade_offer("v", offer), "вещи по связи не идут")


func test_foresight_peeks_and_gains_clue_once_per_round() -> void:
	GameState.players["b"]["conditions"] = ["paranoia"]
	GameState._cond.reconcile_backs()
	var v: Dictionary = GameState.players["v"]
	assert_eq(int(v["clues"]), 3, "+1 улика")
	var g: Dictionary = v.get("gains", {})
	assert_eq(String(g.get("card", "")), "paranoia")
	assert_eq(
		String(g.get("card_back", "")),
		String(GameState.players["b"]["conditions_backs"]["paranoia"]),
		"видит именно оборот, закреплённый за картой"
	)
	(GameState.players["b"]["conditions"] as Array).append("amnesia")
	GameState._cond.reconcile_backs()
	assert_eq(int(v["clues"]), 3, "второй раз за раунд — нет")


func test_foresight_skips_common_and_own() -> void:
	GameState.players["b"]["conditions"] = ["debt"]
	GameState.players["v"]["conditions"] = ["paranoia"]
	GameState._cond.reconcile_backs()
	assert_eq(int(GameState.players["v"]["clues"]), 2, "Долг — обычное, своё — не в счёт")
