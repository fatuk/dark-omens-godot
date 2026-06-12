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


func test_focus_gain_and_loss_clamp() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "gainFocus", "amount": 2}], p)
	assert_eq(int(p["concentration"]), 2)
	EffectRunner.run([{"do": "loseFocus", "amount": 9}], p)
	assert_eq(int(p["concentration"]), 0, "сосредоточение не ниже 0")


func test_improve_and_impair_skill_accumulate() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "improveSkill", "skill": "lore", "amount": 2}], p)
	EffectRunner.run([{"do": "impairSkill", "skill": "lore", "amount": 1}], p)
	assert_eq(int((p["skill_mods"] as Dictionary)["lore"]), 1, "+2 − 1 = +1 к навыку")
	# skill:"all" — улучшить каждый навык (Markings of Isis «+1 to all skills»).
	EffectRunner.run([{"do": "improveSkill", "skill": "all", "amount": 1}], p)
	assert_eq(int((p["skill_mods"] as Dictionary)["will"]), 1, "all → +1 каждому навыку")
	assert_eq(int((p["skill_mods"] as Dictionary)["lore"]), 2, "lore: 1 + 1(all)")


func test_become_delayed_adds_condition() -> void:
	var p: Dictionary = _player()
	EffectRunner.run([{"do": "becomeDelayed"}], p)
	assert_true((p["conditions"] as Array).has("delayed"))


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


# ── Интерактивный choice (Phase 3): pause → pending → decisions → resume ───────
# В interactive-режиме choice без записанного решения кладёт ветки в flow.pending
# и ОСТАНАВЛИВАЕТ прогон; с решением — идёт в выбранную ветку. Путь верхнеуровневой
# ноды i == String(i), поэтому choice на позиции 0 имеет path "0".


func test_interactive_choice_without_decision_pauses() -> void:
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run(
		[{"choice": [{"do": "gainClue"}, {"do": "loseSanity", "amount": 2}]}],
		p,
		{},
		{"interactive": true}
	)
	var pending: Dictionary = res["pending"]
	assert_eq(String(pending.get("path", "")), "0", "путь choice — верхнеуровневая нода 0")
	assert_eq((pending.get("options", []) as Array).size(), 2, "обе ветки сложены в pending")
	assert_eq(String(pending.get("by", "")), "active", "by по умолчанию active")
	assert_eq(int(p["clues"]), 1, "до выбора ни одна ветка не применяется")
	assert_eq(int(p["sanity"]), 5)


func test_interactive_choice_with_decision_runs_chosen_branch() -> void:
	var p: Dictionary = _player()
	var flow: Dictionary = {"interactive": true, "decisions": {"0": 1}}
	var res: Dictionary = EffectRunner.run(
		[{"choice": [{"do": "gainClue"}, {"do": "loseSanity", "amount": 2}]}], p, {}, flow
	)
	assert_eq(int(p["sanity"]), 3, "выбрана ветка 1 (loseSanity)")
	assert_eq(int(p["clues"]), 1, "ветка 0 не выполнялась")
	assert_eq((res["pending"] as Dictionary).size(), 0, "выбор сделан — паузы нет")


func test_interactive_choice_decision_index_clamped() -> void:
	var p: Dictionary = _player()
	var flow: Dictionary = {"interactive": true, "decisions": {"0": 9}}
	EffectRunner.run(
		[{"choice": [{"do": "gainClue"}, {"do": "loseSanity", "amount": 2}]}], p, {}, flow
	)
	assert_eq(int(p["sanity"]), 3, "индекс за границей → последняя ветка")


func test_interactive_choice_pause_halts_following_nodes() -> void:
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run(
		[{"choice": [{"do": "gainClue"}]}, {"do": "gainClue", "amount": 5}],
		p,
		{},
		{"interactive": true}
	)
	assert_eq(int(p["clues"]), 1, "ноды после паузы не выполняются")
	assert_eq(String((res["pending"] as Dictionary).get("path", "")), "0")


func test_interactive_empty_choice_is_noop() -> void:
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run([{"choice": []}], p, {}, {"interactive": true})
	assert_eq((res["pending"] as Dictionary).size(), 0, "пустой choice — без паузы")
	assert_eq(int(p["clues"]), 1)


