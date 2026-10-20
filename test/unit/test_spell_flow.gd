extends GutTest

## Юнит-тесты каста заклинаний (scripts/core/game/spell_flow.gd). Двусторонняя
## карта: каст → фронт onPass (при pass) → flip к рубашке → tiers по числу успехов
## → discard/назад на фронт. Детерминизм: явные successes/dice + flow.backs (форс
## рубашки). Данные — реальный data/spells.json (через SpellCatalog).

var _gs: MockGameState
var _sf: SpellFlow


# Стаб CheckFlow: start/roll/clear + push/pop стек. roll помечает rolled и кладёт
# заданные successes/dice, СОХРАНЯЯ owner/context (как настоящий CheckFlow).
class StubCheck:
	extends RefCounted
	var _gs: Node

	func _init(gs: Node) -> void:
		_gs = gs

	func start(owner: String, pid: String, _skill: String, _mod: int, ctx: String) -> void:
		_gs.active_check = {"owner": owner, "pid": pid, "context": ctx, "rolled": false}

	func roll(_pid: String) -> bool:
		var c: Dictionary = _gs.active_check
		c["rolled"] = true
		c["successes"] = _gs.roll_successes
		c["dice"] = _gs.roll_dice
		_gs.active_check = c
		return true

	func clear() -> void:
		_gs.active_check = {}

	func push() -> void:
		(_gs._check_stack as Array).append((_gs.active_check as Dictionary).duplicate(true))

	func pop() -> void:
		var st: Array = _gs._check_stack
		_gs.active_check = st.pop_back() if not st.is_empty() else {}

	func add_mods(_pid: String, mods: Array) -> void:
		var c: Dictionary = _gs.active_check
		var active: Array = c.get("active_mods", [])
		active.append_array(mods)
		c["active_mods"] = active


# Стаб PhaseController: фиксирует освобождение хода после применения каста (ritual).
class StubPhase:
	extends RefCounted
	var released: Array = []

	func release_cast_turn(pid: String) -> void:
		released.append(pid)


# Стаб EncounterFlow: окно реакции на потерю и итоги кастов фазы встреч.
class StubEncounter:
	extends RefCounted
	var window: bool = true
	var prevented: Array = []  # [[caster, stat, amount]]
	var options: Dictionary = {}  # pid → verbs

	func spell_loss_window(_stat: String) -> bool:
		return window

	func prevent_by_spell(caster: String, stat: String, amount: int) -> void:
		prevented.append([caster, stat, amount])

	func grant_spell_options(pid: String, verbs: Array) -> void:
		options[pid] = verbs


class MockGameState:
	extends Node
	var host: bool = true
	var players: Dictionary = {}
	var board_effects: Array = []
	var active_check: Dictionary = {}
	var _check_stack: Array = []
	var pending_spell_cast: Dictionary = {}
	var casting_spell: Dictionary = {}
	var last_cast_result: Dictionary = {}
	var roll_successes: int = 0
	var roll_dice: Array = []
	var spell_deck: Array = []  # колода копий {id, back}; пустая → grant замешает «сброс»
	var mythos_decision: Dictionary = {}
	var _check: StubCheck
	var _phase: StubPhase
	var _encounter: StubEncounter

	func _init() -> void:
		_check = StubCheck.new(self)
		_phase = StubPhase.new()
		_encounter = StubEncounter.new()

	func broadcast_and_emit() -> void:
		pass

	func is_host() -> bool:
		return host

	func name_of(pid: String) -> String:
		return pid

	func apply_board_effect(node: Dictionary) -> void:
		board_effects.append(node)


func before_each() -> void:
	# Свой каталог: data/spells.json генерится из CMS, обороты там правят авторы.
	SpellCatalog.use_fixture(DataLoader.load_array("res://test/fixtures/spells.json"))
	_gs = autofree(MockGameState.new())
	_sf = SpellFlow.new(_gs)


func after_each() -> void:
	SpellCatalog.use_fixture([])


func _player(items: Array = []) -> void:
	_gs.players["p"] = {
		"hp": 5,
		"hp_max": 7,
		"sanity": 5,
		"sanity_max": 6,
		"clues": 0,
		"conditions": [],
		"items": items,
		"skill_mods": {},
	}


# Форс конкретной рубашки для item_index 0.
func _force(back_id: String) -> Dictionary:
	return {"backs": {"0": back_id}}


# ── Фронт (onPass при успехе) ─────────────────────────────────────────────────


func test_pass_applies_front_effect() -> void:
	_player([{"id": "shriveling"}])
	# successes 2 → pass → front damageMonster (board); рубашка b1 тир 2+ → ничего.
	_sf.resolve_cast("p", 0, 2, [5, 5], _force("shriveling_b1"))
	var verbs: Array = []
	for i in range(_gs.board_effects.size()):
		verbs.append(String((_gs.board_effects[i] as Dictionary).get("do", "")))
	assert_has(verbs, "damageMonster", "фронт onPass применён при успехе")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 1, "карта остаётся (многоразовая)")


