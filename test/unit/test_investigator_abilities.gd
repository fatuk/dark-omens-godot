extends GutTest

## Юнит-тесты способностей сыщика: спец-действие (ability.do) и пассив (passive.mods).
## Оба поля НЕОБЯЗАТЕЛЬНЫЕ — данные пока пустые, механику наполняет автор руками,
## поэтому тесты подменяют кэш Investigators фикстурой и проверяют КОНТРАКТ:
##   • какие глаголы пассив пускает в проверку, а какие отбрасывает;
##   • фильтр по контексту проверки;
##   • что CheckFlow сидирует пассив в active_mods при создании ЛЮБОЙ проверки;
##   • что сыщик без способностей ведёт себя ровно как раньше (пустой active_mods).

var _saved: Dictionary = {}

const INV := "Fixture Investigator"
const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")


func before_each() -> void:
	# Подменяем кэш каталога фикстурой (реальные сыщики способностей пока не имеют).
	Investigators._ensure_loaded()
	_saved = Investigators._by_name.duplicate(true)


func after_each() -> void:
	Investigators._by_name = _saved


# Кладёт в кэш сыщика с заданными ability/passive.
func _fixture(ability: Dictionary = {}, passive: Dictionary = {}) -> void:
	var inv: Dictionary = {"name": INV, "skills": {"will": 3, "lore": 2}}
	if not ability.is_empty():
		inv["ability"] = ability
	if not passive.is_empty():
		inv["passive"] = passive
	Investigators._by_name[INV] = inv


# ── Спец-действие ─────────────────────────────────────────────────────────────


func test_no_ability_by_default() -> void:
	_fixture()
	assert_false(Investigators.has_ability(INV), "без поля ability способности нет")
	assert_eq(Investigators.ability_program(INV), [], "программа пуста")


func test_ability_program_read() -> void:
	_fixture({"name": "ABIL", "do": [{"do": "gainClue", "count": 1}]})
	assert_true(Investigators.has_ability(INV))
	assert_eq((Investigators.ability_program(INV) as Array).size(), 1)
	assert_eq(String(Investigators.ability(INV).get("name", "")), "ABIL", "подпись для кнопки")


func test_ability_with_empty_program_is_not_usable() -> void:
	_fixture({"name": "ABIL", "do": []})
	assert_false(Investigators.has_ability(INV), "пустая программа — кнопки быть не должно")


# ── Пассив: фильтр глаголов ───────────────────────────────────────────────────


func test_passive_accepts_check_mod_verb() -> void:
	_fixture({}, {"mods": [{"do": "rerollDice", "count": 1}]})
	var mods: Array = Investigators.passive_check_mods(INV, "anyTest")
	assert_eq(mods.size(), 1, "check-mod-глагол проходит")
	assert_eq(String((mods[0] as Dictionary).get("do", "")), "rerollDice")


func test_passive_rejects_non_check_verb() -> void:
	# gainClue меняет игрока, а не проверку: как пассив он не поддержан (нужен
	# отдельный слой правил) — молча отбрасываем, а не роняем проверку.
	_fixture({}, {"mods": [{"do": "gainClue", "count": 1}]})
	assert_eq(Investigators.passive_check_mods(INV, "anyTest"), [], "не-check-глагол отброшен")


func test_passive_context_filter() -> void:
	_fixture({}, {"mods": [{"do": "addToDie", "amount": 1, "context": "combat"}]})
	assert_eq(Investigators.passive_check_mods(INV, "combat").size(), 1, "свой контекст — да")
	assert_eq(Investigators.passive_check_mods(INV, "encounter"), [], "чужой контекст — нет")


func test_passive_without_context_applies_everywhere() -> void:
	_fixture({}, {"mods": [{"do": "improveSkill", "skill": "will", "amount": 1}]})
	assert_eq(Investigators.passive_check_mods(INV, "combat").size(), 1)
	assert_eq(Investigators.passive_check_mods(INV, "deathSave").size(), 1, "в т.ч. на Пороге")


# ── Пассив: попадание в проверку ──────────────────────────────────────────────


class MockGameState:
	extends Node
	var players: Dictionary = {}
	var active_check: Dictionary = {}
	var _check_stack: Array = []

	func _name_of(pid: String) -> String:
		return pid

	func _broadcast_sync() -> void:
		pass

	func _emit_changed() -> void:
		pass


func test_check_seeds_investigator_passive() -> void:
	_fixture({}, {"mods": [{"do": "rerollDice", "count": 1, "context": "anyTest"}]})
	var gs: MockGameState = autofree(MockGameState.new())
	gs.players["p"] = {"investigator": INV, "skill_mods": {}}
	var cf: CheckFlow = CheckFlow.new(gs)
	var c: Dictionary = cf.make_check("encounter", "p", "will", 0, "encounter")
	assert_eq((c["active_mods"] as Array).size(), 1, "пассив сыщика попал в проверку")


