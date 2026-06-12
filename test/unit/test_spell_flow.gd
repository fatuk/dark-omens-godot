extends GutTest

## Юнит-тесты каста заклинаний (scripts/core/game/spell_flow.gd). Двусторонняя
## карта: каст → фронт onPass (при pass) → flip к рубашке → tiers по числу успехов
## → discard/назад на фронт. Детерминизм: явные successes/dice + flow.backs (форс
## рубашки). Данные — реальный data/spells.json (через SpellCatalog).

var _gs: MockGameState
var _sf: SpellFlow


# Стаб CheckFlow: бросок «каста» отдаёт заданные successes/dice в active_check.
class StubCheck:
	extends RefCounted
	var _gs: Node

	func _init(gs: Node) -> void:
		_gs = gs

	func start(_owner: String, _pid: String, _skill: String, _mod: int, _ctx: String) -> void:
		pass

	func roll(_pid: String) -> bool:
		_gs.active_check = {"successes": _gs.roll_successes, "dice": _gs.roll_dice}
		return true

	func clear() -> void:
		_gs.active_check = {}


class MockGameState:
	extends Node
	var host: bool = true
	var players: Dictionary = {}
	var board_effects: Array = []
	var active_check: Dictionary = {}
	var pending_spell_cast: Dictionary = {}
	var last_cast_result: Dictionary = {}
	var roll_successes: int = 0
	var roll_dice: Array = []
	var _check: StubCheck

	func _init() -> void:
		_check = StubCheck.new(self)

	func _is_host() -> bool:
		return host

	func _name_of(pid: String) -> String:
		return pid

	func _apply_board_effect(node: Dictionary) -> void:
		board_effects.append(node)


func before_each() -> void:
	_gs = autofree(MockGameState.new())
	_sf = SpellFlow.new(_gs)


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
	# pass → front improveSkill strength +3; b1 тир 2+ → ничего.
	_sf.resolve_cast("p", 0, 2, [5, 5], _force("wither_b1"))
	assert_eq(int((_gs.players["p"]["skill_mods"] as Dictionary).get("strength", 0)), 3)


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
	assert_false(
		(items[0] as Dictionary).has("back"), "рубашка НЕ фиксируется — тянется заново каждый каст"
	)


func test_flow_back_overrides_instance_back() -> void:
	# Рубашка тянется заново при касте → даже если на экземпляре завалялся back,
	# он игнорируется, а flow.backs форсит конкретную рубашку (детерминизм/тесты).
	_player([{"id": "shriveling", "kind": "spell", "back": "shriveling_b1"}])
	_sf.resolve_cast("p", 0, 0, [3, 4], _force("shriveling_b2"))
	assert_true(
		(_gs.players["p"]["conditions"] as Array).has("poisoned"),
		"flow.backs (b2 → poisoned) бьёт залежавшийся instance.back (b1)"
	)


func test_grant_spell_random_from_catalog() -> void:
	_player()
	_sf.grant_spell("p")
	var items: Array = _gs.players["p"]["items"]
	assert_eq(items.size(), 1, "случайное заклинание выдано")
	assert_true(SpellCatalog.is_spell(String((items[0] as Dictionary)["id"])), "id из каталога")


func test_grant_spell_non_host_noop() -> void:
	_gs.host = false
	_player()
	_sf.grant_spell("p", "shriveling")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "не-хост не выдаёт")


func test_grant_spell_unknown_id_noop() -> void:
	_player()
	_sf.grant_spell("p", "no_such_spell")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "неизвестный id игнорируется")


# ── cast_ritual (Ritual: каст = тест Lore через CheckFlow → resolve) ──────────


func test_cast_ritual_pass_applies_front_and_clears() -> void:
	_player([{"id": "shriveling"}])
	_gs.roll_successes = 2
	_gs.roll_dice = [5, 5]
	assert_true(_sf.cast_ritual("p", 0, _force("shriveling_b1")), "каст выполнен")
	var verbs: Array = []
	for i in range(_gs.board_effects.size()):
		verbs.append(String((_gs.board_effects[i] as Dictionary).get("do", "")))
	assert_has(verbs, "damageMonster", "фронт onPass при успехе")
	assert_eq(_gs.active_check.size(), 0, "проверка очищена после каста")


func test_cast_ritual_fail_resolves_back() -> void:
	_player([{"id": "shriveling"}])
	_gs.roll_successes = 0
	_gs.roll_dice = [1, 3]  # выпала 1 → рубашка b1 сбрасывает карту
	assert_true(_sf.cast_ritual("p", 0, _force("shriveling_b1")))
	assert_eq((_gs.players["p"]["items"] as Array).size(), 0, "рубашка сбросила карту")


func test_cast_ritual_rejects_incantation() -> void:
	_player([{"id": "wither"}])  # subtype incantation — не Ritual
	assert_false(_sf.cast_ritual("p", 0), "Incantation не кастуется как Ritual-действие")
	assert_eq((_gs.players["p"]["items"] as Array).size(), 1, "карта не тронута")


func test_cast_ritual_non_host_rejected() -> void:
	_gs.host = false
	_player([{"id": "shriveling"}])
	assert_false(_sf.cast_ritual("p", 0))


func test_cast_ritual_bad_index_rejected() -> void:
	_player([{"id": "shriveling"}])
	assert_false(_sf.cast_ritual("p", 9))


# ── cast_incantation (контекстный, combat-гейт, транзиентный тест Lore) ───────


func test_cast_incantation_in_combat_applies_front() -> void:
	_player([{"id": "wither"}])
	_gs.active_check = {"context": "combatEncounter"}
	var flow: Dictionary = {"cast": {"successes": 2, "dice": [5, 5]}, "backs": {"0": "wither_b1"}}
	assert_true(_sf.cast_incantation("p", 0, flow))
	assert_eq(int((_gs.players["p"]["skill_mods"] as Dictionary).get("strength", 0)), 3, "+3 Силы")