func test_fail_skips_front_effect() -> void:
	_player([{"id": "shriveling"}])
	# successes 0 → НЕ pass → фронт не применяется; рубашка b1 тир 0-1 → loseSanity 1.
	_sf.resolve_cast("p", 0, 0, [3, 4], _force("shriveling_b1"))
	assert_eq(_gs.board_effects.size(), 0, "фронт (damageMonster) не сработал")
	assert_eq(int(_gs.players["p"]["sanity"]), 4, "рубашка 0-1: −1 рассудок")


# ── Рубашка: тиры по числу успехов ────────────────────────────────────────────


func test_back_tier_by_success_count() -> void:
	_player([{"id": "shriveling"}])
	# Форс b2: тир 0 → gainCondition poisoned; тир 1+ → ничего.
	_sf.resolve_cast("p", 0, 0, [3, 4], _force("shriveling_b2"))
	assert_true((_gs.players["p"]["conditions"] as Array).has("poisoned"), "тир 0 рубашки b2")


func test_back_high_tier_no_effect() -> void:
	_player([{"id": "shriveling"}])
	_sf.resolve_cast("p", 0, 3, [5, 5, 6], _force("shriveling_b2"))
	assert_false(
		(_gs.players["p"]["conditions"] as Array).has("poisoned"), "3 успеха → тир 1+ (пусто)"
	)


# ── Сброс карты: discardCard в рубашке ────────────────────────────────────────


func test_conditional_discard_on_rolled_one() -> void:
	_player([{"id": "shriveling"}])
	# b1 тир 0-1: discardCard ТОЛЬКО если выпала 1. dice [1,3] → есть 1 → сброс.
	_sf.resolve_cast("p", 0, 0, [1, 3], _force("shriveling_b1"))
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "выпала 1 → карта сброшена")


func test_no_discard_without_rolled_one() -> void:
	_player([{"id": "shriveling"}])
	_sf.resolve_cast("p", 0, 0, [3, 4], _force("shriveling_b1"))
	assert_eq((_gs.players["p"]["items"] as Array).size(), 1, "без 1 — карта остаётся")


func test_unconditional_discard() -> void:
	_player([{"id": "wither"}])
	# wither b2 тир 0: gainCondition internalInjury + безусловный discardCard.
	_sf.resolve_cast("p", 0, 0, [3, 4], _force("wither_b2"))
	assert_true((_gs.players["p"]["conditions"] as Array).has("internalInjury"))
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "рубашка сбрасывает карту")


func test_wither_front_buffs_strength() -> void:
	_player([{"id": "wither"}])
	# pass → front improveSkill strength +3, но кап навыка +2 (SKILL_MOD_CAP).
	_sf.resolve_cast("p", 0, 2, [5, 5], _force("wither_b1"))
	assert_eq(int((_gs.players["p"]["skill_mods"] as Dictionary).get("strength", 0)), 2, "кап +2")


# ── Гварды ────────────────────────────────────────────────────────────────────


func test_non_host_rejected() -> void:
	_gs.host = false
	_player([{"id": "shriveling"}])
	assert_false(_sf.resolve_cast("p", 0, 2, [5, 5]))


func test_bad_index_rejected() -> void:
	_player([{"id": "shriveling"}])
	assert_false(_sf.resolve_cast("p", 5, 2, [5, 5]), "индекс вне инвентаря")


func test_unknown_spell_rejected() -> void:
	_player([{"id": "not_a_spell"}])
	assert_false(_sf.resolve_cast("p", 0, 2, [5, 5]), "id нет в каталоге заклинаний")


# ── grant_spell (board-verb gainSpell: розыгрыш реальной карты) ───────────────


func test_grant_spell_explicit_id() -> void:
	_player()
	_sf.grant_spell("p", "shriveling")
	var items: Array = _gs.players["p"]["items"]
	assert_eq(items.size(), 1, "карта добавлена")
	assert_eq(String((items[0] as Dictionary)["id"]), "shriveling")
	assert_eq(String((items[0] as Dictionary)["kind"]), "spell", "помечена как заклинание")
	var back: String = String((items[0] as Dictionary).get("back", ""))
	assert_true(back.begins_with("shriveling_b"), "выдана конкретная копия — рубашка закреплена")


