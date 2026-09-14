extends GutTest

## Юнит-тесты подсистемы состояний (scripts/core/game/condition_flow.gd),
## вынесенной из GameState. Покрытие:
##   • whileHeld-ограничения (cannotMove/Act, removeFromBoard, immuneToEffects);
##   • расплата: детерминированный onReckoning (poisoned → −1 hp), подавление
##     у перевёрнутых, ворота через dieRoll (cursed);
##   • flip: then:flip / then:discard / выдача нового состояния / пустые исходы;
##   • triggered (Hypothermia on:rest) и action (Detained escape).
##
## Выдача активов (host_grant_asset) переехала в AssetActionFlow — см.
## test_asset_action_flow.gd.
##
## Случайность детерминируется тем же механизмом, что и в EffectRunner:
##   flow.rolls[path] — броски ворот (dieRoll/test); путь верхнеуровневой ноды
##     i == String(i), поэтому одиночный dieRoll → ключ "0";
##   flow.outcomes[cid] — форс конкретного reckoningOutcome при flip.

var _gs: MockGameState
var _cond: ConditionFlow


# Заглушка CheckFlow: ConditionFlow._run_action_program зовёт start/clear (бросок —
# интерактивный, результат приходит через resolve_action_check, а не roll).
class StubCheck:
	extends RefCounted
	var started: Dictionary = {}

	func start(owner: String, pid: String, skill: String, _mod: int, _ctx: String) -> void:
		started = {"owner": owner, "pid": pid, "skill": skill}

	func make_check(
		owner: String, pid: String, skill: String, _mod: int, _ctx: String
	) -> Dictionary:
		return {"owner": owner, "pid": pid, "skill": skill, "rolled": false, "passed": false}

	func roll(_pid: String, _c: Dictionary = {}) -> bool:
		return true

	func clear() -> void:
		started = {}


# Заглушка PhaseController: завершение действия освобождает ход.
class StubPhase:
	extends RefCounted
	var released: Array = []

	func release_condition_turn(pid: String) -> void:
		released.append(pid)


class MockGameState:
	extends Node
	signal effect_check_applied(pid: String, passed: bool)  # будит интерактивную Расплату
	signal mythos_decided(index: int)  # будит выбор в onReckoning (канал mythos_decision)
	var players: Dictionary = {}
	var mythos_decision: Dictionary = {}
	var board_effects: Array = []
	var reckoning_results: Dictionary = {}
	var host: bool = true
	var active_check: Dictionary = {}
	var pending_check: Dictionary = {}
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

	func announce_action(_pid: String, _id: String, _params: Dictionary = {}) -> void:
		pass


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


# ── Регрессия дедлока: проверка Расплаты отвалившегося ────────────────────────


# Отвалившийся во время своей проверки Расплаты сыщик броска не пришлёт. _await_my_check
# не должен виснуть на effect_check_applied — сразу возвращает «провалено». Если бы
# гард по connected регрессировал, этот тест завис бы (таймаут GUT), а не прошёл.
func test_await_my_check_fails_fast_for_disconnected() -> void:
	_add_player("p", {"connected": false})
	var passed: bool = await _cond._await_my_check("p")
	assert_false(passed, "проверка отвалившегося = провал, без ожидания сигнала")


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


func test_flip_records_reckoning_result() -> void:
	# Флип пишет результат для модалки игрока: выпавший оборот + flavor-ключ.
	_add_player("p", {"conditions": ["legInjury"]})
	var def: Dictionary = Conditions.get_def("legInjury")
	_cond._flip_condition(
		"p", "legInjury", def, {}, {"outcomes": {"legInjury": "splittingHeadache"}}
	)
	var r: Dictionary = _gs.reckoning_results.get("p", {})
	assert_eq(String(r.get("back", "")), "splittingHeadache", "результат флипа записан")
	assert_eq(String(r.get("text", "")), "OUTCOME_SPLITTING_HEADACHE_TEXT", "несёт flavor-ключ")


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
	# Состояние без backs → пометить перевёрнутым с пустым id (ветка fallback).
	_add_player("p", {"conditions": ["x"]})
	_cond._flip_condition("p", "x", {"kind": "zzz_no_such_kind"}, {}, {})
	assert_eq(String((_gs.players["p"]["conditions_flipped"] as Dictionary).get("x", "?")), "")


