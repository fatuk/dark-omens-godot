extends GutTest

## Юнит-тесты прогона программ актива (scripts/core/game/asset_action_flow.gd).
## Покрытие:
##   • выдача карты с onGain: обычный актив в руку, услуга срабатывает и сбрасывается;
##   • интерактивный выбор МОНСТРА (target chosenMonster) — пауза, модалка, ref;
##   • интерактивный выбор ЛОКАЦИИ (target chosenSpace) — урон всем монстрам там;
##   • очередь выдач: вторая карта ждёт, пока игрок ответит по первой;
##   • действие актива: удержание хода, оплата (истощение) и гварды can_play.
##
## Монстры на поле подменяются заглушкой _board: движку важны только варианты
## выбора, а сам урон наносит BoardState (см. test_board_state.gd).

const _DERRINGER: String = "18_derringer"  # обычный актив (без onGain)
const _QUARANTINE: String = "agency_quarantine"  # услуга: onGain → damageMonster chosenSpace
const _ASSASSINATION: String = "assassination"  # услуга: onGain → damageMonster chosenMonster
const _MONSTER_HUNTER: String = "monster_hunter"  # действие: damageMonster chosenMonster

var _gs: MockGameState
var _flow: AssetActionFlow


# Заглушка BoardState: варианты выбора монстра и локации.
class StubBoard:
	extends RefCounted
	var monsters: Array = []
	var spaces: Array = []

	func monster_choices() -> Array:
		return monsters

	func space_choices() -> Array:
		return spaces


# Заглушка TargetResolver: «прочие сыщики» для chosenInvestigator.
class StubTarget:
	extends RefCounted

	func other_pids(_exclude: String) -> Array:
		return []


# Заглушка CheckFlow: программа с test поднимает видимую проверку.
class StubCheck:
	extends RefCounted
	var started: Dictionary = {}

	func start(owner: String, pid: String, skill: String, _mod: int, _ctx: String) -> void:
		started = {"owner": owner, "pid": pid, "skill": skill}

	func clear() -> void:
		started = {}


# Заглушка PhaseController: завершение действия освобождает ход.
class StubPhase:
	extends RefCounted
	var released: Array = []

	func release_asset_turn(pid: String) -> void:
		released.append(pid)


class MockGameState:
	extends Node
	var players: Dictionary = {}
	var board_effects: Array = []
	var host: bool = true
	var pending_check: Dictionary = {}
	var mythos_decision: Dictionary = {}
	var _board := StubBoard.new()
	var _target := StubTarget.new()
	var _check := StubCheck.new()
	var _phase := StubPhase.new()

	func _is_host() -> bool:
		return host

	func _name_of(pid: String) -> String:
		return pid

	func _apply_board_effect(node: Dictionary) -> void:
		board_effects.append(node)

	func _broadcast_sync() -> void:
		pass

	func _emit_changed() -> void:
		pass


func before_each() -> void:
	_gs = autofree(MockGameState.new())
	_flow = AssetActionFlow.new(_gs)


func _add_player(pid: String) -> void:
	_gs.players[pid] = {
		"user_id": pid,
		"investigator": "Charlie Kane",
		"hp": 5,
		"hp_max": 7,
		"sanity": 5,
		"sanity_max": 6,
		"clues": 0,
		"items": [],
		"conditions": [],
		"location": "arkham",
	}


func _monster(ref: String, loc: String) -> Dictionary:
	return {"ref": ref, "name": "MON", "toughness": 2, "health": 2, "loc": loc, "loc_name": loc}


# Первый board-эффект с указанным глаголом ({} — нет такого).
func _board_node(verb: String) -> Dictionary:
	for i in range(_gs.board_effects.size()):
		var n: Dictionary = _gs.board_effects[i]
		if String(n.get("do", "")) == verb:
			return n
	return {}


# ── Выдача карты (onGain) ─────────────────────────────────────────────────────


func test_grant_normal_asset_added_to_items() -> void:
	_add_player("p")
	_flow.grant("p", _DERRINGER)
	var items: Array = _gs.players["p"]["items"]
	assert_eq(items.size(), 1, "обычный актив попадает в инвентарь")
	assert_eq(String((items[0] as Dictionary)["id"]), _DERRINGER)
	assert_false(bool((items[0] as Dictionary)["exhausted"]), "выдан неистощённым")
	assert_true(_gs.mythos_decision.is_empty(), "без интерактива модалку не поднимаем")


func test_grant_asset_non_host_is_noop() -> void:
	_gs.host = false
	_add_player("p")
	_flow.grant("p", _DERRINGER)
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "не-хост ничего не выдаёт")


func test_grant_unknown_asset_is_noop() -> void:
	_add_player("p")
	_flow.grant("p", "no_such_asset")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "неизвестный id игнорируется")


# ── Выбор монстра (chosenMonster) ─────────────────────────────────────────────