func test_flow_back_overrides_instance_back() -> void:
	# flow.backs (детерминизм/тесты/replay) сильнее закреплённой рубашки копии.
	_player([{"id": "shriveling", "kind": "spell", "back": "shriveling_b1"}])
	_sf.resolve_cast("p", 0, 0, [3, 4], _force("shriveling_b2"))
	assert_true(
		(_gs.players["p"]["conditions"] as Array).has("poisoned"),
		"flow.backs (b2 → poisoned) бьёт instance.back (b1)"
	)


func test_cast_uses_fixed_back_of_the_copy() -> void:
	# Без форса переворачивается рубашка ЭТОЙ копии — и во второй каст та же.
	_player([{"id": "shriveling", "kind": "spell", "back": "shriveling_b2"}])
	_sf.resolve_cast("p", 0, 0, [3, 4])
	assert_eq(String(_gs.last_cast_result["back"]), "shriveling_b2", "первый каст — b2")
	assert_true((_gs.players["p"]["conditions"] as Array).has("poisoned"), "исход b2 при 0 успехов")
	_sf.resolve_cast("p", 0, 3, [5, 5, 6])
	assert_eq(String(_gs.last_cast_result["back"]), "shriveling_b2", "второй каст — та же копия")


func test_legacy_item_without_back_gets_random_back() -> void:
	_player([{"id": "shriveling", "kind": "spell"}])
	_sf.resolve_cast("p", 0, 3, [5, 5, 6])
	assert_true(
		String(_gs.last_cast_result["back"]).begins_with("shriveling_b"),
		"карта без back (легаси) — случайная рубашка заклинания"
	)


# ── Колода копий (reset_deck / assign_backs / замешивание) ────────────────────


func test_reset_deck_one_copy_per_back_minus_hands() -> void:
	_player([{"id": "shriveling", "kind": "spell"}])  # стартовое заклинание без рубашки
	_sf.reset_deck()
	var deck: Array = _gs.spell_deck
	var total: int = 0
	for s_v: Variant in SeasonGate.filter_room(SpellCatalog.all()):
		total += maxi(1, ((s_v as Dictionary).get("backs", []) as Array).size())
	assert_eq(deck.size(), total - 1, "копий = сумма оборотов минус карта в руке")
	var item: Dictionary = _gs.players["p"]["items"][0]
	assert_true(
		String(item.get("back", "")).begins_with("shriveling_b"),
		"стартовой карте назначена рубашка"
	)
	for c_v: Variant in deck:
		var c: Dictionary = c_v
		assert_false(
			String(c["id"]) == "shriveling" and String(c["back"]) == String(item["back"]),
			"копия из руки в колоде не лежит"
		)


func test_all_copies_in_hands_blocks_named_grant() -> void:
	_player()
	var n: int = (SpellCatalog.by_id("shriveling").get("backs", []) as Array).size()
	for _i in range(n):
		_sf.grant_spell("p", "shriveling")
	var items: Array = _gs.players["p"]["items"]
	assert_eq(items.size(), n, "выданы все копии")
	var backs: Dictionary = {}
	for it_v: Variant in items:
		backs[String((it_v as Dictionary)["back"])] = true
	assert_eq(backs.size(), n, "все рубашки разные — копии уникальны")
	_sf.grant_spell("p", "shriveling")
	assert_eq((_gs.players["p"]["items"] as Array).size(), n, "копий не осталось — карта не выдана")


func test_discarded_copy_returns_via_reshuffle() -> void:
	_player()
	var n: int = (SpellCatalog.by_id("shriveling").get("backs", []) as Array).size()
	for _i in range(n):
		_sf.grant_spell("p", "shriveling")
	# «Сбросили» одну копию: убрали из руки → она вне рук и вне колоды = в сбросе.
	var items: Array = _gs.players["p"]["items"]
	var dropped: String = String((items[0] as Dictionary)["back"])
	items.remove_at(0)
	_gs.players["p"]["items"] = items
	_sf.grant_spell("p", "shriveling")
	items = _gs.players["p"]["items"]
	assert_eq(items.size(), n, "копия вернулась через замешивание сброса")
	assert_eq(
		String((items[n - 1] as Dictionary)["back"]), dropped, "и это именно сброшенная копия"
	)


func test_grant_spell_random_from_catalog() -> void:
	_player()
	_sf.grant_spell("p")
	var items: Array = _gs.players["p"]["items"]
	assert_eq(items.size(), 1, "случайное заклинание выдано")
	assert_true(SpellCatalog.is_spell(String((items[0] as Dictionary)["id"])), "id из каталога")


func test_grant_spell_of_type() -> void:
	# «Получите заклинание-ритуал»: из колоды берётся заклинание нужного вида.
	_player()
	for _i in range(6):
		_sf.grant_spell("p", "", "glamour")
	for it_v: Variant in _gs.players["p"]["items"]:
		var sid: String = String((it_v as Dictionary)["id"])
		assert_eq(String(SpellCatalog.by_id(sid).get("subtype", "")), "glamour", sid)