func test_flip_uses_own_backs() -> void:
	# Без форса оборот тянется из СОБСТВЕННЫХ backs состояния (инлайн, как у
	# заклинаний), а не из общего пула вида.
	_add_player("p", {"conditions": ["amnesia"]})
	var def: Dictionary = Conditions.get_def("amnesia")
	var own_ids: Array = []
	for b_v: Variant in def.get("backs", []):
		own_ids.append(String((b_v as Dictionary)["id"]))
	_cond._flip_condition("p", "amnesia", def, {}, {})
	var fl: Dictionary = _gs.players["p"]["conditions_flipped"]
	if fl.has("amnesia"):
		assert_has(own_ids, String(fl["amnesia"]), "перевёрнуто на собственный оборот amnesia")
	else:
		assert_false(
			(_gs.players["p"]["conditions"] as Array).has("amnesia"),
			"оборот then:discard снял amnesia"
		)


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


# ── Видимая проверка действия через ОБЩИЙ движок test (pend → resolve) ─────────


func test_begin_action_starts_visible_check() -> void:
	_add_player("p", {"conditions": ["detained"]})
	assert_true(_cond.begin_action("p", "detained"), "detained — действие с проверкой")
	assert_eq(String(_gs._check.started.get("owner", "")), "effectCheck", "check owner=effectCheck")
	assert_eq(String(_gs._check.started.get("skill", "")), "influence", "навык из test-узла")
	assert_eq(
		String(_gs.pending_check.get("driver", "")), "condition", "pending_check.driver=condition"
	)
	assert_eq(String(_gs.pending_check.get("pid", "")), "p")
	assert_true(_gs.pending_check.has("path"), "путь проверки задан")


func test_begin_action_no_test_returns_false() -> void:
	# poisoned — без локального действия → видимой проверки нет.
	_add_player("p", {"conditions": ["poisoned"]})
	assert_false(_cond.begin_action("p", "poisoned"))
	assert_eq(_gs.pending_check, {})


func test_resolve_action_check_passed_discards() -> void:
	_add_player("p", {"conditions": ["detained"]})
	assert_true(_cond.begin_action("p", "detained"))
	var path: String = String(_gs.pending_check.get("path", ""))
	_cond.resolve_action_check("p", path, true)
	assert_false(
		(_gs.players["p"]["conditions"] as Array).has("detained"), "успех → сброс (onPass)"
	)
	assert_eq(_gs.pending_check, {}, "проверка снята")
	assert_true((_gs._phase.released as Array).has("p"), "ход освобождён")


func test_resolve_action_check_failed_keeps() -> void:
	_add_player("p", {"conditions": ["detained"]})
	assert_true(_cond.begin_action("p", "detained"))
	var path: String = String(_gs.pending_check.get("path", ""))
	_cond.resolve_action_check("p", path, false)
	assert_true(
		(_gs.players["p"]["conditions"] as Array).has("detained"), "провал → держится (onFail пуст)"
	)
	assert_eq(_gs.pending_check, {}, "проверка снята и при провале")
	assert_true((_gs._phase.released as Array).has("p"), "ход освобождён")


# ── Интерактивная Расплата: test onReckoning → ВИДИМАЯ проверка (Фаза E) ───────
# amnesia: onReckoning test will → при провале flipCard. interactive=true пендит
# проверку (pending_check{driver:reckoning}) и ждёт effect_check_applied.


func test_reckon_condition_interactive_pends_check() -> void:
	_add_player("p", {"conditions": ["amnesia"]})
	_cond.reckon_condition("p", "amnesia", {}, true)  # корутина доходит до await
	# Проверка лежит В ИГРОКЕ (per-player слот), параллельно с другими сыщиками.
	var rp: Dictionary = (_gs.players["p"] as Dictionary).get("reckoning_pending", {})
	assert_eq(String(rp.get("cid", "")), "amnesia", "per-player reckoning_pending выставлен")
	var rc: Dictionary = (_gs.players["p"] as Dictionary).get("reckoning_check", {})
	assert_eq(String(rc.get("owner", "")), "reckoning", "слот reckoning_check создан")
	_gs.effect_check_applied.emit("p", true)  # дренируем корутину (иначе висит на await)


