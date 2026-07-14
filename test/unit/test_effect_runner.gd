extends GutTest

## Юнит-тесты интерпретатора Effect-DSL (scripts/core/effect_runner.gd).
## Детерминизм бросков — через flow.rolls[path]: путь верхнеуровневой ноды i ==
## String(i), записанный бросок переигрывается без обращения к ГСЧ. Единственная
## внешняя зависимость интерпретатора — Dice (глобальный class_name).

const EffectRunner = preload("res://scripts/core/game/effect_runner.gd")


# Базовый словарь игрока (форма GameState.players[*]).
func _player() -> Dictionary:
	return {
		"hp": 5,
		"hp_max": 7,
		"sanity": 5,
		"sanity_max": 6,
		"clues": 1,
		"concentration": 0,
		"conditions": [],
		"conditions_flipped": {},
		"items": [],
		"skill_mods": {},
		"passive_mods": [],
	}


# ── Игровые verb'ы: применение и кламп ────────────────────────────────────────


func test_lose_health_subtracts() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "loseHealth", "amount": 2}], p)
	assert_eq(int(p["hp"]), 3, "5 − 2 = 3")


func test_lose_health_clamps_at_zero() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "loseHealth", "amount": 99}], p)
	assert_eq(int(p["hp"]), 0, "не уходит ниже 0")


func test_heal_health_clamps_at_max() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "healHealth", "amount": 99}], p)
	assert_eq(int(p["hp"]), 7, "не выше hp_max")


func test_lose_sanity_and_heal_sanity() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "loseSanity", "amount": 3}], p)
	assert_eq(int(p["sanity"]), 2, "5 − 3 = 2")
	EffectRunner.run([{"do": "healSanity", "amount": 99}], p)
	assert_eq(int(p["sanity"]), 6, "клампится по sanity_max")


func test_gain_and_spend_clue() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainClue", "amount": 2}], p)
	assert_eq(int(p["clues"]), 3, "1 + 2 = 3")
	EffectRunner.run([{"do": "spendClue", "amount": 5}], p)
	assert_eq(int(p["clues"]), 0, "spendClue клампится по нулю")


func test_amount_defaults_to_one() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainClue"}], p)
	assert_eq(int(p["clues"]), 2, "без amount шаг = 1")


func test_count_used_as_amount() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainClue", "count": 3}], p)
	assert_eq(int(p["clues"]), 4, "count трактуется как величина")


func test_gain_condition_no_duplicate() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainCondition", "condition": "cursed"}], p)
	EffectRunner.run([{"do": "gainCondition", "condition": "cursed"}], p)
	assert_eq((p["conditions"] as Array).size(), 1, "состояние не дублируется")
	assert_true((p["conditions"] as Array).has("cursed"))


func test_lose_condition_clears_flipped() -> void:
	var p: Dictionary = _player()
	p["conditions"] = ["legInjury"]
	p["conditions_flipped"] = {"legInjury": "failingBody"}
	EffectRunner.run([{"do": "loseCondition", "condition": "legInjury"}], p)
	assert_eq((p["conditions"] as Array).size(), 0, "состояние снято")
	assert_false((p["conditions_flipped"] as Dictionary).has("legInjury"), "flip-метка очищена")


func test_lose_all_possessions_clears_items() -> void:
	var p: Dictionary = _player()
	p["items"] = [{"id": "a"}, {"id": "b", "kind": "spell"}]
	p["conditions"] = ["blessed"]
	p["clues"] = 3
	EffectRunner.run([{"do": "loseAllPossessions"}], p)
	assert_eq((p["items"] as Array).size(), 0, "весь инвентарь сброшен")
	assert_true((p["conditions"] as Array).has("blessed"), "состояния — не имущество, целы")
	assert_eq(int(p["clues"]), 3, "улики — не имущество, целы")


func test_focus_gain_and_loss_clamp() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainFocus", "amount": 2}], p)
	assert_eq(int(p["concentration"]), 2)
	EffectRunner.run([{"do": "loseFocus", "amount": 9}], p)
	assert_eq(int(p["concentration"]), 0, "сосредоточение не ниже 0")


func test_resource_gain_and_loss_clamp() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainResource", "amount": 1}], p)
	assert_eq(int(p["resources"]), 1)
	EffectRunner.run([{"do": "gainResource", "amount": 5}], p)
	assert_eq(int(p["resources"]), GameState.MAX_RESOURCES, "ресурс не выше потолка")
	EffectRunner.run([{"do": "loseResource", "amount": 9}], p)
	assert_eq(int(p["resources"]), 0, "ресурс не ниже 0")