func test_cast_incantation_requires_combat_context() -> void:
	_player([{"id": "wither"}])
	_gs.active_check = {}  # нет боевой проверки
	assert_false(_sf.cast_incantation("p", 0, {"cast": {"successes": 2, "dice": [5, 5]}}))


func test_cast_incantation_rejects_ritual() -> void:
	_player([{"id": "shriveling"}])  # subtype ritual
	_gs.active_check = {"context": "combatEncounter"}
	assert_false(_sf.cast_incantation("p", 0), "Ritual не кастуется как Incantation")


func test_cast_incantation_non_host_rejected() -> void:
	_gs.host = false
	_player([{"id": "wither"}])
	assert_false(_sf.cast_incantation("p", 0))


# ── cast_glamour (⟳: exhaust + тест Lore → рубашка; аура — отдельно) ──────────


func test_cast_glamour_exhausts_and_resolves_back() -> void:
	_player([{"id": "mind_s_eye"}])
	var flow: Dictionary = {"cast": {"successes": 0, "dice": [3]}, "backs": {"0": "mind_s_eye_b1"}}
	assert_true(_sf.cast_glamour("p", 0, flow))
	assert_true(bool(_gs.players["p"]["items"][0]["exhausted"]), "⟳ истощает карту (oncePerRound)")
	assert_eq(int(_gs.players["p"]["sanity"]), 4, "рубашка 0-1: −1 рассудок")


func test_cast_glamour_rejects_exhausted() -> void:
	_player([{"id": "mind_s_eye", "exhausted": true}])
	assert_false(_sf.cast_glamour("p", 0), "истощённая карта не кастуется")


func test_cast_glamour_rejects_non_glamour() -> void:
	_player([{"id": "shriveling"}])
	assert_false(_sf.cast_glamour("p", 0), "Ritual — не glamour")


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
	# healing_words (+1 hp/+1 san) и mending_trance (+2 hp). Рубашки b1 на 2 успехах
	# = тир «2+» пуст, без побочки.
	_player([{"id": "healing_words"}, {"id": "mending_trance"}])
	_gs.players["p"]["hp"] = 3
	_gs.players["p"]["sanity"] = 3
	var flow: Dictionary = {
		"cast": {"successes": 2, "dice": [5, 5]},
		"backs": {"0": "healing_words_b1", "1": "mending_trance_b1"},
	}
	assert_true(_sf.fire_trigger("p", "onRest", flow), "сработало хотя бы одно")
	assert_eq(int(_gs.players["p"]["hp"]), 6, "healing_words +1 и mending_trance +2 → +3 hp")
	assert_eq(int(_gs.players["p"]["sanity"]), 4, "healing_words +1 рассудка")


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
	assert_eq(String(r["text"]), "RECK_SHRIVELING_B2", "flavor-ключ расплаты")
	assert_eq(int(r["successes"]), 0)
	assert_has(
		(r["outcome"] as Dictionary).get("conditions", []), "poisoned", "итог: новое состояние"
	)


func test_cast_result_averted_on_high_successes() -> void:
	_player([{"id": "shriveling"}])
	# b2, 3 успеха → тир 1+ пуст → расплаты нет (outcome пуст = «обошлось»).
	_sf.resolve_cast("p", 0, 3, [5, 5, 6], _force("shriveling_b2"))
	assert_true((_gs.last_cast_result["outcome"] as Dictionary).is_empty(), "обошлось — итог пуст")


# ── prompt_trigger / host_apply_trigger_spells (опциональный onRest) ──────────


func test_prompt_trigger_sets_pending() -> void:
	# Два onRest-заклинания + ритуал → промпт собирает ТОЛЬКО onRest.
	_player([{"id": "healing_words"}, {"id": "shriveling"}, {"id": "mending_trance"}])
	assert_true(_sf.prompt_trigger("p", "onRest"), "есть onRest → промпт выставлен")
	var prompt: Dictionary = _gs.pending_spell_cast
	assert_eq(String(prompt["pid"]), "p")
	assert_eq(String(prompt["event"]), "onRest")
	var opts: Array = prompt["options"]
	assert_eq(opts.size(), 2, "shriveling (ритуал) не попал в onRest-промпт")
	assert_eq(int((opts[0] as Dictionary)["index"]), 0, "healing_words idx 0")
	assert_eq(int((opts[1] as Dictionary)["index"]), 2, "mending_trance idx 2")


func test_prompt_trigger_no_matches_returns_false() -> void:
	_player([{"id": "shriveling"}])  # ритуал, не onRest
	assert_false(_sf.prompt_trigger("p", "onRest"))
	assert_true((_gs.pending_spell_cast as Dictionary).is_empty(), "промпт не выставлен")


func test_apply_trigger_casts_only_selected() -> void:
	# Промпт на две onRest-карты; игрок выбрал ТОЛЬКО mending_trance (idx 1).
	_player([{"id": "healing_words"}, {"id": "mending_trance"}])
	_gs.players["p"]["hp"] = 3
	_gs.players["p"]["sanity"] = 3
	_sf.prompt_trigger("p", "onRest")
	var flow: Dictionary = {
		"cast": {"successes": 2, "dice": [5, 5]}, "backs": {"1": "mending_trance_b1"}
	}
	assert_true(_sf.host_apply_trigger_spells("p", [1], flow), "промпт закрыт")
	assert_eq(int(_gs.players["p"]["hp"]), 5, "mending_trance +2 hp")
	assert_eq(int(_gs.players["p"]["sanity"]), 3, "healing_words НЕ кастовали")
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
