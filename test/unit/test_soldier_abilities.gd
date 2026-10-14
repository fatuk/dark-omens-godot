## Солдат (Фрэнк Далтон), данные — боевой data/investigators.json:
##  • действие «вы и 1 монстр на вашей локации теряете по 1 здоровью» (strikeMonster);
##  • пассив «не можете стать Задержаны или получить Заключение, если сами того не
##    пожелаете» — whileOwned immuneTo. Тот же «если не выбрали сами» у Pocket Watch.
extends GutTest

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

const SOLDIER := "Frank Dalton"
const OTHER := "Mei Lin"
const LOC := "5"

var _nm: Node
var _was_host: bool


func before_each() -> void:
	_nm = get_node("/root/NetworkManager")
	_was_host = bool(_nm.get("_is_host_flag"))
	_nm.set("_is_host_flag", true)
	GameState.reset_session()


func after_each() -> void:
	GameState.reset_session()
	_nm.set("_is_host_flag", _was_host)


func _p(inv: String, items: Array = []) -> Dictionary:
	return {"investigator": inv, "hp": 5, "sanity": 5, "conditions": [], "items": items}


# ── Данные ────────────────────────────────────────────────────────────────────


func test_soldier_data() -> void:
	assert_eq(Investigators.ability_kind(SOLDIER), "strikeMonster")
	assert_true(Investigators.has_ability(SOLDIER))
	assert_true(Investigators.passive_immune_to(SOLDIER, "delayed"))
	assert_true(Investigators.passive_immune_to(SOLDIER, "detained"))
	assert_false(Investigators.passive_immune_to(SOLDIER, "legInjury"))
	assert_false(Investigators.passive_immune_to(OTHER, "delayed"), "у других — нет")


# ── Пассив: Задержка и Заключение ─────────────────────────────────────────────


func test_soldier_ignores_imposed_delay_and_detained() -> void:
	var p: Dictionary = _p(SOLDIER)
	(
		_EffectRunner
		. run(
			[
				{"do": "becomeDelayed"},
				{"do": "gainCondition", "condition": "detained"},
				{"do": "gainCondition", "condition": "legInjury"},
			],
			p
		)
	)
	assert_does_not_have(p["conditions"], "delayed", "не задержан")
	assert_does_not_have(p["conditions"], "detained", "не в заключении")
	assert_has(p["conditions"], "legInjury", "прочие состояния — как обычно")


func test_other_investigator_is_delayed() -> void:
	var p: Dictionary = _p(OTHER)
	_EffectRunner.run([{"do": "becomeDelayed"}], p)
	assert_has(p["conditions"], "delayed")


func test_soldier_can_choose_delay() -> void:
	# «Можете стать Задержаным, чтобы получить …» — выбор игрока: пассив не мешает.
	var p: Dictionary = _p(SOLDIER)
	var flow: Dictionary = {"interactive": true, "decisions": {"0": 0}, "rolls": {}}
	_EffectRunner.run(
		[{"choice": [{"do": "becomeDelayed"}, {"do": "text", "text": "DECISION_SKIP"}]}],
		p,
		{},
		flow
	)
	assert_has(p["conditions"], "delayed", "выбрал сам — задержан")


func test_choice_does_not_leak_into_later_effects() -> void:
	# После выбранной ветки навязанная задержка снова гасится (счётчик вернулся в 0).
	var p: Dictionary = _p(SOLDIER)
	var flow: Dictionary = {"interactive": true, "decisions": {"0": 1}, "rolls": {}}
	(
		_EffectRunner
		. run(
			[
				{"choice": [{"do": "becomeDelayed"}, {"do": "text", "text": "DECISION_SKIP"}]},
				{"do": "becomeDelayed"},
			],
			p,
			{},
			flow
		)
	)
	assert_does_not_have(p["conditions"], "delayed")


func test_pocket_watch_also_allows_own_choice() -> void:
	var items: Array = [{"id": "pocket_watch", "exhausted": false}]
	var imposed: Dictionary = _p(OTHER, items)
	_EffectRunner.run([{"do": "becomeDelayed"}], imposed)
	assert_does_not_have(imposed["conditions"], "delayed", "часы гасят навязанную задержку")
	var chosen: Dictionary = _p(OTHER, items.duplicate(true))
	var flow: Dictionary = {"interactive": true, "decisions": {"0": 0}, "rolls": {}}
	_EffectRunner.run(
		[{"choice": [{"do": "becomeDelayed"}, {"do": "text", "text": "DECISION_SKIP"}]}],
		chosen,
		{},
		flow
	)
	assert_has(chosen["conditions"], "delayed", "но не выбранную самим")


# ── Действие: удар ───────────────────────────────────────────────────────────


func _setup_host_turn() -> Dictionary:
	GameState.players = {"a": GameState._make_player_dict("a", "A", SOLDIER, LOC, 8, 4)}
	GameState.players["a"]["hp"] = 5
	GameState.turn_order = ["a"]
	GameState.current_idx = 0
	GameState.phase = Phases.ACTION
	GameState.active = true
	return GameState.players["a"]


func test_strike_hurts_soldier_and_chosen_monster() -> void:
	var me: Dictionary = _setup_host_turn()
	GameState.monsters = {LOC: [{"id": "deep_one", "health": 2}, {"id": "zombie", "health": 2}]}
	var left: int = int(me["actions_left"])
	assert_true(
		GameState._phase.host_apply_action(
			"a", GameActions.INVESTIGATOR_ABILITY, {"monster": "%s#1" % LOC}
		)
	)
	assert_eq(int(me["hp"]), 4, "Солдат −1 здоровья")
	var here: Array = GameState.monsters[LOC]
	assert_eq(int((here[0] as Dictionary)["health"]), 2, "первый монстр не тронут")
	assert_eq(int((here[1] as Dictionary)["health"]), 1, "выбранный монстр −1")
	assert_eq(int(me["actions_left"]), left - 1, "тратит действие")


func test_strike_needs_monster_on_own_space() -> void:
	var me: Dictionary = _setup_host_turn()
	GameState.monsters = {"1": [{"id": "deep_one", "health": 2}]}
	var left: int = int(me["actions_left"])
	assert_false(
		GameState._phase.host_apply_action("a", GameActions.INVESTIGATOR_ABILITY, {}),
		"на своей клетке монстров нет"
	)
	assert_false(
		GameState._phase.host_apply_action(
			"a", GameActions.INVESTIGATOR_ABILITY, {"monster": "1#0"}
		),
		"монстр на чужой клетке не цель"
	)
	assert_eq(int(me["hp"]), 5, "здоровье цело")
	assert_eq(int(me["actions_left"]), left, "действие не потрачено")
	assert_eq(int((GameState.monsters["1"][0] as Dictionary)["health"]), 2)