func test_improve_and_impair_skill_accumulate() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "improveSkill", "skill": "lore", "amount": 2}], p)
	EffectRunner.run([{"do": "impairSkill", "skill": "lore", "amount": 1}], p)
	assert_eq(int((p["skill_mods"] as Dictionary)["lore"]), 1, "+2 − 1 = +1 к навыку")
	# skill:"all" — улучшить каждый навык (Markings of Isis «+1 to all skills»).
	EffectRunner.run([{"do": "improveSkill", "skill": "all", "amount": 1}], p)
	assert_eq(int((p["skill_mods"] as Dictionary)["will"]), 1, "all → +1 каждому навыку")
	assert_eq(int((p["skill_mods"] as Dictionary)["lore"]), 2, "lore: 1 + 1(all)")


func test_skill_mod_caps_both_directions() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "improveSkill", "skill": "lore", "amount": 5}], p)
	assert_eq(int((p["skill_mods"] as Dictionary)["lore"]), 2, "улучшение не выше +2")
	EffectRunner.run([{"do": "improveSkill", "skill": "lore", "amount": 1}], p)
	assert_eq(int((p["skill_mods"] as Dictionary)["lore"]), 2, "верхний потолок держится")
	EffectRunner.run([{"do": "impairSkill", "skill": "lore", "amount": 9}], p)
	assert_eq(int((p["skill_mods"] as Dictionary)["lore"]), -2, "ухудшение не ниже −2")
	EffectRunner.run([{"do": "improveSkill", "skill": "lore", "amount": 1}], p)
	assert_eq(int((p["skill_mods"] as Dictionary)["lore"]), -1, "−2 + 1 = −1")


func test_become_delayed_adds_condition() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "becomeDelayed"}], p)
	assert_true((p["conditions"] as Array).has("delayed"))


func test_extra_action_adds_to_actions_left() -> void:
	var p: Dictionary = _player()
	p["actions_left"] = 1
	EffectRunner.run([{"do": "extraAction"}], p)
	assert_eq(int(p["actions_left"]), 2, "+1 действие в ход")
	EffectRunner.run([{"do": "extraAction", "amount": 2}], p)
	assert_eq(int(p["actions_left"]), 4, "amount уважается")


func test_passive_verb_collected_in_passive_mods() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "rerollDice"}], p)
	var mods: Array = p["passive_mods"]
	assert_eq(mods.size(), 1, "пассив сложен в passive_mods")
	assert_eq(String((mods[0] as Dictionary)["do"]), "rerollDice")


# ── Комбинаторы ───────────────────────────────────────────────────────────────


func test_group_runs_all_children() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"group": [{"do": "gainClue"}, {"do": "gainClue"}]}], p)
	assert_eq(int(p["clues"]), 3, "group выполняет обе ноды")


func test_choice_non_interactive_takes_first_branch() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"choice": [{"do": "gainClue"}, {"do": "loseSanity", "amount": 2}]}], p)
	assert_eq(int(p["clues"]), 2, "взята первая ветка")
	assert_eq(int(p["sanity"]), 5, "вторая ветка не тронута")


func test_repeat_on_group_literal() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"repeat": 2, "group": [{"do": "gainClue"}]}], p)
	assert_eq(int(p["clues"]), 3, "group повторён 2 раза → +2 улики")


func test_repeat_on_group_source() -> void:
	var p: Dictionary = _player()
	EffectRunner.run(
		[{"repeat": {"source": "monstersOnBoard"}, "group": [{"do": "gainClue"}]}],
		p,
		{"monsters_on_board": 3}
	)
	assert_eq(int(p["clues"]), 4, "1 + 3 (по числу монстров)")


func test_repeat_on_choice_pends_each_iteration() -> void:
	var p: Dictionary = _player()
	var effects: Array = [
		{
			"repeat": 2,
			"choice": [{"do": "loseHealth", "amount": 1}, {"do": "loseSanity", "amount": 1}]
		}
	]
	var res: Dictionary = EffectRunner.run(effects, p, {}, {"interactive": true})
	assert_eq(
		String((res["pending"] as Dictionary).get("path", "")), "0/r0", "первая итерация повисла"
	)
	assert_eq(int(p["hp"]), 5, "на паузе ничего не применено")