func test_interactive_choice_propagates_by_field() -> void:
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run(
		[{"choice": [{"do": "gainClue"}], "by": "lead"}], p, {}, {"interactive": true}
	)
	assert_eq(String((res["pending"] as Dictionary).get("by", "")), "lead", "by берётся из ноды")


func test_interactive_choice_resume_round_trip() -> void:
	var p: Dictionary = _player()
	var effects: Array = [{"choice": [{"do": "gainClue"}, {"do": "loseSanity", "amount": 2}]}]
	# 1-й прогон: решения нет → пауза, стейт не тронут.
	var res1: Dictionary = EffectRunner.run(effects, p, {}, {"interactive": true})
	assert_eq(String((res1["pending"] as Dictionary).get("path", "")), "0")
	assert_eq(int(p["clues"]), 1, "на паузе ничего не применено")
	# Возобновление: тот же набор + записанное решение (как делает GameState).
	var flow2: Dictionary = {"interactive": true, "decisions": {"0": 0}}
	var res2: Dictionary = EffectRunner.run(effects, p, {}, flow2)
	assert_eq(int(p["clues"]), 2, "после выбора применилась ветка 0")
	assert_eq((res2["pending"] as Dictionary).size(), 0)


# ── Передача целей (Phase 4): chosenInvestigator → выбор → нода на доску ───────


func test_interactive_target_without_decision_pauses() -> void:
	var p: Dictionary = _player()
	var ctx: Dictionary = {"other_pids": ["p2", "p3"]}
	var res: Dictionary = EffectRunner.run(
		[{"do": "gainClue", "target": "chosenInvestigator"}], p, ctx, {"interactive": true}
	)
	var pending: Dictionary = res["pending"]
	assert_eq(String(pending.get("kind", "")), "target", "пауза на выборе цели")
	assert_eq(pending.get("options", []) as Array, ["p2", "p3"], "кандидаты из ctx.other_pids")
	assert_eq((res["board"] as Array).size(), 0, "до выбора на доску ничего не уходит")


func test_interactive_target_without_candidates_is_lost() -> void:
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run(
		[{"do": "gainClue", "target": "chosenInvestigator"}], p, {}, {"interactive": true}
	)
	assert_eq((res["pending"] as Dictionary).size(), 0, "некому передавать — без паузы")
	assert_eq((res["board"] as Array).size(), 0, "эффект пропадает")
	assert_eq(int(p["clues"]), 1, "себе тоже не применяется")


func test_interactive_target_with_decision_routes_to_board() -> void:
	var p: Dictionary = _player()
	var ctx: Dictionary = {"other_pids": ["p2"]}
	var flow: Dictionary = {"interactive": true, "decisions": {"0": "p2"}}
	var res: Dictionary = EffectRunner.run(
		[{"do": "gainClue", "target": "chosenInvestigator", "repeat": 2}], p, ctx, flow
	)
	var board: Array = res["board"]
	assert_eq(board.size(), 1, "цель выбрана → адресная нода на доску")
	var node: Dictionary = board[0]
	assert_eq(String(node["_target_pid"]), "p2", "выбранный сыщик")
	assert_eq(String(node["do"]), "gainClue")
	assert_eq(int(node["_times"]), 2, "repeat пробрасывается как _times")
	assert_eq(int(p["clues"]), 1, "себе не применяется")


func test_interactive_lead_target_routes_to_board() -> void:
	# Игровой verb с детерминированной целью (lead) в interactive → на доску с _times
	# (цель развернёт GameState), в отличие от легаси-режима, где применился бы к self.
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run(
		[{"do": "loseHealth", "target": "lead", "amount": 1}], p, {}, {"interactive": true}
	)
	var board: Array = res["board"]
	assert_eq(board.size(), 1)
	assert_eq(String((board[0] as Dictionary)["target"]), "lead")
	assert_eq(int((board[0] as Dictionary)["_times"]), 1)
	assert_eq(int(p["hp"]), 5, "к себе не применяется (в отличие от не-interactive)")


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