func test_grant_service_asks_for_monster() -> void:
	_add_player("p")
	_gs._board.monsters = [_monster("arkham#0", "arkham"), _monster("rome#1", "rome")]
	_flow.grant("p", _ASSASSINATION)
	var d: Dictionary = _gs.mythos_decision
	assert_true(bool(d.get("active", false)), "прогон встал на выборе монстра")
	assert_eq(String(d.get("kind", "")), "monster")
	assert_eq(String(d.get("driver", "")), "asset", "будить надо прогон актива, не мифы")
	assert_eq((d.get("options", []) as Array).size(), 2, "оба монстра предложены")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "карта ещё не отработала")


func test_chosen_monster_reaches_board_by_ref() -> void:
	_add_player("p")
	_gs._board.monsters = [_monster("arkham#0", "arkham"), _monster("rome#1", "rome")]
	_flow.grant("p", _ASSASSINATION)
	_flow.resolve_decision("p", 1)  # второй монстр
	var node: Dictionary = _board_node("damageMonster")
	assert_eq(String(node.get("_target_monster", "")), "rome#1", "урон уходит выбранному монстру")
	assert_eq(int(node.get("amount", 0)), 2, "урон карты сохранён")
	assert_true(_gs.mythos_decision.is_empty(), "модалка закрыта после ответа")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "услуга сброшена, в руку не идёт")


func test_service_without_monsters_still_consumed() -> void:
	_add_player("p")
	_flow.grant("p", _ASSASSINATION)  # монстров на поле нет
	assert_true(_gs.mythos_decision.is_empty(), "выбирать не из кого — вопрос не задаём")
	assert_eq(_board_node("damageMonster"), {}, "урон никуда не уходит")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "карта всё равно сброшена")


# ── Выбор локации (chosenSpace) ───────────────────────────────────────────────


func test_quarantine_asks_for_space() -> void:
	_add_player("p")
	_gs._board.spaces = [{"ref": "arkham", "name": "arkham", "count": 2}]
	_flow.grant("p", _QUARANTINE)
	assert_eq(String(_gs.mythos_decision.get("kind", "")), "space", "карантин выбирает локацию")
	_flow.resolve_decision("p", 0)
	var node: Dictionary = _board_node("damageMonster")
	assert_eq(String(node.get("_target_space", "")), "arkham", "локация уехала на доску")
	assert_eq(int(node.get("amount", 0)), 4, "урон карантина — 4")


# ── Очередь выдач ─────────────────────────────────────────────────────────────


func test_second_grant_waits_for_first_decision() -> void:
	_add_player("p")
	_gs._board.monsters = [_monster("arkham#0", "arkham")]
	_gs._board.spaces = [{"ref": "arkham", "name": "arkham", "count": 1}]
	_flow.grant("p", _ASSASSINATION)
	_flow.grant("p", _QUARANTINE)
	assert_eq(String(_gs.mythos_decision.get("kind", "")), "monster", "первой спрашиваем убийство")
	_flow.resolve_decision("p", 0)
	assert_eq(String(_gs.mythos_decision.get("kind", "")), "space", "очередь дошла до карантина")
	_flow.resolve_decision("p", 0)
	assert_true(_gs.mythos_decision.is_empty(), "очередь пуста — модалки нет")
	assert_eq(_gs.board_effects.size(), 2, "обе услуги применились")


# ── Действие актива ───────────────────────────────────────────────────────────


func test_action_holds_turn_until_monster_picked() -> void:
	_add_player("p")
	_gs._board.monsters = [_monster("arkham#0", "arkham")]
	(_gs.players["p"]["items"] as Array).append({"id": _MONSTER_HUNTER, "exhausted": false})
	assert_eq(_flow.play("p", 0), AssetActionFlow.PLAY_WAITING, "ход держим до выбора")
	assert_eq(_gs._phase.released.size(), 0, "ход ещё не отпущен")
	_flow.resolve_decision("p", 0)
	assert_eq(String(_board_node("damageMonster").get("_target_monster", "")), "arkham#0")
	assert_eq(_gs._phase.released, ["p"], "после ответа ход отпущен")
	var card: Dictionary = (_gs.players["p"]["items"] as Array)[0]
	assert_true(bool(card.get("exhausted", false)), "действие истощило карту")


func test_cannot_play_monster_action_without_monsters() -> void:
	_add_player("p")
	(_gs.players["p"]["items"] as Array).append({"id": _MONSTER_HUNTER, "exhausted": false})
	assert_false(_flow.can_play("p", 0), "монстров нет — карта не играется")
	assert_eq(_flow.play("p", 0), AssetActionFlow.PLAY_INVALID, "действие не тратится")


func test_cannot_play_exhausted_card() -> void:
	_add_player("p")
	_gs._board.monsters = [_monster("arkham#0", "arkham")]
	(_gs.players["p"]["items"] as Array).append({"id": _MONSTER_HUNTER, "exhausted": true})
	assert_false(_flow.can_play("p", 0), "истощённую карту играть нельзя")