func test_repeat_on_choice_two_picks() -> void:
	var p: Dictionary = _player()
	var effects: Array = [
		{
			"repeat": 2,
			"choice": [{"do": "loseHealth", "amount": 1}, {"do": "loseSanity", "amount": 1}]
		}
	]
	# r0 → ветка 0 (здоровье), r1 → ветка 1 (рассудок).
	var flow: Dictionary = {"interactive": true, "decisions": {"0/r0": 0, "0/r1": 1}}
	EffectRunner.run(effects, p, {}, flow)
	assert_eq(int(p["hp"]), 4, "r0 → −1 здоровье")
	assert_eq(int(p["sanity"]), 4, "r1 → −1 рассудок")


func test_die_roll_low_range_branch() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {
		"dieRoll":
		[
			{"on": "1-3", "then": [{"do": "loseHealth", "amount": 2}]},
			{"on": "4-6", "then": [{"do": "gainClue"}]},
		]
	}
	EffectRunner.run([node], p, {}, {"rolls": {"0": [2]}})
	assert_eq(int(p["hp"]), 3, "выпало 2 → ветка 1-3")
	assert_eq(int(p["clues"]), 1, "ветка 4-6 не сработала")


func test_die_roll_high_range_branch() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {
		"dieRoll":
		[
			{"on": "1-3", "then": [{"do": "loseHealth", "amount": 2}]},
			{"on": "4-6", "then": [{"do": "gainClue"}]},
		]
	}
	EffectRunner.run([node], p, {}, {"rolls": {"0": [5]}})
	assert_eq(int(p["clues"]), 2, "выпало 5 → ветка 4-6")
	assert_eq(int(p["hp"]), 5, "ветка 1-3 не сработала")


func test_test_on_pass_with_skills() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {
		"test": "lore",
		"onPass": [{"do": "gainClue"}],
		"onFail": [{"do": "loseSanity", "amount": 2}],
	}
	EffectRunner.run([node], p, {"skills": {"lore": 3}}, {"rolls": {"0": [6, 6, 6]}})
	assert_eq(int(p["clues"]), 2, "успешный бросок → onPass")
	assert_eq(int(p["sanity"]), 5, "onFail не сработал")


func test_test_on_fail_with_skills() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {
		"test": "lore",
		"onPass": [{"do": "gainClue"}],
		"onFail": [{"do": "loseSanity", "amount": 2}],
	}
	EffectRunner.run([node], p, {"skills": {"lore": 3}}, {"rolls": {"0": [1, 2, 3]}})
	assert_eq(int(p["sanity"]), 3, "провал → onFail")
	assert_eq(int(p["clues"]), 1, "onPass не сработал")


func test_test_auto_passes_without_skills() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {"test": "lore", "onPass": [{"do": "gainClue"}], "onFail": []}
	EffectRunner.run([node], p, {}, {})
	assert_eq(int(p["clues"]), 2, "без навыков в ctx проверка считается пройденной")


# ── when (предикаты) ──────────────────────────────────────────────────────────


func test_when_has_condition_gates_action() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {
		"do": "gainClue", "when": {"kind": "hasCondition", "condition": "cursed"}
	}
	EffectRunner.run([node], p)
	assert_eq(int(p["clues"]), 1, "без состояния — эффект пропущен")
	p["conditions"] = ["cursed"]
	EffectRunner.run([node], p)
	assert_eq(int(p["clues"]), 2, "с состоянием — эффект применён")


func test_when_negated_predicate() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {
		"do": "gainClue",
		"when": {"kind": "hasCondition", "condition": "cursed", "not": true},
	}
	EffectRunner.run([node], p)
	assert_eq(int(p["clues"]), 2, "not:true — применяется при ОТСУТСТВИИ состояния")


# ── repeat ────────────────────────────────────────────────────────────────────


func test_repeat_literal() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainClue", "repeat": 3}], p)
	assert_eq(int(p["clues"]), 4, "1 + 3×1 = 4")


func test_repeat_by_conditions_source() -> void:
	var p: Dictionary = _player()
	p["conditions"] = ["a", "b"]
	EffectRunner.run([{"do": "gainClue", "repeat": {"source": "conditions"}}], p)
	assert_eq(int(p["clues"]), 3, "1 + 2 состояния = 3")


func test_repeat_by_condition_kind() -> void:
	# repeat «по трейту»: amnesia/paranoia — madness, poisoned — illness → 2 madness.
	var p: Dictionary = _player()
	p["conditions"] = ["amnesia", "poisoned", "paranoia"]
	EffectRunner.run(
		[{"do": "gainClue", "repeat": {"source": "conditionsOfKind", "kind": "madness"}}], p
	)
	assert_eq(int(p["clues"]), 3, "1 + 2 madness (amnesia, paranoia) = 3")


