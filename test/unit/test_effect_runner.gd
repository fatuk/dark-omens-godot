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
	# onDuplicate:"flip" (Благословение): вместо дубля — board-узел flipCondition владельцу.
	var ph := {"user_id": "u1", "conditions": ["blessed"], "conditions_flipped": {}}
	var rh: Dictionary = EffectRunner.run([{"do": "gainCondition", "condition": "blessed"}], ph, {})
	assert_eq(ph["conditions"], ["blessed"], "дубля нет")
	var bh: Array = rh.get("board", [])
	assert_eq(bh.size(), 1)
	assert_eq(String((bh[0] as Dictionary)["do"]), "flipCondition")
	assert_eq(String((bh[0] as Dictionary)["condition"]), "blessed")
	assert_eq(String((bh[0] as Dictionary)["_pid"]), "u1", "флип адресован владельцу")
	# Без флага (Долг) — как раньше: дубля нет и переворота нет.
	var ph2 := {"user_id": "u1", "conditions": ["debt"], "conditions_flipped": {}}
	var rh2: Dictionary = EffectRunner.run([{"do": "gainCondition", "condition": "debt"}], ph2, {})
	assert_eq(ph2["conditions"], ["debt"], "второго Долга нет")
	assert_true((rh2.get("board", []) as Array).is_empty(), "и переворота нет")


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
	# cluesAtMost — по сыщику; noInvestigatorsAt — по контексту поля (investigators_at).
	var poor := {"do": "gainClue", "when": {"kind": "cluesAtMost", "n": 0}}
	EffectRunner.run([poor], p)
	assert_eq(int(p["clues"]), 2, "улики есть → cluesAtMost 0 не прошёл")
	p["clues"] = 0
	EffectRunner.run([poor], p)
	assert_eq(int(p["clues"]), 1, "улик нет → прошёл")
	var empty_field := {"do": "gainClue", "when": {"kind": "noInvestigatorsAt", "location": "5"}}
	EffectRunner.run([empty_field], p, {"investigators_at": {"5": 2}})
	assert_eq(int(p["clues"]), 1, "на поле есть сыщики → не прошёл")
	EffectRunner.run([empty_field], p, {"investigators_at": {"Arkham": 1}})
	assert_eq(int(p["clues"]), 2, "поле пусто → прошёл")


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


# ── Состояния по ВИДУ (kind), а не по id ──────────────────────────────────────


func test_gain_condition_by_kind_picks_that_kind() -> void:
	# «Получите состояние Безумие» — вид, а не карта: движок берёт случайное того вида.
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainCondition", "kind": "madness"}], p)
	assert_eq((p["conditions"] as Array).size(), 1, "выдано ровно одно состояние")
	var cid: String = String((p["conditions"] as Array)[0])
	assert_eq(Conditions.kind_of(cid), "madness", "и оно нужного вида")


func test_gain_condition_by_kind_does_not_duplicate() -> void:
	# Пул вида исчерпан (все уже на руках) — verb не делает ничего, а не дублирует.
	var p: Dictionary = _player()
	var all_madness: Array = Conditions.ids_of_kinds(["madness"])
	p["conditions"] = all_madness.duplicate()
	EffectRunner.run([{"do": "gainCondition", "kind": "madness"}], p)
	assert_eq(
		(p["conditions"] as Array).size(), all_madness.size(), "нечего выдать — состав тот же"
	)


func test_gain_condition_id_still_wins_over_kind() -> void:
	# Явный id важнее вида: старые карточки не должны поменять поведение.
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainCondition", "condition": "blessed", "kind": "madness"}], p)
	assert_has(p["conditions"], "blessed", "выдан именно указанный id")


func test_lose_condition_by_kind_removes_matching_only() -> void:
	# «Сбросьте 1 Безумие» не должно трогать благословение.
	var p: Dictionary = _player()
	p["conditions"] = ["blessed", "paranoia"]
	EffectRunner.run([{"do": "loseCondition", "kind": "madness"}], p)
	assert_has(p["conditions"], "blessed", "чужой вид не тронут")
	assert_does_not_have(p["conditions"], "paranoia", "снято безумие")


func test_lose_condition_accepts_kind_list() -> void:
	# «Сбросьте 1 Болезнь ИЛИ Травму» — массив видов.
	var p: Dictionary = _player()
	p["conditions"] = ["blessed", "legInjury"]
	EffectRunner.run([{"do": "loseCondition", "kind": ["illness", "injury"]}], p)
	assert_does_not_have(p["conditions"], "legInjury", "травма снята по списку видов")
	assert_eq((p["conditions"] as Array).size(), 1, "снято ровно одно")