func test_grant_spell_non_host_noop() -> void:
	_gs.host = false
	_player()
	_sf.grant_spell("p", "shriveling")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "не-хост не выдаёт")


func test_grant_spell_unknown_id_noop() -> void:
	_player()
	_sf.grant_spell("p", "no_such_spell")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "неизвестный id игнорируется")


# ── Ritual: begin (старт проверки) → apply (резолв + освобождение хода) ───────


func test_begin_ritual_starts_check_without_resolving() -> void:
	_player([{"id": "shriveling"}])
	assert_true(_sf.begin_ritual("p", 0), "каст начат")
	assert_eq(String(_gs.casting_spell.get("subtype", "")), "ritual")
	assert_eq(String(_gs.active_check.get("owner", "")), "spell", "spell-проверка")
	assert_false(bool(_gs.active_check.get("rolled", false)), "ещё не брошено")
	assert_eq(_gs.board_effects.size(), 0, "резолва пока нет")


func test_apply_ritual_pass_applies_front_clears_and_releases() -> void:
	_player([{"id": "shriveling"}])
	_gs.roll_successes = 2
	_gs.roll_dice = [5, 5]
	_sf.begin_ritual("p", 0)
	_sf.roll_cast("p")
	assert_true(_sf.apply_cast("p", _force("shriveling_b1")), "применено")
	var verbs: Array = []
	for i in range(_gs.board_effects.size()):
		verbs.append(String((_gs.board_effects[i] as Dictionary).get("do", "")))
	assert_has(verbs, "damageMonster", "фронт onPass при успехе")
	assert_eq(_gs.active_check.size(), 0, "проверка снята")
	assert_eq(_gs.casting_spell.size(), 0, "casting_spell очищен")
	assert_eq(_gs._phase.released, ["p"], "ход освобождён (ritual)")


func test_apply_ritual_fail_resolves_back_discard() -> void:
	_player([{"id": "shriveling"}])
	_gs.roll_successes = 0
	_gs.roll_dice = [1, 3]  # выпала 1 → рубашка b1 сбрасывает карту
	_sf.begin_ritual("p", 0)
	_sf.apply_cast("p", _force("shriveling_b1"))  # без явного roll — apply докинет бросок
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "рубашка сбросила карту")


func test_begin_ritual_rejects_incantation() -> void:
	_player([{"id": "wither"}])  # subtype incantation — не Ritual
	assert_false(_sf.begin_ritual("p", 0), "Incantation не кастуется как Ritual-действие")
	assert_true(_gs.casting_spell.is_empty(), "каст не начат")


func test_begin_ritual_non_host_rejected() -> void:
	_gs.host = false
	_player([{"id": "shriveling"}])
	assert_false(_sf.begin_ritual("p", 0))


func test_begin_ritual_bad_index_rejected() -> void:
	_player([{"id": "shriveling"}])
	assert_false(_sf.begin_ritual("p", 9))


# ── Incantation: begin push боя → apply pop (вложенная проверка) ──────────────


func test_begin_incantation_pushes_combat_and_starts_spell() -> void:
	_player([{"id": "wither"}])
	_gs.active_check = {
		"owner": "combat", "context": "combatEncounter", "rolled": true, "dice": [4]
	}
	assert_true(_sf.begin_incantation("p", 0))
	assert_eq((_gs._check_stack as Array).size(), 1, "боевая проверка сохранена в стек")
	assert_eq(String(_gs.active_check.get("owner", "")), "spell", "поверх — spell-проверка")


func test_apply_incantation_applies_front_and_restores_combat() -> void:
	_player([{"id": "wither"}])
	var combat: Dictionary = {"owner": "combat", "context": "combatEncounter", "rolled": true}
	_gs.active_check = combat.duplicate(true)
	_gs.roll_successes = 2
	_gs.roll_dice = [5, 5]
	_sf.begin_incantation("p", 0)
	_sf.roll_cast("p")
	assert_true(_sf.apply_cast("p", {"backs": {"0": "wither_b1"}}))
	assert_eq(
		int((_gs.players["p"]["skill_mods"] as Dictionary).get("strength", 0)),
		0,
		"«+3 Силы в этой встрече» — не жетон навсегда"
	)
	assert_eq(String(_gs.active_check.get("owner", "")), "combat", "боевая проверка вернулась")
	var mods: Array = _gs.active_check.get("active_mods", [])
	assert_eq(mods.size(), 1, "+3 Силы — временный мод боевой проверки")
	assert_eq(String((mods[0] as Dictionary).get("skill", "")), "strength")
	assert_eq(int((mods[0] as Dictionary).get("amount", 0)), 3)
	assert_eq((_gs._check_stack as Array).size(), 0, "стек пуст")
	assert_eq(_gs._phase.released, [], "incantation не освобождает ход")


