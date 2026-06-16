extends GutTest

## Юнит-тесты интерактивного слоя интерпретатора Effect-DSL (pause/resume):
## choice (Phase 3), гейт стоимости веток, выбор монстра (chosenMonster) и
## передача целей (Phase 4, chosenInvestigator). Вынесено из test_effect_runner.gd,
## чтобы оба файла остались в пределах лимита gdlint на число публичных методов.
## Путь верхнеуровневой ноды i == String(i).

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


# ── Гейт стоимости у веток choice («сделай X, иначе штраф») ───────────────────


func test_choice_cost_affordable_pauses_both() -> void:
	var p: Dictionary = _player()
	p["clues"] = 2
	var effects: Array = [
		{
			"choice":
			[
				{"do": "text", "cost": {"spend": "clue", "amount": 1}},
				{"do": "loseSanity", "amount": 2},
			]
		}
	]
	var res: Dictionary = EffectRunner.run(effects, p, {}, {"interactive": true})
	assert_eq((res["pending"].get("options", []) as Array).size(), 2, "обе ветки доступны → пауза")
	assert_eq(int(p["clues"]), 2, "на паузе улики не списаны")


func test_choice_cost_unaffordable_auto_penalty() -> void:
	var p: Dictionary = _player()
	p["clues"] = 0  # заплатить нечем
	var effects: Array = [
		{
			"choice":
			[
				{"do": "text", "cost": {"spend": "clue", "amount": 1}},
				{"do": "loseSanity", "amount": 2},
			]
		}
	]
	var res: Dictionary = EffectRunner.run(effects, p, {}, {"interactive": true})
	assert_eq((res["pending"] as Dictionary).size(), 0, "нет улик → без выбора, авто-штраф")
	assert_eq(int(p["sanity"]), 3, "применился штраф (−2 рассудка)")


func test_choice_cost_charged_on_pick() -> void:
	var p: Dictionary = _player()
	p["clues"] = 2
	var effects: Array = [
		{
			"choice":
			[
				{"do": "text", "cost": {"spend": "clue", "amount": 1}},
				{"do": "loseSanity", "amount": 2},
			]
		}
	]
	EffectRunner.run(effects, p, {}, {"interactive": true, "decisions": {"0": 0}})
	assert_eq(int(p["clues"]), 1, "выбрал «потратить» → списана 1 улика")
	assert_eq(int(p["sanity"]), 5, "штраф не применён")


func test_choice_cost_discard_condition_affordable() -> void:
	var p: Dictionary = _player()
	p["conditions"] = ["blessed"]  # kind=boon
	var effects: Array = [
		{
			"choice":
			[
				{"do": "text", "cost": {"discardCondition": "boon"}},
				{"do": "loseSanity", "amount": 2},
			]
		}
	]
	var res: Dictionary = EffectRunner.run(effects, p, {}, {"interactive": true})
	assert_eq((res["pending"].get("options", []) as Array).size(), 2, "есть состояние boon → выбор")


func test_choice_cost_discard_condition_unaffordable_auto() -> void:
	var p: Dictionary = _player()  # boon-состояний нет
	var effects: Array = [
		{
			"choice":
			[
				{"do": "text", "cost": {"discardCondition": "boon"}},
				{"do": "loseSanity", "amount": 2},
			]
		}
	]
	var res: Dictionary = EffectRunner.run(effects, p, {}, {"interactive": true})
	assert_eq((res["pending"] as Dictionary).size(), 0, "нет состояния категории → авто-штраф")
	assert_eq(int(p["sanity"]), 3)


func test_choice_cost_discard_condition_charged() -> void:
	var p: Dictionary = _player()
	p["conditions"] = ["blessed", "debt"]  # boon + deal
	(
		EffectRunner
		. run(
			[
				{
					"choice":
					[
						{"do": "text", "cost": {"discardCondition": "boon"}},
						{"do": "loseSanity", "amount": 2},
					]
				}
			],
			p,
			{},
			{"interactive": true, "decisions": {"0": 0}}
		)
	)
	assert_false((p["conditions"] as Array).has("blessed"), "boon-состояние сброшено")
	assert_true((p["conditions"] as Array).has("debt"), "прочие категории целы")
	assert_eq(int(p["sanity"]), 5, "штраф не применён")


# ── Выбор монстра (chosenMonster) + динамическая стойкость ────────────────────