func test_lose_condition_without_id_removes_first_held() -> void:
	# choose:true без id раньше стирал пустую строку и не делал НИЧЕГО.
	var p: Dictionary = _player()
	p["conditions"] = ["blessed", "paranoia"]
	EffectRunner.run([{"do": "loseCondition", "choose": true}], p)
	assert_eq((p["conditions"] as Array).size(), 1, "одно состояние снято")


func test_lose_condition_no_match_is_noop() -> void:
	var p: Dictionary = _player()
	p["conditions"] = ["blessed"]
	EffectRunner.run([{"do": "loseCondition", "kind": "madness"}], p)
	assert_eq(p["conditions"] as Array, ["blessed"], "нечего снимать — состав тот же")


# ── Выдача актива по трейту ───────────────────────────────────────────────────


func test_gain_asset_with_trait_respects_trait() -> void:
	# «Получите случайное ОРУЖИЕ из колоды»: выдача сужается трейтом.
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainAsset", "trait": "weapon"}], p)
	assert_eq((p["items"] as Array).size(), 1, "актив выдан")
	var aid: String = AssetCatalog.entry_id((p["items"] as Array)[0])
	var item_traits: Array = AssetCatalog.by_id(aid).get("traits", [])
	assert_has(item_traits, "weapon", "у выданного актива есть запрошенный трейт")


func test_gain_asset_unknown_trait_falls_back_to_pool() -> void:
	# Ни одного актива с таким трейтом — выдаём из общего пула, а не пустоту:
	# пустая награда за успех хуже слегка неточной.
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainAsset", "trait": "нет-такого-трейта"}], p)
	assert_eq((p["items"] as Array).size(), 1, "выдан хоть какой-то актив")


# ── Сброс имущества: трейт, count, keep ───────────────────────────────────────


func _items(ids: Array) -> Array:
	var out: Array = []
	for id_v: Variant in ids:
		out.append({"id": String(id_v), "exhausted": false})
	return out


func _first_asset_with(trait_name: String) -> String:
	for id_v: Variant in AssetCatalog.available_ids():
		var a: Dictionary = AssetCatalog.by_id(String(id_v))
		if (a.get("traits", []) as Array).has(trait_name):
			return String(id_v)
	return ""


func test_lose_asset_by_trait_picks_matching_item() -> void:
	# «Сбросьте 1 Вещь» при наличии оружия — уходит именно вещь.
	var weapon: String = _first_asset_with("weapon")
	var item: String = _first_asset_with("item")
	assert_ne(weapon, "", "в корпусе есть оружие")
	assert_ne(item, "", "в корпусе есть вещь")
	var p: Dictionary = _player()
	p["items"] = _items([weapon, item])
	EffectRunner.run([{"do": "loseAsset", "trait": "item"}], p)
	assert_eq((p["items"] as Array).size(), 1, "сброшен ровно один")
	assert_eq(AssetCatalog.entry_id((p["items"] as Array)[0]), weapon, "ушла вещь, оружие цело")


func test_lose_asset_count_drops_several() -> void:
	var p: Dictionary = _player()
	p["items"] = _items(["a", "b", "c"])
	EffectRunner.run([{"do": "loseAsset", "count": 2}], p)
	assert_eq((p["items"] as Array).size(), 1, "сброшено 2 из 3")


func test_lose_asset_keep_leaves_n() -> void:
	# «Сбросьте всё, кроме одного» — поле keep, которое словарь объявлял мёртвым.
	var p: Dictionary = _player()
	p["items"] = _items(["a", "b", "c", "d"])
	EffectRunner.run([{"do": "loseAsset", "keep": 1}], p)
	assert_eq((p["items"] as Array).size(), 1, "оставлен ровно один")


func test_lose_spell_hits_spells_not_assets() -> void:
	# loseSpell и loseAsset делили обработчик и снимали последний предмет подряд.
	var p: Dictionary = _player()
	p["items"] = [{"id": "shriveling", "kind": "spell"}, {"id": "18_derringer", "exhausted": false}]
	EffectRunner.run([{"do": "loseSpell"}], p)
	assert_eq((p["items"] as Array).size(), 1, "сброшено одно")
	assert_eq(
		AssetCatalog.entry_id((p["items"] as Array)[0]), "18_derringer", "актив остался на руках"
	)


func test_lose_asset_nothing_matching_is_noop() -> void:
	var p: Dictionary = _player()
	p["items"] = [{"id": "shriveling", "kind": "spell"}]
	EffectRunner.run([{"do": "loseAsset"}], p)
	assert_eq((p["items"] as Array).size(), 1, "заклинание не считается активом")


# ── Билеты ────────────────────────────────────────────────────────────────────


func test_gain_ticket_by_kind() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainTicket", "kind": "ship", "count": 2}], p)
	assert_eq(int(p.get("ship_tickets", 0)), 2, "пароходные выданы")
	assert_eq(int(p.get("train_tickets", 0)), 0, "поездные не тронуты")


