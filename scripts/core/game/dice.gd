class_name Dice
extends RefCounted

## Единая логика бросков кубиков для ВСЕХ проверок (встречи, бой, магазин, …).
## Раньше `randi() % 6 + 1` и подсчёт успехов (≥5) дублировались по нескольким
## файлам — теперь один источник правды. Отрисовка — компонент DiceTray.
##
## Правила Dark Omens: d6, успех = 5 или 6, проверка пройдена при ≥1 успехе,
## переброс за концентрацию — только провального куба.

const SIDES: int = 6
const SUCCESS_MIN: int = 5  # успех проверки: выпало 5 или 6
const PASS_MIN: int = 1  # проверка пройдена, если успехов не меньше


## Один куб (1..SIDES).
static func roll_one() -> int:
	return randi() % SIDES + 1


## Бросить n кубов → массив значений.
static func roll(n: int) -> Array:
	var out: Array = []
	for _i in range(maxi(0, n)):
		out.append(roll_one())
	return out


## Успешен ли куб. threshold — порог успеха (Cursed → 6, Blessed → 4; дефолт 5).
static func is_success(value: int, threshold: int = SUCCESS_MIN) -> bool:
	return value >= threshold


## Сколько успехов в наборе. threshold — порог успеха (Cursed → 6, Blessed → 4).
static func count_successes(dice: Array, threshold: int = SUCCESS_MIN) -> int:
	var n: int = 0
	for i in range(dice.size()):
		if int(dice[i]) >= threshold:
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
static func result(dice: Array, threshold: int = SUCCESS_MIN) -> Dictionary:
	var s: int = count_successes(dice, threshold)
	return {"dice": dice, "successes": s, "passed": s >= PASS_MIN}


# ── Конвейер модификаторов проверки (активируемые карты, Фаза 5) ───────────────
# mods — список effect-нод активированных карт (do: rollAdditionalDice / addToDie /
# convertDie / improveSkill). До броска меняют пул, после броска — грани/подсчёт.


# Подходит ли мод текущему навыку проверки: без поля skill — всегда; пустой
# целевой навык (skill == "") — не фильтруем; иначе skill мода должен совпасть.
# Карты боя (combatEncounter) несут skill: strength/will — на «не свой» шаг проверки
# (Воля против Силы) их модификаторы применяться не должны.
static func mod_skill_ok(m: Dictionary, skill: String) -> bool:
	return skill.is_empty() or not m.has("skill") or String(m.get("skill", "")) == skill


# Глаголы, меняющие ПУЛ (число кубов) — применяются ТОЛЬКО до броска: в уже
# брошенный набор их не докинуть. Прочие check-mod-глаголы (addToDie/convertDie/
# rerollDice/rerollMatching/enhanceReroll) — результат/перебросы, только ПОСЛЕ.
const PRE_ROLL_VERBS: Array = ["improveSkill", "impairSkill", "rollAdditionalDice", "minDice"]


## Применяется ли мод ДО броска (усиление пула) — иначе после (результат/переброс).
static func mod_is_pre_roll(m: Dictionary) -> bool:
	return PRE_ROLL_VERBS.has(String(m.get("do", "")))


## Доп. кубы к ПУЛУ от активных модификаторов (применяется ДО броска):
## rollAdditionalDice — складываются (разные источники); improveSkill — НЕ
## складываются (бонусы навыка/оружие не суммируются: берём МАКСИМУМ по навыку,
## игрок выбирает лучшее); impairSkill — штрафы вычитаются. skill="" — без фильтра.
static func pre_roll_bonus(mods: Array, skill: String) -> int:
	var dice_bonus: int = 0  # rollAdditionalDice − impairSkill (складываются)
	var best_skill: int = 0  # improveSkill — берём максимум (не складываются)
	for m_v: Variant in mods:
		var m: Dictionary = m_v
		if not mod_skill_ok(m, skill):
			continue
		match String(m.get("do", "")):
			"rollAdditionalDice":
				dice_bonus += int(m.get("count", m.get("amount", 1)))
			"improveSkill":
				best_skill = maxi(best_skill, int(m.get("amount", 0)))
			"impairSkill":
				dice_bonus -= int(m.get("amount", 0))
	return dice_bonus + best_skill


