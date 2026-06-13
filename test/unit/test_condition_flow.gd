extends GutTest

## Юнит-тесты подсистемы состояний (scripts/core/game/condition_flow.gd),
## вынесенной из GameState. Покрытие:
##   • whileHeld-ограничения (cannotMove/Act, removeFromBoard, immuneToEffects);
##   • расплата: детерминированный onReckoning (poisoned → −1 hp), подавление
##     у перевёрнутых, ворота через dieRoll (cursed);
##   • flip: then:flip / then:discard / выдача нового состояния / пустые исходы;
##   • triggered (Hypothermia on:rest) и action (Detained escape);
##   • выдача активов с onGain (обычный / сервис / гварды).
##
## Случайность детерминируется тем же механизмом, что и в EffectRunner:
##   flow.rolls[path] — броски ворот (dieRoll/test); путь верхнеуровневой ноды
##     i == String(i), поэтому одиночный dieRoll → ключ "0";
##   flow.outcomes[cid] — форс конкретного reckoningOutcome при flip.

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


# ── Порог успеха (Cursed/Blessed whileHeld successThreshold) ──────────────────


func test_threshold_default() -> void:
	_add_player("p")
	assert_eq(_cond.player_success_threshold("p"), 5, "без состояний — дефолт 5")


func test_threshold_cursed_is_6() -> void:
	_add_player("p", {"conditions": ["cursed"]})
	assert_eq(_cond.player_success_threshold("p"), 6, "Cursed — только 6")


func test_threshold_blessed_is_4() -> void:
	_add_player("p", {"conditions": ["blessed"]})
	assert_eq(_cond.player_success_threshold("p"), 4, "Blessed — 4-6")


func test_threshold_cursed_and_blessed_cancel() -> void:
	_add_player("p", {"conditions": ["cursed", "blessed"]})
	assert_eq(_cond.player_success_threshold("p"), 5, "конфликт 6 и 4 → нейтральные 5")


func test_threshold_flipped_ignored() -> void:
	_add_player("p", {"conditions": ["cursed"], "conditions_flipped": {"cursed": "x"}})
	assert_eq(_cond.player_success_threshold("p"), 5, "перевёрнутое Cursed не действует")


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


# ── Flip: выбор исхода форсируется flow.outcomes[cid] ─────────────────────────
# legInjury — kind "injury"; исходы этого вида берём боевые из data/conditions.json:
#   splittingHeadache (effects: loseSanity 1, then: flip)
#   failingBody       (effects: loseImprovement, then: discard)
#   infectedWound     (effects: gainCondition diseased, then: discard)


func test_flip_then_flip_marks_flipped_and_applies_effect() -> void:
	_add_player("p", {"conditions": ["legInjury"]})
	var def: Dictionary = Conditions.get_def("legInjury")
	_cond._flip_condition(
		"p", "legInjury", def, {}, {"outcomes": {"legInjury": "splittingHeadache"}}
	)
	var p: Dictionary = _gs.players["p"]
	assert_eq(int(p["sanity"]), 4, "эффект исхода применён (loseSanity 1)")
	assert_eq(
		String((p["conditions_flipped"] as Dictionary).get("legInjury", "")), "splittingHeadache"
	)
	assert_true((p["conditions"] as Array).has("legInjury"), "при then:flip состояние остаётся")


func test_flip_then_discard_removes_condition() -> void:
	_add_player("p", {"conditions": ["legInjury"]})
	var def: Dictionary = Conditions.get_def("legInjury")
	_cond._flip_condition("p", "legInjury", def, {}, {"outcomes": {"legInjury": "failingBody"}})
	var p: Dictionary = _gs.players["p"]
	assert_false((p["conditions"] as Array).has("legInjury"), "при then:discard состояние снято")
	assert_false((p["conditions_flipped"] as Dictionary).has("legInjury"), "flip-метка очищена")


