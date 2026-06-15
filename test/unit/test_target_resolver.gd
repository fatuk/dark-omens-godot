extends GutTest

## Юнит-тесты адресных эффектов (scripts/core/game/target_resolver.gd): роутинг
## target (lead/each/eachOn*/chosenInvestigator), применение verb'а к целям,
## передачи give* между сыщиками. Детерминировано. _EffectRunner реален (применяет
## игровые verb'ы к словарю игрока); мок GameState даёт players/turn_order/локации.

var _gs: MockGameState
var _t: TargetResolver


class MockGameState:
	extends Node
	var players: Dictionary = {}
	var turn_order: Array = []
	var current_idx: int = 0
	var locations: Array = []

	func _current_pid() -> String:
		return String(turn_order[current_idx]) if current_idx < turn_order.size() else ""

	func _name_of(pid: String) -> String:
		return pid

	func _load_locations() -> Array:
		return locations


func before_each() -> void:
	_gs = autofree(MockGameState.new())
	_t = TargetResolver.new(_gs)


func _player(pid: String, extra: Dictionary = {}) -> void:
	var base: Dictionary = {
		"hp": 5, "hp_max": 7, "clues": 0, "items": [], "location": "", "connected": true
	}
	for k_v: Variant in extra:
		base[k_v] = extra[k_v]
	_gs.players[pid] = base
	if not (_gs.turn_order as Array).has(pid):
		_gs.turn_order.append(pid)


# ── is_targeted_effect ────────────────────────────────────────────────────────


func test_give_verbs_are_targeted() -> void:
	assert_true(_t.is_targeted_effect({"do": "giveClue"}))
	assert_true(_t.is_targeted_effect({"do": "giveAsset"}))


func test_self_and_empty_target_not_targeted() -> void:
	assert_false(_t.is_targeted_effect({"do": "loseHealth", "target": "self"}))
	assert_false(_t.is_targeted_effect({"do": "loseHealth"}), "без target — не адресный")


func test_player_verb_with_target_is_targeted() -> void:
	assert_true(_t.is_targeted_effect({"do": "loseHealth", "target": "lead"}))


func test_non_player_verb_not_targeted() -> void:
	assert_false(
		_t.is_targeted_effect({"do": "advanceDoom", "target": "each"}), "board-verb — не адресный"
	)


# ── _resolve_targets ──────────────────────────────────────────────────────────


func test_resolve_lead() -> void:
	_player("p1")
	_player("p2")
	assert_eq(_t._resolve_targets({"target": "lead"}), ["p1"], "lead → turn_order[0]")


func test_resolve_each_connected() -> void:
	_player("p1")
	_player("p2", {"connected": false})
	_player("p3")
	assert_eq(_t._resolve_targets({"target": "each"}), ["p1", "p3"], "each → только подключённые")


func test_resolve_each_on_city() -> void:
	_gs.locations = [{"id": "ark", "type": "city"}, {"id": "sea1", "type": "sea"}]
	_player("p1", {"location": "ark"})
	_player("p2", {"location": "sea1"})
	assert_eq(_t._resolve_targets({"target": "eachOnCity"}), ["p1"], "только в городе")


func test_resolve_chosen_investigator() -> void:
	_player("p1")
	_player("p2")
	assert_eq(_t._resolve_targets({"target": "chosenInvestigator", "_target_pid": "p2"}), ["p2"])


func test_resolve_chosen_unknown_is_empty() -> void:
	_player("p1")
	assert_eq(_t._resolve_targets({"target": "chosenInvestigator", "_target_pid": "ghost"}), [])


func test_resolve_default_is_active() -> void:
	_player("p1")
	_player("p2")
	_gs.current_idx = 1  # активный p2
	assert_eq(_t._resolve_targets({}), ["p2"], "без target → активный игрок")


func test_loc_type_of_unknown_is_empty() -> void:
	_gs.locations = [{"id": "ark", "type": "city"}]
	assert_eq(_t._loc_type_of("ark"), "city")
	assert_eq(_t._loc_type_of("nope"), "", "неизвестная локация → пусто")


# ── относительные соседи ──────────────────────────────────────────────────────


func test_resolve_right_neighbor_from_active() -> void:
	_player("p1")
	_player("p2")
	_player("p3")
	# активный p1 (якорь по умолчанию) → сосед по часовой p2
	assert_eq(_t._resolve_targets({"target": "rightNeighbor"}), ["p2"])


func test_resolve_left_neighbor_wraps() -> void:
	_player("p1")
	_player("p2")
	_player("p3")
	# активный p1 → сосед против часовой p3 (wrap назад)
	assert_eq(_t._resolve_targets({"target": "leftNeighbor"}), ["p3"])