func test_begin_incantation_requires_combat_context() -> void:
	_player([{"id": "wither"}])
	_gs.active_check = {}  # нет боевой проверки
	assert_false(_sf.begin_incantation("p", 0))
	assert_eq((_gs._check_stack as Array).size(), 0, "без боя — ничего не сохранили")


func test_begin_incantation_rejects_ritual() -> void:
	_player([{"id": "shriveling"}])  # subtype ritual
	_gs.active_check = {"context": "combatEncounter"}
	assert_false(_sf.begin_incantation("p", 0), "Ritual не кастуется как Incantation")


# ── Glamour: begin (exhaust + старт) → apply (рубашка; ход не тратится) ───────


func test_begin_glamour_exhausts_and_starts_check() -> void:
	_player([{"id": "mind_s_eye"}])
	assert_true(_sf.begin_glamour("p", 0))
	assert_true(
		bool(_gs.players["p"]["items"][0]["exhausted"]), "⟳ истощает на старте (oncePerRound)"
	)
	assert_eq(String(_gs.active_check.get("owner", "")), "spell")


func test_apply_glamour_resolves_back_no_turn_release() -> void:
	_player([{"id": "mind_s_eye"}])
	_gs.roll_successes = 0
	_gs.roll_dice = [3]
	_sf.begin_glamour("p", 0)
	_sf.apply_cast("p", {"backs": {"0": "mind_s_eye_b1"}})
	assert_eq(int(_gs.players["p"]["sanity"]), 4, "рубашка 0-1: −1 рассудок")
	assert_eq(_gs._phase.released, [], "glamour не освобождает ход")


func test_begin_glamour_rejects_exhausted() -> void:
	_player([{"id": "mind_s_eye", "exhausted": true}])
	assert_false(_sf.begin_glamour("p", 0), "истощённая карта не кастуется")


func test_begin_glamour_rejects_non_glamour() -> void:
	_player([{"id": "shriveling"}])
	assert_false(_sf.begin_glamour("p", 0), "Ritual — не glamour")


# ── fire_trigger (игровое событие → каст заклинания с front.trigger == event) ─


func test_fire_trigger_on_rest_heals() -> void:
	_player([{"id": "healing_words"}])
	_gs.players["p"]["hp"] = 3
	_gs.players["p"]["sanity"] = 3
	var flow: Dictionary = {
		"cast": {"successes": 2, "dice": [5, 5]}, "backs": {"0": "healing_words_b1"}
	}
	assert_true(_sf.fire_trigger("p", "onRest", flow), "Healing Words сработал на onRest")
	assert_eq(int(_gs.players["p"]["hp"]), 4, "+1 здоровья (фронт onPass)")
	assert_eq(int(_gs.players["p"]["sanity"]), 4, "+1 рассудка")


func test_fire_trigger_fires_all_matching() -> void:
	# Несколько onRest-заклинаний в руке → срабатывают ВСЕ (а не только первое):
	# два экземпляра healing_words (+1 hp/+1 san каждый). Рубашки b1 на 2 успехах
	# = тир «2+» пуст, без побочки.
	_player([{"id": "healing_words"}, {"id": "healing_words"}])
	_gs.players["p"]["hp"] = 3
	_gs.players["p"]["sanity"] = 3
	var flow: Dictionary = {
		"cast": {"successes": 2, "dice": [5, 5]},
		"backs": {"0": "healing_words_b1", "1": "healing_words_b1"},
	}
	assert_true(_sf.fire_trigger("p", "onRest", flow), "сработало хотя бы одно")
	assert_eq(int(_gs.players["p"]["hp"]), 5, "оба healing_words → +2 hp")
	assert_eq(int(_gs.players["p"]["sanity"]), 5, "оба healing_words → +2 рассудка")


func test_fire_trigger_no_matching_spell() -> void:
	_player([{"id": "shriveling"}])  # trigger action, не onRest
	assert_false(_sf.fire_trigger("p", "onRest"))


func test_fire_trigger_empty_hand() -> void:
	_player([])
	assert_false(_sf.fire_trigger("p", "onRest"))


# ── last_cast_result (модалка расплаты: какой оборот + flavor + итог) ─────────


func test_cast_sets_result_with_flavor_and_outcome() -> void:
	_player([{"id": "shriveling"}])
	# b2, 0 успехов → тир 0: poisoned. Результат несёт оборот, flavor-ключ, итог.
	_sf.resolve_cast("p", 0, 0, [3, 4], _force("shriveling_b2"))
	var r: Dictionary = _gs.last_cast_result
	assert_eq(String(r["spell"]), "shriveling")
	assert_eq(String(r["back"]), "shriveling_b2", "выпавший оборот")
	assert_eq(String(r["text"]), "RECK_SHRIVELING_B2_T1", "флейвор выпавшего яруса")
	assert_eq(int(r["successes"]), 0)
	assert_has(
		(r["outcome"] as Dictionary).get("conditions", []), "poisoned", "итог: новое состояние"
	)