func test_flip_outcome_can_grant_new_condition() -> void:
	_add_player("p", {"conditions": ["legInjury"]})
	var def: Dictionary = Conditions.get_def("legInjury")
	_cond._flip_condition("p", "legInjury", def, {}, {"outcomes": {"legInjury": "infectedWound"}})
	var p: Dictionary = _gs.players["p"]
	assert_true((p["conditions"] as Array).has("diseased"), "исход выдал новое состояние")
	assert_false((p["conditions"] as Array).has("legInjury"), "исходное снято (then:discard)")


func test_flip_empty_outcomes_marks_flipped_blank() -> void:
	# Вид без reckoningOutcomes → пометить перевёрнутым с пустым id (ветка fallback).
	_add_player("p", {"conditions": ["x"]})
	_cond._flip_condition("p", "x", {"kind": "zzz_no_such_kind"}, {}, {})
	assert_eq(String((_gs.players["p"]["conditions_flipped"] as Dictionary).get("x", "?")), "")


# ── _apply_reckon_board: маршрутизация board-узлов расплаты ────────────────────


func test_reckon_board_flipcard_delegates_to_flip() -> void:
	_add_player("p", {"conditions": ["legInjury"]})
	var def: Dictionary = Conditions.get_def("legInjury")
	var flow: Dictionary = {"outcomes": {"legInjury": "splittingHeadache"}}
	_cond._apply_reckon_board("p", "legInjury", def, {"do": "flipCard"}, {}, flow)
	assert_eq(
		String((_gs.players["p"]["conditions_flipped"] as Dictionary).get("legInjury", "")),
		"splittingHeadache"
	)


func test_reckon_board_discardcard_removes() -> void:
	_add_player("p", {"conditions": ["legInjury"]})
	_cond._apply_reckon_board("p", "legInjury", {}, {"do": "discardCard"}, {})
	assert_false((_gs.players["p"]["conditions"] as Array).has("legInjury"))


func test_reckon_board_other_verb_goes_to_board() -> void:
	_add_player("p", {"conditions": ["legInjury"]})
	_cond._apply_reckon_board("p", "legInjury", {}, {"do": "advanceDoom", "amount": 1}, {})
	assert_eq(_gs.board_effects.size(), 1, "прочий verb — обычным board-эффектом")
	assert_eq(String((_gs.board_effects[0] as Dictionary)["do"]), "advanceDoom")


# ── Расплата через onReckoning-ворота (dieRoll) — детерминизм flow.rolls ───────
# cursed (kind bane): onReckoning [ dieRoll [ on 4-6 → discardCard ] ].


func test_reckoning_cursed_discards_on_high_roll() -> void:
	_add_player("p", {"conditions": ["cursed"]})
	_cond.host_resolve_reckoning({"rolls": {"0": [5]}})
	assert_false((_gs.players["p"]["conditions"] as Array).has("cursed"), "5 ∈ 4-6 → discardCard")


func test_reckoning_cursed_retains_on_low_roll() -> void:
	_add_player("p", {"conditions": ["cursed"]})
	_cond.host_resolve_reckoning({"rolls": {"0": [2]}})
	assert_true((_gs.players["p"]["conditions"] as Array).has("cursed"), "2 ∉ 4-6 → без эффекта")


# ── fire_triggered (Hypothermia on:rest) ──────────────────────────────────────
# triggered.do = [ cannotRecover health, dieRoll [ 4-6 → discardCard, 1-3 → [] ] ].


func test_fire_triggered_returns_cannot_recover_and_retains_on_low() -> void:
	_add_player("p", {"conditions": ["hypothermia"]})
	var rec: Array = _cond.fire_triggered("p", "rest", {"rolls": {"0": [2]}})
	assert_has(rec, "health", "cannotRecover health возвращается синхронно")
	assert_true(
		(_gs.players["p"]["conditions"] as Array).has("hypothermia"), "1-3 → состояние держится"
	)


func test_fire_triggered_discards_on_high_roll() -> void:
	_add_player("p", {"conditions": ["hypothermia"]})
	var rec: Array = _cond.fire_triggered("p", "rest", {"rolls": {"0": [5]}})
	assert_has(rec, "health")
	assert_false((_gs.players["p"]["conditions"] as Array).has("hypothermia"), "4-6 → discardCard")


