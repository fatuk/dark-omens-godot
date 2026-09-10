extends GutTest

## Юнит-тесты LocalDice (scripts/core/game/local_dice.gd) — UI-слоя кубов
## локального игрока: кликабельность, заряженный жетон, маршрут тапа в act().
##
## Мок GameState пишет каждый act() в список — проверяем, КАКОЕ relay-действие и
## с какой валютой ушло, не поднимая сеть.

var _gs: MockGameState
var _dice: LocalDice


class MockNm:
	extends RefCounted
	var my_user_id: String = "p"


class MockGameState:
	extends Node
	var players: Dictionary = {}
	var active_check: Dictionary = {}
	var _check_stack: Array = []
	var _nm: MockNm = MockNm.new()
	var acts: Array = []
	var changed: int = 0

	func act(action: String, payload: Dictionary = {}) -> void:
		acts.append({"action": action, "payload": payload})

	func my_player() -> Dictionary:
		return players.get("p", {})

	func _name_of(pid: String) -> String:
		return pid

	func _broadcast_sync() -> void:
		pass

	func _emit_changed() -> void:
		changed += 1


func before_each() -> void:
	_gs = autofree(MockGameState.new())
	_dice = LocalDice.new(_gs, CheckFlow.new(_gs))
	_gs.players["p"] = {"investigator": "", "skill_mods": {}, "concentration": 0, "clues": 0}


# Брошенная проверка: кубы [2, 6], порог 5 → куб 0 провал, куб 1 успех.
func _rolled(owner: String = "shop", extra: Dictionary = {}) -> Dictionary:
	var c: Dictionary = {
		"owner": owner,
		"pid": "p",
		"skill": "will",
		"modifier": 0,
		"context": "",
		"rolled": true,
		"base": [2, 6],
		"dice": [2, 6],
		"successes": 1,
		"passed": true,
		"active_mods": [],
		"reroll_allowance": 0,
		"rerolls_used": 0,
		"add_targets": [],
	}
	for k_v: Variant in extra:
		c[k_v] = extra[k_v]
	return c


func _last() -> Dictionary:
	return _gs.acts.back() if not _gs.acts.is_empty() else {}


# ── Кликабельность ────────────────────────────────────────────────────────────


func test_can_reroll_needs_free_reroll_or_charged_token() -> void:
	_gs.active_check = _rolled()
	assert_false(_dice.can_reroll(), "ни бесплатного переброса, ни жетона")
	_gs.active_check["reroll_allowance"] = 1
	assert_true(_dice.can_reroll(), "бесплатный переброс от карты")
	_gs.active_check["reroll_allowance"] = 0
	_dice.charge("concentration")
	assert_true(_dice.can_reroll(), "заряжен жетон")
	assert_eq(_gs.changed, 1, "charge перерисовывает")


func test_can_reroll_false_before_roll_or_without_check() -> void:
	_dice.charge("clue")
	assert_false(_dice.can_reroll(), "проверки нет")
	_gs.active_check = _rolled("shop", {"rolled": false})
	assert_false(_dice.can_reroll(), "ещё не брошено")


func test_has_resource_counts_tokens_in_hand() -> void:
	_gs.active_check = _rolled()
	assert_false(_dice.has_resource())
	_gs.players["p"]["clues"] = 1
	assert_true(_dice.has_resource(), "улика в руке — исход ещё можно спасти")


func test_current_check_prefers_reckoning_slot() -> void:
	_gs.active_check = _rolled("effectCheck")
	assert_eq(String(_dice.current_check().get("owner", "")), "effectCheck")
	_gs.players["p"]["reckoning_check"] = _rolled("reckoning")
	assert_eq(String(_dice.current_check().get("owner", "")), "reckoning", "в Расплате — свой слот")
	assert_true(
		_dice.can_reroll(true) == false and _dice.can_add(true) == false, "слот без ресурсов"
	)


# ── Тап по кубу ───────────────────────────────────────────────────────────────


func test_tap_routes_reroll_by_check_owner() -> void:
	for pair: Array in [
		["shop", RelayActions.SHOP_REROLL],
		["spell", RelayActions.SPELL_CAST_REROLL],
		["effectCheck", RelayActions.CHECK_REROLL],
		["combat", RelayActions.REROLL_ENCOUNTER],
	]:
		_gs.acts = []
		_gs.active_check = _rolled(String(pair[0]), {"reroll_allowance": 1})
		_dice.tap(0)
		assert_eq(String(_last().get("action", "")), String(pair[1]), "owner=%s" % pair[0])
		assert_eq(String(_last()["payload"].get("currency", "")), "free", "без жетона — бесплатно")


func test_tap_spends_charged_token_once() -> void:
	_gs.active_check = _rolled()
	_dice.charge("concentration")
	_dice.tap(0)
	assert_eq(
		String(_last()["payload"].get("currency", "")), "concentration", "ушла ИМЕННО заряженная"
	)
	assert_eq(_dice.pending_currency, "", "жетон потреблён")
	_dice.tap(0)
	assert_eq(String(_last()["payload"].get("currency", "")), "free", "второй тап — уже без жетона")


func test_tap_on_success_die_keeps_token() -> void:
	_gs.active_check = _rolled()
	_dice.charge("clue")
	_dice.tap(1)  # куб 1 = 6 — успех, перебрасывать нельзя
	assert_true(_gs.acts.is_empty(), "ничего не ушло хосту")
	assert_eq(_dice.pending_currency, "clue", "заряд не съеден")


func test_tap_prefers_add_die_when_charged() -> void:
	# Заряд +1 (addToDie) на кубе 0 (< 6) — тап кладёт +1, а не перебрасывает.
	_gs.active_check = _rolled(
		"shop", {"active_mods": [{"do": "addToDie", "skill": "will", "amount": 1}]}
	)
	assert_true(_dice.can_add(), "есть незаряженный +1")
	_dice.tap(0)
	assert_eq(String(_last().get("action", "")), RelayActions.ADD_DIE)


func test_tap_in_reckoning_uses_own_slot_and_actions() -> void:
	_gs.players["p"]["reckoning_check"] = _rolled("reckoning", {"reroll_allowance": 1})
	_dice.tap(0, true)
	assert_eq(String(_last().get("action", "")), RelayActions.RECKONING_REROLL)
	_gs.players["p"]["reckoning_check"]["active_mods"] = [
		{"do": "addToDie", "skill": "will", "amount": 1}
	]
	_dice.tap(0, true)
	assert_eq(String(_last().get("action", "")), RelayActions.RECKONING_ADD_DIE)