func test_cast_result_text_falls_back_to_back() -> void:
	_player([{"id": "shriveling"}])
	# У яруса 1+ своего текста нет — флейвор оборота целиком.
	_sf.resolve_cast("p", 0, 3, [5, 5, 6], _force("shriveling_b2"))
	assert_eq(String(_gs.last_cast_result["text"]), "RECK_SHRIVELING_B2")


func test_cast_result_averted_on_high_successes() -> void:
	_player([{"id": "shriveling"}])
	# b2, 3 успеха → тир 1+ пуст → расплаты нет (outcome пуст = «обошлось»).
	_sf.resolve_cast("p", 0, 3, [5, 5, 6], _force("shriveling_b2"))
	assert_true((_gs.last_cast_result["outcome"] as Dictionary).is_empty(), "обошлось — итог пуст")


# ── prompt_trigger / host_apply_trigger_spells (опциональный onRest) ──────────


func test_prompt_trigger_sets_pending() -> void:
	# Два onRest-заклинания + ритуал → промпт собирает ТОЛЬКО onRest.
	_player([{"id": "healing_words"}, {"id": "shriveling"}, {"id": "healing_words"}])
	assert_true(_sf.prompt_trigger("p", "onRest"), "есть onRest → промпт выставлен")
	var prompt: Dictionary = _gs.pending_spell_cast
	assert_eq(String(prompt["pid"]), "p")
	assert_eq(String(prompt["event"]), "onRest")
	var opts: Array = prompt["options"]
	assert_eq(opts.size(), 2, "shriveling (ритуал) не попал в onRest-промпт")
	assert_eq(int((opts[0] as Dictionary)["index"]), 0, "healing_words idx 0")
	assert_eq(int((opts[1] as Dictionary)["index"]), 2, "второй healing_words idx 2")


func test_prompt_trigger_no_matches_returns_false() -> void:
	_player([{"id": "shriveling"}])  # ритуал, не onRest
	assert_false(_sf.prompt_trigger("p", "onRest"))
	assert_true((_gs.pending_spell_cast as Dictionary).is_empty(), "промпт не выставлен")


func test_apply_trigger_casts_only_selected() -> void:
	# Промпт на две onRest-карты; игрок выбрал ТОЛЬКО вторую (idx 1).
	_player([{"id": "healing_words"}, {"id": "healing_words"}])
	_gs.players["p"]["hp"] = 3
	_gs.players["p"]["sanity"] = 3
	_sf.prompt_trigger("p", "onRest")
	var flow: Dictionary = {
		"cast": {"successes": 2, "dice": [5, 5]}, "backs": {"1": "healing_words_b1"}
	}
	assert_true(_sf.host_apply_trigger_spells("p", [1], flow), "промпт закрыт")
	assert_eq(int(_gs.players["p"]["hp"]), 4, "только выбранный healing_words → +1 hp")
	assert_eq(int(_gs.players["p"]["sanity"]), 4, "кастован один из двух, не оба")
	assert_true((_gs.pending_spell_cast as Dictionary).is_empty(), "промпт очищен")


func test_apply_trigger_rejects_unoffered_index() -> void:
	# Клиент прислал индекс вне предложенных → каста нет, но промпт закрываем.
	_player([{"id": "healing_words"}])  # onRest idx 0
	_gs.players["p"]["hp"] = 3
	_sf.prompt_trigger("p", "onRest")
	assert_true(_sf.host_apply_trigger_spells("p", [5], {"cast": {"successes": 2, "dice": [5, 5]}}))
	assert_eq(int(_gs.players["p"]["hp"]), 3, "несуществующий индекс — каста нет")
	assert_true((_gs.pending_spell_cast as Dictionary).is_empty())


func test_apply_trigger_wrong_pid_rejected() -> void:
	_player([{"id": "healing_words"}])
	_sf.prompt_trigger("p", "onRest")
	assert_false(_sf.host_apply_trigger_spells("q", [0]), "чужой pid не резолвит промпт")
	assert_false((_gs.pending_spell_cast as Dictionary).is_empty(), "промпт остался для p")


# ── Poison Mist: фронт discardMonster по стойкости (через resolve_cast) ────────