func test_fire_triggered_wrong_event_is_noop() -> void:
	_add_player("p", {"conditions": ["hypothermia"]})
	var rec: Array = _cond.fire_triggered("p", "move")
	assert_eq(rec.size(), 0, "событие не совпало — триггер молчит")
	assert_true((_gs.players["p"]["conditions"] as Array).has("hypothermia"))


func test_fire_triggered_non_host_returns_empty() -> void:
	_gs.host = false
	_add_player("p", {"conditions": ["hypothermia"]})
	assert_eq(_cond.fire_triggered("p", "rest").size(), 0, "не-хост триггеры не исполняет")


# ── Восстановление при отдыхе (rest-triggered) для травм/безумия/болезни ───────


func test_rest_injury_discards_on_high_roll() -> void:
	# legInjury: при отдыхе roll 1, на 5-6 — сброс. Нет cannotRecover (rec пуст).
	_add_player("p", {"conditions": ["legInjury"]})
	var rec: Array = _cond.fire_triggered("p", "rest", {"rolls": {"0": [5]}})
	assert_eq(rec.size(), 0, "травма не блокирует лечение")
	assert_false((_gs.players["p"]["conditions"] as Array).has("legInjury"), "5 → сброс")


func test_rest_injury_retains_on_low_roll() -> void:
	_add_player("p", {"conditions": ["legInjury"]})
	_cond.fire_triggered("p", "rest", {"rolls": {"0": [2]}})
	assert_true((_gs.players["p"]["conditions"] as Array).has("legInjury"), "2 → держится")


func test_rest_head_injury_blocks_sanity_and_rolls_46() -> void:
	# headInjury: не лечит рассудок + roll 1, на 4-6 — сброс.
	_add_player("p", {"conditions": ["headInjury"]})
	var rec: Array = _cond.fire_triggered("p", "rest", {"rolls": {"0": [4]}})
	assert_has(rec, "sanity", "headInjury блокирует лечение рассудка")
	assert_false((_gs.players["p"]["conditions"] as Array).has("headInjury"), "4 → сброс")


func test_rest_poisoned_blocks_both_and_flips() -> void:
	# poisoned: не лечит здоровье и рассудок + flip (вскрытие исхода-болезни).
	_add_player("p", {"conditions": ["poisoned"]})
	var rec: Array = _cond.fire_triggered("p", "rest", {"outcomes": {"poisoned": "burningFever"}})
	assert_has(rec, "health", "poisoned блокирует здоровье")
	assert_has(rec, "sanity", "и рассудок")
	assert_eq(
		String((_gs.players["p"]["conditions_flipped"] as Dictionary).get("poisoned", "")),
		"burningFever",
		"при отдыхе poisoned перевернулось на исход"
	)


# ── host_run_condition_action (Detained escape) ───────────────────────────────
# action = [ test influence → onPass [ discardCard ] ]. Без навыков в ctx проверка
# авто-проходит (см. EffectRunner) → escape срабатывает детерминированно.


func test_condition_action_detained_escapes() -> void:
	_add_player("p", {"conditions": ["detained"]})
	var ok: bool = _cond.host_run_condition_action("p", "detained")
	assert_true(ok, "у detained есть action")
	assert_false((_gs.players["p"]["conditions"] as Array).has("detained"), "auto-pass → сброс")


func test_condition_action_absent_returns_false() -> void:
	_add_player("p", {"conditions": ["poisoned"]})
	assert_false(_cond.host_run_condition_action("p", "poisoned"), "у poisoned нет action-слота")
	assert_true((_gs.players["p"]["conditions"] as Array).has("poisoned"))


func test_condition_action_non_host_returns_false() -> void:
	_gs.host = false
	_add_player("p", {"conditions": ["detained"]})
	assert_false(_cond.host_run_condition_action("p", "detained"))
