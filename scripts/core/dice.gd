class_name Dice
extends RefCounted

## Единая логика бросков кубиков для ВСЕХ проверок (встречи, бой, магазин, …).
## Раньше `randi() % 6 + 1` и подсчёт успехов (≥5) дублировались по нескольким
## файлам — теперь один источник правды. Отрисовка — компонент DiceTray.
##
## Правила Dark Omens: d6, успех = 5 или 6, проверка пройдена при ≥1 успехе,
## переброс за концентрацию — только провального куба.

const SIDES: int       = 6
const SUCCESS_MIN: int  = 5   # успех проверки: выпало 5 или 6
const PASS_MIN: int     = 1   # проверка пройдена, если успехов не меньше


## Один куб (1..SIDES).
static func roll_one() -> int:
	return randi() % SIDES + 1


## Бросить n кубов → массив значений.
static func roll(n: int) -> Array:
	var out: Array = []
	for _i in range(maxi(0, n)):
		out.append(roll_one())
	return out


## Успешен ли куб.
static func is_success(value: int) -> bool:
	return value >= SUCCESS_MIN


## Сколько успехов в наборе.
static func count_successes(dice: Array) -> int:
	var n: int = 0
	for i in range(dice.size()):
		if int(dice[i]) >= SUCCESS_MIN:
			n += 1
	return n


## Перебросить ТОЛЬКО провальный куб (правило переброса за концентрацию).
## Возвращает true, если куб реально переброшен (был провальным и индекс валиден).
static func reroll_failure(dice: Array, idx: int) -> bool:
	if idx < 0 or idx >= dice.size() or is_success(int(dice[idx])):
		return false
	dice[idx] = roll_one()
	return true


## Стандартный результат проверки: { dice, successes, passed }. Единый формат
## для встреч и боя.
static func result(dice: Array) -> Dictionary:
	var s: int = count_successes(dice)
	return { "dice": dice, "successes": s, "passed": s >= PASS_MIN }