func test_poison_mist_emits_monster_discard_by_toughness() -> void:
	_player([{"id": "poison_mist"}])
	# successes 3 → pass → фронт discardMonster maxToughness:"testResult" на доску.
	_sf.resolve_cast("p", 0, 3, [5, 5, 6], _force("poison_mist_b1"))
	var hit: bool = false
	for i in range(_gs.board_effects.size()):
		var n: Dictionary = _gs.board_effects[i]
		if (
			String(n.get("do", "")) == "discardMonster"
			and String(n.get("maxToughness", "")) == "testResult"
		):
			hit = true
			assert_eq(int(n.get("_successes", 0)), 3, "_successes = результат каста")
	assert_true(hit, "Poison Mist эмитит discardMonster по стойкости")


func test_spell_card_uses_own_frame_and_zones() -> void:
	# Фиолетовая рамка заклинания: плашка и пергамент выше, чем у актива — свои зоны.
	var p: Dictionary = SpellCatalog.card_payload(SpellCatalog.by_id("shriveling"))
	assert_eq(p.get("base_frame"), SpellCatalog.FRAME, "рамка заклинания")
	assert_eq((p.get("zones", {}) as Dictionary).get("title"), SpellCatalog.Z_TITLE)
	assert_eq((p.get("zones", {}) as Dictionary).get("desc"), SpellCatalog.Z_DESC)
	var tone: Dictionary = p.get("art_tone", {})
	assert_gt(float(tone.get("amount", 0.0)), 0.0, "арт подгоняется под сиреневый тон рамки")
	assert_eq(tone.get("mid"), SpellCatalog.TONE_MID)


# ── Контент из CMS (data/spells.json): каждый ярус каждого оборота разыгрывается ──


func test_content_every_tier_resolves_with_own_text() -> void:
	SpellCatalog.use_fixture([])  # реальный каталог, не фикстура
	var spells: Array = SpellCatalog.all()
	assert_gt(spells.size(), 0, "каталог заклинаний не пуст")
	for s_v: Variant in spells:
		var s: Dictionary = s_v
		var sid: String = String(s.get("id", ""))
		for b_v: Variant in s.get("backs", []):
			var back: Dictionary = b_v
			for succ: int in range(5):
				_player([{"id": sid}])
				_gs.board_effects.clear()
				_sf.resolve_cast("p", 0, succ, [1, 4, 5, 6], _force(String(back.get("id", ""))))
				var r: Dictionary = _gs.last_cast_result
				assert_eq(String(r.get("back", "")), String(back.get("id", "")), sid)
				var key: String = String(r.get("text", ""))
				# Ярусы с текстом (новые обороты) — ключ должен быть переведён.
				if key.begins_with("RECK_") and key.contains("_T"):
					assert_ne(tr(key), key, "%s: нет перевода %s" % [sid, key])


# ── Вопросы каста игроку (interactive): «X, иначе сбросьте карту», навык на выбор ──


# Ритуал брошен с successes и применён (каст через модалку — interactive).
func _apply_ritual(spell_id: String, successes: int) -> void:
	_player([{"id": spell_id}])
	_gs.players["p"]["casting"] = true
	assert_true(_sf.begin_ritual("p", 0))
	_gs.roll_successes = successes
	_gs.roll_dice = [1, 2, 3]
	assert_true(_sf.apply_cast("p"))


func test_unless_discard_asks_player() -> void:
	_apply_ritual("fx_unless", 0)
	var md: Dictionary = _gs.mythos_decision
	assert_eq(String(md.get("driver", "")), "spell", "вопрос каста — в модалку решения")
	assert_eq((md.get("options", []) as Array).size(), 2, "−2 рассудка / сбросить карту")
	assert_true(_sf.busy())
	assert_eq(_gs._phase.released, [], "ход ритуала держится до ответа")
	_sf.resolve_decision("p", 1)  # сбросить карту
	assert_eq(int(_gs.players["p"]["sanity"]), 5, "рассудок цел")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "карта сброшена")
	assert_true(_gs.mythos_decision.is_empty())
	assert_eq(_gs._phase.released, ["p"], "ответ получен — ход отпущен")
	assert_false(_sf.busy())


func test_unless_discard_keep_card() -> void:
	_apply_ritual("fx_unless", 0)
	_sf.resolve_decision("p", 0)  # заплатить рассудком
	assert_eq(int(_gs.players["p"]["sanity"]), 3)
	assert_eq((_gs.players["p"]["items"] as Array).size(), 1, "карта осталась")


func test_skill_of_choice() -> void:
	_apply_ritual("fx_feed", 1)
	assert_eq((_gs.mythos_decision.get("options", []) as Array).size(), 5, "пять навыков")
	_sf.resolve_decision("p", 2)
	var mods: Dictionary = _gs.players["p"]["skill_mods"]
	assert_eq(mods.size(), 1, "улучшен ровно один навык")