func test_gain_ticket_defaults_to_train() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainTicket"}], p)
	assert_eq(int(p.get("train_tickets", 0)), 1, "без kind — поездной")


func test_gain_ticket_capped_by_shared_limit() -> void:
	# Потолок MAX_TICKETS общий на оба вида, а не по виду.
	var p: Dictionary = _player()
	p["train_tickets"] = GameState.MAX_TICKETS
	EffectRunner.run([{"do": "gainTicket", "kind": "ship", "count": 3}], p)
	assert_eq(int(p.get("ship_tickets", 0)), 0, "лимит уже выбран поездными")


func test_lose_ticket_clamps_at_zero() -> void:
	var p: Dictionary = _player()
	p["ship_tickets"] = 1
	EffectRunner.run([{"do": "loseTicket", "kind": "ship", "count": 5}], p)
	assert_eq(int(p.get("ship_tickets", 0)), 0, "не уходит в минус")


# ── skill:"choice" — «улучшите 1 навык на свой выбор» ─────────────────────────


func test_skill_choice_improves_exactly_one_skill() -> void:
	# Без интерактива choice берёт первую ветку — важно, что затронут РОВНО один навык
	# (а не все пять, как сделал бы skill:"all").
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "improveSkill", "skill": "choice", "amount": 1}], p)
	var mods: Dictionary = p["skill_mods"]
	var touched: int = 0
	for k_v: Variant in mods.keys():
		if int(mods[k_v]) != 0:
			touched += 1
	assert_eq(touched, 1, "улучшен ровно один навык")


func test_skill_choice_pends_a_decision_when_interactive() -> void:
	# В интерактивном прогоне выбор навыка идёт через общий тракт пауз: программа
	# останавливается и кладёт пять веток в pending.
	var p: Dictionary = _player()
	var flow: Dictionary = {"interactive": true, "decisions": {}, "rolls": {}, "pending": {}}
	var res: Dictionary = EffectRunner.run(
		[{"do": "improveSkill", "skill": "choice", "amount": 1}], p, {}, flow
	)
	var pending: Dictionary = res.get("pending", {})
	# У паузы обычного choice поля kind нет (оно только у destination/target/check) —
	# ветки узнаются по options, и это ровно та пауза, что нужна.
	assert_eq(String(pending.get("path", "")), "0", "пауза на верхнеуровневом узле")
	assert_eq((pending.get("options", []) as Array).size(), 5, "пять веток — по навыку на ветку")
	assert_eq((p["skill_mods"] as Dictionary).size(), 0, "до решения ничего не применено")


func test_skill_choice_applies_recorded_decision() -> void:
	# Записанное решение переигрывается детерминированно — как у обычного choice.
	var p: Dictionary = _player()
	var flow: Dictionary = {"interactive": true, "decisions": {"0": 4}, "rolls": {}, "pending": {}}
	EffectRunner.run([{"do": "improveSkill", "skill": "choice", "amount": 2}], p, {}, flow)
	assert_eq(int((p["skill_mods"] as Dictionary).get("will", 0)), 2, "пятая ветка — воля")


func test_skill_choice_untouched_for_other_verbs() -> void:
	# Разворачиваем только improveSkill/impairSkill: у чужого verb-а skill — параметр.
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "rerollDice", "count": 1, "skill": "choice"}], p)
	assert_eq((p["passive_mods"] as Array).size(), 1, "узел ушёл в пассивы как есть")


# ── Счётчик conditionsOf (имя из словаря DSL) ─────────────────────────────────


func test_repeat_by_conditions_of_counts_held() -> void:
	# Словарь объявляет conditionsOf, движок знал только conditions — карточка
	# со счётчиком из словаря молча повторялась 1 раз.
	var p: Dictionary = _player()
	p["conditions"] = ["blessed", "paranoia", "delayed"]
	EffectRunner.run([{"do": "loseSanity", "amount": 1, "repeat": {"source": "conditionsOf"}}], p)
	assert_eq(int(p["sanity"]), 2, "5 − 3 состояния = 2")


# ── Артефакты: сброс (выдача — board-ветка, тестируется в test_game_sync) ─────


func test_lose_artifact_takes_artifact_not_asset() -> void:
	# Артефакт и актив могут делить трейт (обе бывают Книгой), поэтому «сбросьте
	# 1 Артефакт» различает их по каталогу-владельцу, а не по трейту.
	var p: Dictionary = _player()
	p["items"] = [
		{"id": "18_derringer", "exhausted": false},
		{"id": "necronomicon", "kind": "artifact", "exhausted": false},
	]
	EffectRunner.run([{"do": "loseArtifact"}], p)
	assert_eq((p["items"] as Array).size(), 1, "сброшено одно")
	assert_eq(
		AssetCatalog.entry_id((p["items"] as Array)[0]), "18_derringer", "актив остался на руках"
	)