func test_check_without_passive_is_unchanged() -> void:
	_fixture()
	var gs: MockGameState = autofree(MockGameState.new())
	gs.players["p"] = {"investigator": INV, "skill_mods": {}}
	var cf: CheckFlow = CheckFlow.new(gs)
	var c: Dictionary = cf.make_check("encounter", "p", "will", 0, "encounter")
	assert_eq(c["active_mods"], [], "без пассива проверка как раньше")


# ── Триггерный пассив: улучшение навыка применяется дважды (Мэй Линь) ─────────


func test_improve_skill_doubled_by_passive() -> void:
	_fixture({}, {"triggers": [{"on": "improveSkill", "repeat": 1}]})
	var p: Dictionary = {"investigator": INV, "skill_mods": {}}
	_EffectRunner.run([{"do": "improveSkill", "skill": "will", "amount": 1}], p)
	assert_eq(int((p["skill_mods"] as Dictionary).get("will", 0)), 2, "+1 применилось дважды")


func test_impair_skill_not_doubled() -> void:
	# Пассив «улучшая навык…» — ухудшение удваивать нельзя, иначе он вредит владельцу.
	_fixture({}, {"triggers": [{"on": "improveSkill", "repeat": 1}]})
	var p: Dictionary = {"investigator": INV, "skill_mods": {}}
	_EffectRunner.run([{"do": "impairSkill", "skill": "will", "amount": 1}], p)
	assert_eq(int((p["skill_mods"] as Dictionary).get("will", 0)), -1, "ухудшение как обычно")


func test_improve_skill_normal_without_passive() -> void:
	_fixture()
	var p: Dictionary = {"investigator": INV, "skill_mods": {}}
	_EffectRunner.run([{"do": "improveSkill", "skill": "will", "amount": 1}], p)
	assert_eq(int((p["skill_mods"] as Dictionary).get("will", 0)), 1, "без пассива — обычное +1")


func test_doubled_improve_respects_cap() -> void:
	_fixture({}, {"triggers": [{"on": "improveSkill", "repeat": 1}]})
	var p: Dictionary = {"investigator": INV, "skill_mods": {"will": 1}}
	_EffectRunner.run([{"do": "improveSkill", "skill": "will", "amount": 1}], p)
	assert_eq(int((p["skill_mods"] as Dictionary).get("will", 0)), 2, "потолок +2 держится")


# ── Встроенный вид действия ───────────────────────────────────────────────────


func test_ability_kind_counts_as_ability() -> void:
	_fixture({"name": "ABIL", "kind": "convertVitality"})
	assert_true(Investigators.has_ability(INV), "вид без программы — тоже способность")
	assert_eq(Investigators.ability_kind(INV), "convertVitality")


# ── Доступность встроенного вида ──────────────────────────────────────────────
#
# Регрессия: кнопка была активна при полных здоровье И рассудке, а нажатие молча
# ничего не делало — переливать было некуда. Доступность обязана это учитывать.


func _mei(hp: int, san: int) -> void:
	Investigators._by_name[INV] = {
		"name": INV,
		"skills": {},
		"ability": {"name": "ABIL", "kind": "convertVitality"},
	}
	NetworkManager.my_user_id = "p"
	GameState.active = true
	GameState.phase = Phases.ACTION
	GameState.turn_order = ["p"]
	GameState.current_idx = 0
	GameState.players = {
		"p":
		{
			"user_id": "p",
			"investigator": INV,
			"connected": true,
			"actions_left": 2,
			"actions_used": [],
			"hp": hp,
			"hp_max": 6,
			"sanity": san,
			"sanity_max": 6,
		}
	}


func test_convert_unavailable_when_both_pools_full() -> void:
	_mei(6, 6)
	assert_false(GameState.can_use_ability(), "переливать некуда — кнопка гаснет")


func test_convert_available_when_target_has_room() -> void:
	_mei(6, 2)
	assert_true(GameState.can_use_ability(), "рассудок неполон — перелив возможен")


func test_convert_unavailable_at_one_and_one() -> void:
	# Источник нельзя опускать до 0, поэтому при 1/1 перелить нечего.
	_mei(1, 1)
	assert_false(GameState.can_use_ability(), "источник нельзя опустить до нуля")


func test_check_for_unknown_investigator_is_safe() -> void:
	var gs: MockGameState = autofree(MockGameState.new())
	gs.players["p"] = {"investigator": "", "skill_mods": {}}
	var cf: CheckFlow = CheckFlow.new(gs)
	var c: Dictionary = cf.make_check("encounter", "p", "will", 0, "encounter")
	assert_eq(c["active_mods"], [], "нет сыщика — пусто, без падения")