func test_new_cast_blocked_while_asking() -> void:
	_apply_ritual("fx_unless", 0)
	(_gs.players["p"]["items"] as Array).append({"id": "fx_feed"})
	assert_false(_sf.begin_ritual("p", 1), "пока каст ждёт ответа — новый не начать")


# ── Ярус оборота меняет обстановку каста ────────────────────────────────────


func test_tier_check_mods_go_to_combat() -> void:
	_player([{"id": "fx_wither"}])
	_gs.active_check = {"owner": "combat", "context": "combatEncounter", "rolled": true}
	assert_true(_sf.begin_incantation("p", 0))
	_gs.roll_successes = 2
	_gs.roll_dice = [5, 6]
	assert_true(_sf.apply_cast("p"))
	var verbs: Array = []
	for m_v: Variant in _gs.active_check.get("active_mods", []):
		verbs.append(
			(
				"%s:%d"
				% [
					(m_v as Dictionary).get("do", ""),
					int((m_v as Dictionary).get("amount", (m_v as Dictionary).get("count", 0)))
				]
			)
		)
	assert_eq(
		verbs, ["improveSkill:3", "improveSkill:5", "rerollDice:1"], "+3 и «+5 вместо» + переброс"
	)
	assert_eq(int((_gs.players["p"]["skill_mods"] as Dictionary).get("strength", 0)), 0)


func test_tier_add_successes_seen_by_front() -> void:
	_player([{"id": "fx_mist_succ"}])
	_sf.resolve_cast("p", 0, 3, [5, 5, 6])
	var n: Dictionary = _gs.board_effects[0]
	assert_eq(String(n.get("do", "")), "discardMonster")
	assert_eq(int(n.get("_successes", 0)), 5, "3 успеха + 2 с оборота")


# ── Реакция на потерю (Защита плоти / Вселить отвагу) ───────────────────────


func _cast_ward(successes: int) -> void:
	_player([{"id": "fx_ward"}])
	_gs.active_check = {"owner": "combat", "context": "combatEncounter", "rolled": true}
	assert_true(_sf.begin_incantation("p", 0))
	assert_eq(String(_gs.casting_spell.get("reaction", "")), "health")
	assert_true(bool(_gs.players["p"]["items"][0]["exhausted"]), "раз в раунд")
	_gs.roll_successes = successes
	_gs.roll_dice = [5, 5, 5]
	assert_true(_sf.apply_cast("p"))


func test_reaction_prevents_loss() -> void:
	_cast_ward(1)
	assert_eq(_gs._encounter.prevented, [["p", "health", 2]])
	assert_eq(String(_gs.active_check.get("owner", "")), "combat", "бой вернулся")


func test_reaction_stronger_on_good_roll() -> void:
	_cast_ward(3)
	assert_eq(_gs._encounter.prevented, [["p", "health", 4]], "«до 4 вместо этого»")


func test_reaction_needs_open_window() -> void:
	_player([{"id": "fx_ward"}])
	_gs._encounter.window = false
	assert_false(_sf.begin_incantation("p", 0), "потери не видно — каст не начать")


func test_reaction_once_per_round() -> void:
	_cast_ward(1)
	assert_false(_sf.begin_incantation("p", 0), "истощена до Refresh")


func test_prompt_spells_not_cast_from_hand() -> void:
	_player([{"id": "healing_words"}, {"id": "fx_mists"}])
	_gs.active_check = {"owner": "combat", "context": "combatEncounter", "rolled": true}
	assert_false(_sf.begin_incantation("p", 0), "onRest — только из промпта отдыха")
	assert_false(_sf.begin_incantation("p", 1), "фаза встреч — только из её промпта")


# ── Фаза встреч и очередь триггер-кастов ────────────────────────────────────


func test_encounter_spell_grants_options_then_continues() -> void:
	_player([{"id": "fx_mists"}])
	assert_true(_sf.prompt_trigger("p", "encounterPhase"))
	var done: Array = []
	_sf.host_apply_trigger_spells(
		"p", [0], {"cast": {"successes": 1, "dice": [5]}}, func() -> void: done.append(true)
	)
	assert_eq(_gs._encounter.options.get("p", []), ["ignoreMonsters"])
	assert_eq(done, [true], "касты доиграны — продолжение хода")


func test_trigger_queue_waits_for_answer() -> void:
	_player([{"id": "fx_unless"}])
	_gs.pending_spell_cast = {
		"pid": "p", "event": "x", "options": [{"index": 0, "id": "fx_unless"}]
	}
	var done: Array = []
	_sf.host_apply_trigger_spells(
		"p", [0], {"cast": {"successes": 0, "dice": [2]}}, func() -> void: done.append(true)
	)
	assert_eq(done, [], "ждём ответа на вопрос оборота")
	_sf.resolve_decision("p", 0)
	assert_eq(done, [true])