func test_chosen_monster_pends_with_choices() -> void:
	var p: Dictionary = _player()
	var ctx: Dictionary = {"monster_choices": [{"ref": "ark#0", "name": "MON_X", "toughness": 3}]}
	var res: Dictionary = EffectRunner.run(
		[{"do": "discardMonster", "target": "chosenMonster"}], p, ctx, {"interactive": true}
	)
	assert_eq(
		String((res["pending"] as Dictionary).get("kind", "")), "monster", "пауза выбора монстра"
	)
	assert_eq((res["pending"].get("options", []) as Array).size(), 1)


func test_chosen_monster_none_drops() -> void:
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run(
		[{"do": "discardMonster", "target": "chosenMonster"}],
		p,
		{"monster_choices": []},
		{"interactive": true}
	)
	assert_eq((res["pending"] as Dictionary).size(), 0, "нет монстров — без паузы")
	assert_eq((res["board"] as Array).size(), 0, "и без board-узла")


func test_chosen_monster_sets_toughness_and_board() -> void:
	var p: Dictionary = _player()
	var ctx: Dictionary = {"monster_choices": [{"ref": "ark#0", "name": "MON_X", "toughness": 3}]}
	var sub: Array = [
		{"do": "discardMonster", "target": "chosenMonster"},
		{"repeat": {"source": "chosenMonsterToughness"}, "do": "gainClue"},
	]
	var res: Dictionary = EffectRunner.run(
		sub, p, ctx, {"interactive": true, "decisions": {"0": "ark#0"}}
	)
	assert_eq((res["board"] as Array).size(), 1, "один board-узел (сброс монстра)")
	assert_eq(String((res["board"][0] as Dictionary).get("_target_monster", "")), "ark#0")
	assert_eq(int(p["clues"]), 4, "repeat по стойкости выбранного (3) → 1 + 3")


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


# ── Видимая проверка test (checks_visible): pend {kind:check} → decision → ветка ──


func test_interactive_test_pends_check_without_decision() -> void:
	var p: Dictionary = _player()
	var node := {"test": "influence", "modifier": -1, "onPass": [{"do": "gainClue"}], "onFail": []}
	var res: Dictionary = EffectRunner.run(
		[node], p, {}, {"interactive": true, "checks_visible": true}
	)
	var pending: Dictionary = res["pending"]
	assert_eq(String(pending.get("kind", "")), "check", "test пендит проверку")
	assert_eq(String(pending.get("skill", "")), "influence", "навык проверки")
	assert_eq(int(pending.get("modifier", 0)), -1, "модификатор проверки")
	assert_eq(int(p["clues"]), 1, "до решения ветка не выполняется")


func test_interactive_test_passed_decision_runs_onpass() -> void:
	var p: Dictionary = _player()
	# decisions[path]=true → onPass. Путь верхнеуровневой ноды 0 == "0".
	EffectRunner.run(
		[{"test": "influence", "onPass": [{"do": "gainClue"}], "onFail": [{"do": "loseSanity"}]}],
		p,
		{},
		{"interactive": true, "checks_visible": true, "decisions": {"0": true}}
	)
	assert_eq(int(p["clues"]), 2, "passed → onPass (gainClue)")
	assert_eq(int(p["sanity"]), 5, "onFail не выполнялся")


func test_interactive_test_failed_decision_runs_onfail() -> void:
	var p: Dictionary = _player()
	EffectRunner.run(
		[{"test": "influence", "onPass": [{"do": "gainClue"}], "onFail": [{"do": "loseSanity"}]}],
		p,
		{},
		{"interactive": true, "checks_visible": true, "decisions": {"0": false}}
	)
	assert_eq(int(p["sanity"]), 4, "failed → onFail (loseSanity)")
	assert_eq(int(p["clues"]), 1, "onPass не выполнялся")


func test_test_silent_without_checks_visible_flag() -> void:
	# Без флага checks_visible test кидает тихо (seeded). Пустой ctx.skills → auto-pass.
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run(
		[{"test": "influence", "onPass": [{"do": "gainClue"}], "onFail": []}],
		p,
		{},
		{"interactive": true}
	)
	assert_eq((res["pending"] as Dictionary).size(), 0, "без checks_visible проверка не пендит")
	assert_eq(int(p["clues"]), 2, "тихий auto-pass (нет skills) → onPass")