func test_repeat_by_condition_kind_empty_counts_all() -> void:
	var p: Dictionary = _player()
	p["conditions"] = ["amnesia", "poisoned"]
	EffectRunner.run([{"do": "gainClue", "repeat": {"source": "conditionsOfKind"}}], p)
	assert_eq(int(p["clues"]), 3, "пустой kind → все состояния (2)")


func test_add_successes_boosts_result_tiers() -> void:
	# successes 0 → addSuccesses 2 → 2 → тир «2+» срабатывает.
	var p: Dictionary = _player()
	var prog: Array = [
		{"do": "addSuccesses", "amount": 2},
		{
			"resultTiers":
			[
				{"on": "2+", "effect": [{"do": "gainClue"}]},
				{"on": "0-1", "effect": []},
			]
		},
	]
	EffectRunner.run(prog, p, {"successes": 0})
	assert_eq(int(p["clues"]), 2, "буст 0→2 успехов → тир 2+ дал улику (1+1)")


func test_add_successes_affects_board_toughness() -> void:
	# addSuccesses до board-verb'а «по стойкости» → узел получает буст-успехи.
	var p: Dictionary = _player()
	var res: Dictionary = (
		EffectRunner
		. run(
			[
				{"do": "addSuccesses", "amount": 1},
				{"do": "discardMonster", "maxToughness": "testResult"}
			],
			p,
			{"successes": 0},
		)
	)
	var board: Array = res["board"]
	assert_eq(board.size(), 1, "discardMonster ушёл на доску")
	assert_eq(int((board[0] as Dictionary)["_successes"]), 1, "board-узел получил буст (0+1)")


# ── Маршрутизация целей (board) ───────────────────────────────────────────────


func test_board_verb_goes_to_board_not_player() -> void:
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run([{"do": "advanceDoom", "amount": 1}], p)
	var board: Array = res["board"]
	assert_eq(board.size(), 1, "не-игровой verb уходит на доску")
	assert_eq(String((board[0] as Dictionary)["do"]), "advanceDoom")
	assert_eq(int((board[0] as Dictionary)["_times"]), 1, "проставлен _times для повтора")
	# Результат каста (ctx.successes) прокидывается на board-ноду — для verb'ов
	# «по стойкости» (discardMonster/defeatMonster maxToughness:"testResult").
	var r2: Dictionary = EffectRunner.run([{"do": "discardMonster"}], p, {"successes": 3})
	assert_eq(int((r2["board"][0] as Dictionary)["_successes"]), 3, "_successes из ctx на board")


func test_self_player_verb_applied_legacy_mode() -> void:
	# Без interactive (мифос/хуки) игровой verb с целью применяется к переданному
	# игроку — слой-вызыватель сам разворачивает цель.
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "loseHealth", "target": "lead", "amount": 1}], p)
	assert_eq(int(p["hp"]), 4, "в легаси-режиме применяется к переданному игроку")


# ── Публичные хелперы ─────────────────────────────────────────────────────────


func test_is_player_verb() -> void:
	assert_true(EffectRunner.is_player_verb("loseHealth"), "loseHealth — игровой")
	assert_false(EffectRunner.is_player_verb("advanceDoom"), "advanceDoom — нет")
	assert_false(
		EffectRunner.is_player_verb("gainSpell"), "gainSpell — board-verb (host тянет карту)"
	)


func test_apply_player_verb_direct() -> void:
	var p: Dictionary = _player()
	var logs: Array = EffectRunner.apply_player_verb("gainClue", {"amount": 2}, p)
	assert_eq(int(p["clues"]), 3, "verb применён к игроку напрямую")
	assert_eq(logs.size(), 1, "вернулась строка-лог")


func test_run_returns_logs() -> void:
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run([{"do": "gainClue"}, {"do": "loseHealth"}], p)
	assert_eq((res["logs"] as Array).size(), 2, "по логу на каждое действие")
	assert_eq((res["pending"] as Dictionary).size(), 0, "нет ожидающего выбора")


# ── resultTiers (рубашка заклинания: ветвление по ЧИСЛУ УСПЕХОВ каста) ─────────


func test_result_tiers_low_tier() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {
		"resultTiers":
		[
			{"on": "0-1", "effect": [{"do": "loseSanity", "amount": 2}]},
			{"on": "2+", "effect": [{"do": "gainClue"}]},
		]
	}
	EffectRunner.run([node], p, {"successes": 0})
	assert_eq(int(p["sanity"]), 3, "0 успехов → тир 0-1")
	assert_eq(int(p["clues"]), 1, "тир 2+ не сработал")


