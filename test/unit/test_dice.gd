extends GutTest

## Юнит-тесты единой логики кубиков (scripts/core/dice.gd). Правила Dark Omens:
## d6, успех = грань ≥5, проверка пройдена при ≥1 успехе. Здесь же — конвейер
## модификаторов активируемых карт (pre-roll пул и post-roll грани/подсчёт).

# ── Базовые броски и подсчёт ──────────────────────────────────────────────────


func test_roll_one_in_range() -> void:
	for _i in range(50):
		var v: int = Dice.roll_one()
		assert_between(v, 1, 6, "грань d6 в диапазоне 1..6")


func test_roll_n_returns_n_values() -> void:
	assert_eq(Dice.roll(4).size(), 4, "брошено ровно n кубов")
	assert_eq(Dice.roll(0).size(), 0, "ноль кубов → пустой набор")


func test_is_success_threshold() -> void:
	assert_true(Dice.is_success(5), "5 — успех")
	assert_true(Dice.is_success(6), "6 — успех")
	assert_false(Dice.is_success(4), "4 — провал")


func test_is_success_custom_threshold() -> void:
	assert_false(Dice.is_success(5, 6), "Cursed (порог 6): 5 — провал")
	assert_true(Dice.is_success(6, 6), "Cursed: 6 — успех")
	assert_true(Dice.is_success(4, 4), "Blessed (порог 4): 4 — успех")


func test_result_with_threshold_cursed() -> void:
	# Cursed: только 6 — успех (порог 6).
	var r: Dictionary = Dice.result_with([6, 5, 4, 6], [], "", 6)
	assert_eq(int(r["successes"]), 2, "две 6 при пороге 6")
	assert_true(bool(r["passed"]))


func test_result_with_threshold_blessed() -> void:
	# Blessed: 4, 5, 6 — успех (порог 4).
	var r: Dictionary = Dice.result_with([4, 5, 6, 3], [], "", 4)
	assert_eq(int(r["successes"]), 3, "4/5/6 при пороге 4")


func test_count_successes() -> void:
	assert_eq(Dice.count_successes([6, 4, 5, 1]), 2, "успехи: 6 и 5")


func test_result_passed_at_one_success() -> void:
	var r: Dictionary = Dice.result([6, 1, 2])
	assert_eq(int(r["successes"]), 1)
	assert_true(bool(r["passed"]), "≥1 успех → пройдено")


func test_result_failed_without_successes() -> void:
	var r: Dictionary = Dice.result([1, 2, 3, 4])
	assert_eq(int(r["successes"]), 0)
	assert_false(bool(r["passed"]), "0 успехов → провал")


# ── Переброс провального куба ──────────────────────────────────────────────────


func test_reroll_failure_on_success_is_noop() -> void:
	var dice: Array = [6, 2]
	var changed: bool = Dice.reroll_failure(dice, 0)
	assert_false(changed, "успешный куб не перебрасывается")
	assert_eq(int(dice[0]), 6, "значение не изменилось")


func test_reroll_failure_on_failure_rerolls() -> void:
	var dice: Array = [2, 6]
	var changed: bool = Dice.reroll_failure(dice, 0)
	assert_true(changed, "провальный куб переброшен")
	assert_between(int(dice[0]), 1, 6, "новое значение — валидная грань")


func test_reroll_failure_out_of_range() -> void:
	assert_false(Dice.reroll_failure([2, 3], 5), "невалидный индекс → false")


# ── Модификаторы: фильтр навыка и фаза применения ─────────────────────────────


func test_mod_skill_ok() -> void:
	assert_true(Dice.mod_skill_ok({"do": "addToDie"}, "will"), "мод без skill подходит всегда")
	assert_true(Dice.mod_skill_ok({"do": "addToDie", "skill": "will"}, "will"), "совпадение навыка")
	assert_false(Dice.mod_skill_ok({"do": "addToDie", "skill": "strength"}, "will"), "чужой навык")
	assert_true(
		Dice.mod_skill_ok({"do": "addToDie", "skill": "strength"}, ""), "пустой шаг — без фильтра"
	)


func test_mod_is_pre_roll() -> void:
	assert_true(Dice.mod_is_pre_roll({"do": "rollAdditionalDice"}), "пул — до броска")
	assert_false(Dice.mod_is_pre_roll({"do": "addToDie"}), "грани — после броска")


# ── pre_roll_bonus: пул кубов ─────────────────────────────────────────────────


func test_pre_roll_additional_dice_sum() -> void:
	var mods: Array = [
		{"do": "rollAdditionalDice", "count": 2}, {"do": "rollAdditionalDice", "amount": 1}
	]
	assert_eq(Dice.pre_roll_bonus(mods, ""), 3, "доп. кубы складываются (2 + 1)")


func test_pre_roll_improve_skill_takes_max_not_sum() -> void:
	var mods: Array = [{"do": "improveSkill", "amount": 2}, {"do": "improveSkill", "amount": 3}]
	assert_eq(Dice.pre_roll_bonus(mods, ""), 3, "бонусы навыка не суммируются — максимум")


func test_pre_roll_impair_subtracts() -> void:
	assert_eq(Dice.pre_roll_bonus([{"do": "impairSkill", "amount": 1}], ""), -1, "штраф вычитается")


func test_pre_roll_filters_foreign_skill() -> void:
	var mods: Array = [{"do": "rollAdditionalDice", "count": 2, "skill": "strength"}]
	assert_eq(Dice.pre_roll_bonus(mods, "will"), 0, "мод чужого навыка не учитывается")


# ── apply_add_to_die: грани после броска ──────────────────────────────────────


func test_add_to_die_targets_best_failing_die() -> void:
	var out: Array = Dice.apply_add_to_die([4, 2, 6], [{"do": "addToDie", "amount": 1, "count": 1}])
	assert_eq(out, [5, 2, 6], "+1 на наибольший провальный (4 → 5)")


func test_add_to_die_caps_at_six() -> void:
	var out: Array = Dice.apply_add_to_die([4], [{"do": "addToDie", "amount": 9, "count": 1}])
	assert_eq(int(out[0]), 6, "грань не превышает 6")


# ── convertDie: подсчёт успехов ───────────────────────────────────────────────


func test_convert_die_grants_extra_successes() -> void:
	var n: int = Dice.count_successes_with(
		[6, 3], [{"do": "convertDie", "on": "6", "successes": 2}]
	)
	assert_eq(n, 2, "грань 6 даёт 2 успеха, 3 — ноль")


func test_convert_die_negate_removes_success() -> void:
	var n: int = Dice.count_successes_with([6], [{"do": "convertDie", "on": "6", "negate": true}])
	assert_eq(n, 0, "negate снимает успех с грани")


func test_result_with_combines_add_and_count() -> void:
	var r: Dictionary = Dice.result_with([4, 1], [{"do": "addToDie", "amount": 1, "count": 1}])
	assert_eq(r["dice"], [5, 1], "addToDie применён к копии")
	assert_eq(int(r["successes"]), 1, "доведённый до 5 куб — успех")
	assert_true(bool(r["passed"]))
