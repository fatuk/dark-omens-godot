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
