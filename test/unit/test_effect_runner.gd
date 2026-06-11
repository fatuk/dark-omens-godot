extends GutTest

## Юнит-тесты интерпретатора Effect-DSL (scripts/core/effect_runner.gd).
## Детерминизм бросков — через flow.rolls[path]: путь верхнеуровневой ноды i ==
## String(i), записанный бросок переигрывается без обращения к ГСЧ. Единственная
## внешняя зависимость интерпретатора — Dice (глобальный class_name).

const EffectRunner = preload("res://scripts/core/effect_runner.gd")


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


# ── Маршрутизация целей (board) ───────────────────────────────────────────────


func test_board_verb_goes_to_board_not_player() -> void:
	var p: Dictionary = _player()
	var res: Dictionary = EffectRunner.run([{"do": "advanceDoom", "amount": 1}], p)
	var board: Array = res["board"]
	assert_eq(board.size(), 1, "не-игровой verb уходит на доску")
	assert_eq(String((board[0] as Dictionary)["do"]), "advanceDoom")
	assert_eq(int((board[0] as Dictionary)["_times"]), 1, "проставлен _times для повтора")


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
