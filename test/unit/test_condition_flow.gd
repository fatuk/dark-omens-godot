extends GutTest

## Юнит-тесты подсистемы состояний (scripts/core/condition_flow.gd), вынесенной
## из GameState. Покрывают детерминированную поверхность: whileHeld-ограничения,
## расплату с фиксированным onReckoning (poisoned → loseHealth 1), подавление
## фронтового onReckoning у перевёрнутых состояний и выдачу активов с onGain.
##
## Случайные ветки (flipCard через test/dieRoll, triggered-броски) здесь не
## проверяются — для них нужен инъецируемый ГСЧ; покрываются отдельно.

const _DERRINGER: String = "18_derringer"  # обычный актив (без onGain)
const _SERVICE: String = "agency_quarantine"  # сервис: onGain → damageMonster + discardCard

var _gs: MockGameState
var _cond: ConditionFlow


# Минимальный мок GameState: ConditionFlow обращается только к этим четырём членам.
class MockGameState:
	extends Node
	var players: Dictionary = {}
	var board_effects: Array = []
	var host: bool = true

	func _is_host() -> bool:
		return host

	func _name_of(pid: String) -> String:
		return pid

	func _apply_board_effect(node: Dictionary) -> void:
		board_effects.append(node)


func before_each() -> void:
	_gs = autofree(MockGameState.new())
	_cond = ConditionFlow.new(_gs)


func _add_player(pid: String, extra: Dictionary = {}) -> void:
	var base: Dictionary = {
		"hp": 5,
		"hp_max": 7,
		"sanity": 5,
		"sanity_max": 6,
		"investigator": "",
		"conditions": [],
		"conditions_flipped": {},
		"items": [],
	}
	for k_v: Variant in extra:
		base[k_v] = extra[k_v]
	_gs.players[pid] = base


# ── whileHeld-ограничения ─────────────────────────────────────────────────────


func test_constraints_detained() -> void:
	_add_player("p", {"conditions": ["detained"]})
	assert_eq(_cond.player_constraints("p"), {"cannotMove": true, "cannotAct": true})


func test_has_constraint_true_and_false() -> void:
	_add_player("p", {"conditions": ["detained"]})
	assert_true(_cond.player_has_constraint("p", "cannotMove"), "detained → cannotMove")
	assert_false(_cond.player_has_constraint("p", "immuneToEffects"), "detained не даёт иммунитет")


func test_constraints_lost_in_time() -> void:
	_add_player("p", {"conditions": ["lostInTimeAndSpace"]})
	assert_true(_cond.player_has_constraint("p", "removeFromBoard"))
	assert_true(_cond.player_has_constraint("p", "immuneToEffects"))


func test_constraints_empty_when_no_conditions() -> void:
	_add_player("p")
	assert_eq(_cond.player_constraints("p"), {}, "без состояний — нет ограничений")


# ── Расплата (детерминированный onReckoning) ──────────────────────────────────


func test_reckoning_poisoned_loses_health() -> void:
	_add_player("p", {"conditions": ["poisoned"]})
	_cond.host_resolve_reckoning()
	assert_eq(int(_gs.players["p"]["hp"]), 4, "poisoned onReckoning: −1 здоровья")


func test_reckoning_non_host_is_noop() -> void:
	_gs.host = false
	_add_player("p", {"conditions": ["poisoned"]})
	_cond.host_resolve_reckoning()
	assert_eq(int(_gs.players["p"]["hp"]), 5, "не-хост не исполняет расплату")


func test_reckoning_skips_flipped_condition() -> void:
	# Перевёрнутое состояние: фронтовой onReckoning не действует.
	_add_player("p", {"conditions": ["poisoned"], "conditions_flipped": {"poisoned": "x"}})
	_cond.host_resolve_reckoning()
	assert_eq(int(_gs.players["p"]["hp"]), 5, "у перевёрнутого фронтовой onReckoning подавлен")


# ── Выдача активов с onGain ───────────────────────────────────────────────────


func test_grant_normal_asset_added_to_items() -> void:
	_add_player("p")
	_cond.host_grant_asset("p", _DERRINGER)
	var items: Array = _gs.players["p"]["items"]
	assert_eq(items.size(), 1, "обычный актив попадает в инвентарь")
	assert_eq(String((items[0] as Dictionary)["id"]), _DERRINGER)
	assert_false(bool((items[0] as Dictionary)["exhausted"]), "выдан неистощённым")


func test_grant_service_asset_consumed_not_kept() -> void:
	_add_player("p")
	_cond.host_grant_asset("p", _SERVICE)
	var items: Array = _gs.players["p"]["items"]
	assert_eq(items.size(), 0, "сервис сработал и сброшен — в инвентарь не идёт")
	var verbs: Array = []
	for i in range(_gs.board_effects.size()):
		verbs.append(String((_gs.board_effects[i] as Dictionary).get("do", "")))
	assert_has(verbs, "damageMonster", "onGain-эффект применён на доску")


func test_grant_asset_non_host_is_noop() -> void:
	_gs.host = false
	_add_player("p")
	_cond.host_grant_asset("p", _DERRINGER)
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "не-хост ничего не выдаёт")


func test_grant_unknown_asset_is_noop() -> void:
	_add_player("p")
	_cond.host_grant_asset("p", "no_such_asset")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "неизвестный id игнорируется")