func test_result_tiers_high_open_ended() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {
		"resultTiers":
		[
			{"on": "0-1", "effect": [{"do": "loseSanity", "amount": 2}]},
			{"on": "2+", "effect": [{"do": "gainClue"}]},
		]
	}
	EffectRunner.run([node], p, {"successes": 5})
	assert_eq(int(p["clues"]), 2, "5 успехов → тир 2+ (N+)")
	assert_eq(int(p["sanity"]), 5, "тир 0-1 не сработал")


func test_result_tiers_exact_match() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {
		"resultTiers": [{"on": "0", "effect": [{"do": "loseHealth", "amount": 1}]}]
	}
	EffectRunner.run([node], p, {"successes": 0})
	assert_eq(int(p["hp"]), 4, "точное совпадение on:0")


func test_result_tiers_no_match_is_noop() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {"resultTiers": [{"on": "3+", "effect": [{"do": "gainClue"}]}]}
	EffectRunner.run([node], p, {"successes": 1})
	assert_eq(int(p["clues"]), 1, "ни один тир не подошёл — ничего")


func test_result_tiers_defaults_successes_zero() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {"resultTiers": [{"on": "0", "effect": [{"do": "gainClue"}]}]}
	EffectRunner.run([node], p)  # нет ctx.successes → 0
	assert_eq(int(p["clues"]), 2, "без ctx.successes считается 0")


# ── when rolledAny (грани кубов каста — для рубашек «выпали 1 → discard») ──────


func test_when_rolled_any_applies_when_face_present() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {
		"do": "loseSanity", "amount": 1, "when": {"kind": "rolledAny", "face": 1}
	}
	EffectRunner.run([node], p, {"dice": [3, 1, 5]})
	assert_eq(int(p["sanity"]), 4, "в кубах есть 1 → эффект применён")


func test_when_rolled_any_skips_without_face() -> void:
	var p: Dictionary = _player()
	var node: Dictionary = {
		"do": "loseSanity", "amount": 1, "when": {"kind": "rolledAny", "face": 1}
	}
	EffectRunner.run([node], p, {"dice": [3, 4, 5]})
	assert_eq(int(p["sanity"]), 5, "нет 1 в кубах → пропущено")
	EffectRunner.run([node], p, {})
	assert_eq(int(p["sanity"]), 5, "нет ctx.dice → пропущено")


func test_become_delayed_respects_immunity() -> void:
	# Pocket Watch (whileOwned immuneTo status:delayed) блокирует becomeDelayed.
	var p1: Dictionary = {"conditions": [], "items": []}
	EffectRunner.run([{"do": "becomeDelayed"}], p1)
	assert_has(p1["conditions"], "delayed", "без иммунитета — задержка ставится")
	var p2: Dictionary = {"conditions": [], "items": [{"id": "pocket_watch", "exhausted": false}]}
	EffectRunner.run([{"do": "becomeDelayed"}], p2)
	assert_does_not_have(p2["conditions"], "delayed", "Pocket Watch — иммунитет к задержке")


func test_protect_resource_clue_blocks_involuntary_loss() -> void:
	# Scribe's Journal (whileOwned protectResource resource:clue): loseClue не отнимает,
	# но добровольная трата (spendClue) работает.
	var p: Dictionary = {"clues": 3, "items": [{"id": "scribes_journal", "exhausted": false}]}
	EffectRunner.run([{"do": "loseClue", "amount": 2}], p)
	assert_eq(int(p["clues"]), 3, "улики защищены от потери")
	EffectRunner.run([{"do": "spendClue", "amount": 1}], p)
	assert_eq(int(p["clues"]), 2, "трата (spendClue) работает")
	var p2: Dictionary = {"clues": 3, "items": []}
	EffectRunner.run([{"do": "loseClue", "amount": 2}], p2)
	assert_eq(int(p2["clues"]), 1, "без защиты — теряются")


func test_gain_focus_capped_at_max() -> void:
	# Потолок концентрации: gainFocus не поднимает выше GameState.MAX_CONCENTRATION.
	var p: Dictionary = {"concentration": 1}
	EffectRunner.run([{"do": "gainFocus", "amount": 5}], p)
	assert_eq(int(p["concentration"]), GameState.MAX_CONCENTRATION, "концентрация не выше потолка")