# Состояние «активно лицом»: в conditions и НЕ перевёрнуто. flipCard может случайно
# (random back) дать flip ИЛИ discard — в обоих случаях лицо перестаёт быть активным.
func _front_active(pid: String, cid: String) -> bool:
	var p: Dictionary = _gs.players.get(pid, {})
	return (
		(p.get("conditions", []) as Array).has(cid)
		and not (p.get("conditions_flipped", {}) as Dictionary).has(cid)
	)


func test_reckon_condition_interactive_fail_flips() -> void:
	_add_player("p", {"conditions": ["amnesia"]})
	_cond.reckon_condition("p", "amnesia", {}, true)
	_gs.effect_check_applied.emit("p", false)  # провал → onFail flipCard
	assert_false(_front_active("p", "amnesia"), "провал → onFail сработал (флип/сброс)")
	assert_false((_gs.players["p"] as Dictionary).has("reckoning_pending"), "слот проверки очищен")


func test_reckon_condition_interactive_pass_no_flip() -> void:
	_add_player("p", {"conditions": ["amnesia"]})
	_cond.reckon_condition("p", "amnesia", {}, true)
	_gs.effect_check_applied.emit("p", true)  # успех → ветки onPass нет, флипа нет
	assert_true(_front_active("p", "amnesia"), "успех → состояние осталось активным лицом")


# righteous: onReckoning flipCard optional:true → в интерактивной Расплате это выбор
# «перевернуть / пропустить» через канал mythos_decision (раньше optional молча
# применялся всегда, а после появления optional-choice — молча пропускался).
func test_reckon_condition_interactive_optional_pends_decision() -> void:
	_add_player("p", {"conditions": ["righteous"]})
	_cond.reckon_condition("p", "righteous", {}, true)
	var md: Dictionary = _gs.mythos_decision
	assert_true(bool(md.get("active", false)), "модалка решения выставлена")
	assert_eq(String(md.get("pid", "")), "p", "решение — сыщика Расплаты")
	assert_eq((md.get("options", []) as Array).size(), 2, "перевернуть / пропустить")
	assert_true(_front_active("p", "righteous"), "до ответа ничего не применено")
	_gs.mythos_decided.emit(0)  # перевернуть
	assert_false(_front_active("p", "righteous"), "выбор «перевернуть» → флип")
	assert_false(bool(_gs.mythos_decision.get("active", false)), "канал освобождён")


func test_reckon_condition_interactive_optional_skip_keeps_front() -> void:
	_add_player("p", {"conditions": ["righteous"]})
	_cond.reckon_condition("p", "righteous", {}, true)
	_gs.mythos_decided.emit(1)  # пропустить
	assert_true(_front_active("p", "righteous"), "пропуск → состояние осталось лицом")
	assert_false(bool(_gs.mythos_decision.get("active", false)), "канал освобождён")


# Канал mythos_decision один на всех, Расплаты параллельны: второй сыщик ждёт, пока
# первый решит, и только потом получает свою модалку.
func test_reckon_condition_interactive_decisions_are_serialized() -> void:
	_add_player("a", {"conditions": ["righteous"]})
	_add_player("b", {"conditions": ["funding"]})
	_cond.reckon_condition("a", "righteous", {}, true)
	_cond.reckon_condition("b", "funding", {}, true)
	assert_eq(String(_gs.mythos_decision.get("pid", "")), "a", "первым решает a")
	_gs.mythos_decided.emit(1)  # a пропускает → канал переходит к b
	assert_eq(String(_gs.mythos_decision.get("pid", "")), "b", "затем модалка у b")
	_gs.mythos_decided.emit(0)  # b переворачивает
	assert_false(_front_active("b", "funding"), "b перевернул")
	assert_true(_front_active("a", "righteous"), "a остался лицом")
	assert_false(bool(_gs.mythos_decision.get("active", false)), "канал свободен")