func test_resolve_neighbor_from_explicit_anchor() -> void:
	_player("p1")
	_player("p2")
	_player("p3")
	assert_eq(_t._resolve_targets({"target": "rightNeighbor", "_anchor_pid": "p2"}), ["p3"])
	assert_eq(_t._resolve_targets({"target": "leftNeighbor", "_anchor_pid": "p1"}), ["p3"])


func test_resolve_neighbor_skips_disconnected() -> void:
	_player("p1")
	_player("p2", {"connected": false})
	_player("p3")
	# подключённые [p1, p3]; сосед справа от p1 = p3 (отключённый p2 пропущен)
	assert_eq(_t._resolve_targets({"target": "rightNeighbor", "_anchor_pid": "p1"}), ["p3"])


func test_resolve_neighbor_single_player_empty() -> void:
	_player("p1")
	assert_eq(_t._resolve_targets({"target": "rightNeighbor"}), [], "один игрок — соседа нет")


func test_apply_lose_all_possessions_to_right_neighbor() -> void:
	_player("p1")
	_player("p2", {"items": [{"id": "a"}, {"id": "b"}]})
	_player("p3", {"items": [{"id": "c"}]})
	_t.apply_targeted_effect(
		{"do": "loseAllPossessions", "target": "rightNeighbor", "_anchor_pid": "p1"}
	)
	assert_eq(
		(_gs.players["p2"]["items"] as Array).size(), 0, "сосед справа (p2) — инвентарь очищен"
	)
	assert_eq((_gs.players["p3"]["items"] as Array).size(), 1, "p3 не задет")


# ── apply_targeted_effect (игровой verb к целям) ──────────────────────────────


func test_apply_player_verb_to_each() -> void:
	_player("p1")
	_player("p2")
	_t.apply_targeted_effect({"do": "loseHealth", "target": "each", "amount": 1})
	assert_eq(int(_gs.players["p1"]["hp"]), 4)
	assert_eq(int(_gs.players["p2"]["hp"]), 4)


func test_apply_respects_times() -> void:
	_player("p1")
	_t.apply_targeted_effect({"do": "loseHealth", "target": "lead", "amount": 1, "_times": 2})
	assert_eq(int(_gs.players["p1"]["hp"]), 3, "_times=2 → −2 здоровья")


func test_apply_to_lead_only() -> void:
	_player("p1")
	_player("p2")
	_t.apply_targeted_effect({"do": "loseHealth", "target": "lead", "amount": 1})
	assert_eq(int(_gs.players["p1"]["hp"]), 4, "ведущий задет")
	assert_eq(int(_gs.players["p2"]["hp"]), 5, "остальные нетронуты")


# ── _apply_give (передачи между сыщиками) ─────────────────────────────────────


func test_give_clue_transfers() -> void:
	_player("p1", {"clues": 3})
	_player("p2", {"clues": 0})
	_t._apply_give("giveClue", {"count": 2}, "p2")
	assert_eq(int(_gs.players["p1"]["clues"]), 1, "у источника списано")
	assert_eq(int(_gs.players["p2"]["clues"]), 2, "получателю передано")


func test_give_clue_capped_by_available() -> void:
	_player("p1", {"clues": 1})
	_player("p2", {"clues": 0})
	_t._apply_give("giveClue", {"count": 5}, "p2")
	assert_eq(int(_gs.players["p1"]["clues"]), 0, "отдал всё что было")
	assert_eq(int(_gs.players["p2"]["clues"]), 1)


func test_give_clue_zero_available_noop() -> void:
	_player("p1", {"clues": 0})
	_player("p2", {"clues": 0})
	_t._apply_give("giveClue", {"count": 2}, "p2")
	assert_eq(int(_gs.players["p2"]["clues"]), 0, "нечего передавать")


func test_give_asset_transfers_one_item() -> void:
	_player("p1", {"items": [{"id": "a"}, {"id": "b"}]})
	_player("p2", {"items": []})
	_t._apply_give("giveAsset", {}, "p2")
	assert_eq((_gs.players["p1"]["items"] as Array).size(), 1, "у источника на 1 меньше")
	assert_eq((_gs.players["p2"]["items"] as Array).size(), 1, "получателю передан предмет")


func test_give_asset_empty_noop() -> void:
	_player("p1", {"items": []})
	_player("p2", {"items": []})
	_t._apply_give("giveAsset", {}, "p2")
	assert_eq((_gs.players["p2"]["items"] as Array).size(), 0)


func test_give_to_self_noop() -> void:
	_player("p1", {"clues": 3})
	_t._apply_give("giveClue", {"count": 2}, "p1")
	assert_eq(int(_gs.players["p1"]["clues"]), 3, "передача самому себе игнорируется")