## Применить пост-бросковые addToDie к набору: +amount к count кубам, жадно — тем,
## кого бонус доводит до успеха (наибольший провальный). Возвращает НОВЫЙ массив.
static func apply_add_to_die(
	dice: Array, mods: Array, skill: String = "", threshold: int = SUCCESS_MIN
) -> Array:
	var out: Array = dice.duplicate()
	for m_v: Variant in mods:
		var m: Dictionary = m_v
		if String(m.get("do", "")) != "addToDie" or not mod_skill_ok(m, skill):
			continue
		var amount: int = int(m.get("amount", 1))
		var count: int = maxi(1, int(m.get("count", 1)))
		for _c in range(count):
			var idx: int = _best_die_for_bonus(out, threshold)
			if idx < 0:
				break  # все кубы уже успешны — бонус некуда деть
			out[idx] = mini(SIDES, int(out[idx]) + amount)
	return out


## Заряды +бонуса от addToDie: плоский список величин (по одному на куб). Карта
## «+amount к count кубам» даёт count зарядов по amount. Игрок распределяет их сам
## (тапом по кубу) — см. apply_add_to_die_at. Skill-фильтр как везде (карты боя).
static func add_charges(mods: Array, skill: String = "") -> Array:
	var out: Array = []
	for m_v: Variant in mods:
		var m: Dictionary = m_v
		if String(m.get("do", "")) != "addToDie" or not mod_skill_ok(m, skill):
			continue
		var amount: int = int(m.get("amount", 1))
		var count: int = maxi(1, int(m.get("count", 1)))
		for _c in range(count):
			out.append(amount)
	return out


## Применить addToDie к ВЫБРАННЫМ игроком кубам: заряд i (add_charges) идёт на куб
## targets[i]. В отличие от жадного apply_add_to_die — цель выбирает игрок (любой куб
## < SIDES, включая 5→6 ради карт, которым нужны шестёрки). Возвращает НОВЫЙ массив.
static func apply_add_to_die_at(dice: Array, mods: Array, skill: String, targets: Array) -> Array:
	var out: Array = dice.duplicate()
	var charges: Array = add_charges(mods, skill)
	for i in range(mini(charges.size(), targets.size())):
		var idx: int = int(targets[i])
		if idx >= 0 and idx < out.size():
			out[idx] = mini(SIDES, int(out[idx]) + int(charges[i]))
	return out


# Индекс наибольшего провального куба (<threshold) — лучший кандидат под +бонус.
# Все кубы успешны → -1.
static func _best_die_for_bonus(dice: Array, threshold: int = SUCCESS_MIN) -> int:
	var best: int = -1
	var best_val: int = 0
	for i in range(dice.size()):
		var v: int = int(dice[i])
		if v < threshold and v > best_val:
			best_val = v
			best = i
	return best


## Подсчёт успехов с учётом convertDie ({on:"6", successes:N} — грань on даёт N
## успехов; negate — грань успех снимает). Без convert-нод — как count_successes.
static func count_successes_with(
	dice: Array, mods: Array, skill: String = "", threshold: int = SUCCESS_MIN
) -> int:
	var total: int = 0
	for i in range(dice.size()):
		total += _die_successes(int(dice[i]), mods, skill, threshold)
	return total


static func _die_successes(
	value: int, mods: Array, skill: String = "", threshold: int = SUCCESS_MIN
) -> int:
	var base: int = 1 if value >= threshold else 0
	for m_v: Variant in mods:
		var m: Dictionary = m_v
		if String(m.get("do", "")) != "convertDie" or not mod_skill_ok(m, skill):
			continue
		if value == String(m.get("on", "")).to_int():
			if bool(m.get("negate", false)):
				return 0
			return maxi(base, int(m.get("successes", 1)))
	return base


## Результат проверки с пост-бросковыми модификаторами: применяет addToDie к копии
## кубов, считает успехи с convertDie. skill (если задан) отсекает моды «не своего»
## навыка (карты боя на чужой шаг). { dice (модиф.), successes, passed }.
##
## add_targets: null → addToDie раскидывается ЖАДНО (симулятор, оценка). Массив (в т.ч.
## пустой) → игрок выбирает кубы сам: +бонус только на targets, остальные заряды ждут
## тапа (в игре — CheckFlow передаёт c.add_targets).
static func result_with(
	dice: Array,
	mods: Array,
	skill: String = "",
	threshold: int = SUCCESS_MIN,
	add_targets: Variant = null
) -> Dictionary:
	var modded: Array
	if add_targets == null:
		modded = apply_add_to_die(dice, mods, skill, threshold)
	else:
		modded = apply_add_to_die_at(dice, mods, skill, add_targets as Array)
	var s: int = count_successes_with(modded, mods, skill, threshold)
	return {"dice": modded, "successes": s, "passed": s >= PASS_MIN}