func test_lose_asset_does_not_take_artifact() -> void:
	# Обратная сторона: «сбросьте 1 предмет» не должно унести артефакт.
	var p: Dictionary = _player()
	p["items"] = [
		{"id": "necronomicon", "kind": "artifact", "exhausted": false},
		{"id": "18_derringer", "exhausted": false},
	]
	EffectRunner.run([{"do": "loseAsset"}], p)
	assert_eq((p["items"] as Array).size(), 1, "сброшено одно")
	assert_eq(AssetCatalog.entry_id((p["items"] as Array)[0]), "necronomicon", "артефакт остался")


func test_lose_artifact_by_trait() -> void:
	var p: Dictionary = _player()
	p["items"] = [
		{"id": "necronomicon", "kind": "artifact", "exhausted": false},
		{"id": "gate_box", "kind": "artifact", "exhausted": false},
	]
	EffectRunner.run([{"do": "loseArtifact", "trait": "tome"}], p)
	assert_eq(AssetCatalog.entry_id((p["items"] as Array)[0]), "gate_box", "ушла именно книга")


func test_lose_artifact_without_any_is_noop() -> void:
	var p: Dictionary = _player()
	p["items"] = [{"id": "18_derringer", "exhausted": false}]
	EffectRunner.run([{"do": "loseArtifact"}], p)
	assert_eq((p["items"] as Array).size(), 1, "нечего сбрасывать — инвентарь цел")


func test_heal_all_restores_to_max() -> void:
	var p := {"hp": 2, "hp_max": 7, "sanity": 1, "sanity_max": 5}
	EffectRunner.run([{"do": "healHealth", "all": true}, {"do": "healSanity", "all": true}], p)
	assert_eq(int(p["hp"]), 7, "healHealth all → до максимума")
	assert_eq(int(p["sanity"]), 5, "healSanity all → до максимума")


# ── moveMonster: выбор монстра с фильтрами, затем клетки назначения ──


func _monster_ctx() -> Dictionary:
	return {
		"monster_choices":
		[
			{"ref": "A#0", "name": "M_GHOUL", "toughness": 1, "epic": false},
			{"ref": "B#0", "name": "M_CTHULHU", "toughness": 5, "epic": true},
		],
		"locations": [{"id": "A", "name": "LOC_A"}, {"id": "C", "name": "LOC_C"}],
	}


func test_move_monster_chosen_asks_monster_then_destination() -> void:
	var node := {
		"do": "moveMonster", "target": "chosenMonster", "where": "chosen", "excludeEpic": true
	}
	var flow := {"interactive": true, "decisions": {}, "rolls": {}, "pending": {}, "slot": "s/"}
	var p := {}
	var res: Dictionary = EffectRunner.run([node], p, _monster_ctx(), flow)
	var pend: Dictionary = res.get("pending", {})
	assert_eq(String(pend.get("kind", "")), "monster", "сначала — выбор монстра")
	var refs: Array = []
	for o_v: Variant in pend.get("options", []):
		refs.append(String((o_v as Dictionary)["ref"]))
	assert_eq(refs, ["A#0"], "эпический отфильтрован (excludeEpic)")
	flow["decisions"][String(pend["path"])] = "A#0"
	flow["pending"] = {}
	res = EffectRunner.run([node], p, _monster_ctx(), flow)
	pend = res.get("pending", {})
	assert_eq(String(pend.get("kind", "")), "destination", "потом — куда переставить")
	flow["decisions"][String(pend["path"])] = "C"
	flow["pending"] = {}
	res = EffectRunner.run([node], p, _monster_ctx(), flow)
	assert_true((res.get("pending", {}) as Dictionary).is_empty(), "решения приняты — пауз нет")
	var board: Array = res.get("board", [])
	assert_eq(board.size(), 1)
	assert_eq(String((board[0] as Dictionary)["_target_monster"]), "A#0")
	assert_eq(String((board[0] as Dictionary)["_target_space"]), "C")
	# Числовой maxToughness тоже фильтрует варианты («стойкость 3 или меньше»).
	var dnode := {"do": "discardMonster", "target": "chosenMonster", "maxToughness": 3}
	var dflow := {"interactive": true, "decisions": {}, "rolls": {}, "pending": {}, "slot": "s/"}
	res = EffectRunner.run([dnode], {}, _monster_ctx(), dflow)
	var opts: Array = (res.get("pending", {}) as Dictionary).get("options", [])
	assert_eq(opts.size(), 1, "Ктулху со стойкостью 5 не предлагается при maxToughness 3")
