class_name CheckFlow
extends RefCounted

## Единая «активная проверка» для ВСЕХ потоков (встреча, магазин, бой).
## Хост-авторитетна: состояние в GameState.active_check, синкается всем игрокам.
## Здесь — ОДИН механизм броска, перебросов, доп.кубов и активации карт; потоки
## (EncounterFlow / магазин / бой) лишь начинают проверку и читают результат.
##
##   active_check = {
##     owner: "encounter"|"shop"|"combat",  # кто владеет (для UI/логики потока)
##     pid, skill, modifier, context,       # параметры проверки
##     rolled: bool,
##     base: [сырые d6], dice: [показ с addToDie], successes, passed,
##     active_mods: [ноды активированных карт],
##     reroll_allowance, rerolls_used,      # ПОШТУЧНЫЕ перебросы от карт (до фокуса)
##     reroll_all_allowance, reroll_all_used,  # «перебросить ВСЕ кубы разом» (Талисман)
##     exhausted_cards: [item_index],       # карты, истощённые на ЭТУ проверку
##   }
##
## Карта-конвейер и активируемость — в Dice / AssetCatalog (общие статики).

# rerollDice с count >= порога — это «перебросить ВСЕ провальные кубы разом»
# (конвенция данных: count 99 = «сколько угодно кубов за проверку», как у
# Счастливого талисмана), а не N поштучных перебросов.
const _REROLL_ALL_MIN := 10

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


# ── Жизненный цикл проверки ───────────────────────────────────────────────────


## Свежая проверка (до броска) как словарь — для active_check ИЛИ per-player слота
## (параллельная Расплата: players[pid].reckoning_check). Не привязана к _gs.active_check.
func make_check(
	owner: String, pid: String, skill: String, modifier: int, context: String
) -> Dictionary:
	return {
		"owner": owner,
		"pid": pid,
		"skill": skill,
		"modifier": modifier,
		"context": context,
		"rolled": false,
		"base": [],
		"dice": [],
		"successes": 0,
		"passed": false,
		"active_mods": [],  # все карты (action + пассивы) применяются тапом в вееро
		"reroll_allowance": 0,
		"rerolls_used": 0,
		"reroll_all_allowance": 0,
		"reroll_all_used": 0,
		"exhausted_cards": [],
		"add_targets": [],  # кубы, на которые игрок положил +1 от addToDie (тапом)
	}


## Начать проверку (до броска). Перетирает прежнюю активную.
func start(owner: String, pid: String, skill: String, modifier: int, context: String) -> void:
	_gs.active_check = make_check(owner, pid, skill, modifier, context)


## Снять активную проверку.
func clear() -> void:
	_gs.active_check = {}


## Сохранить текущую активную проверку в стек (вложенный каст: incantation над
## боевой проверкой). Затем start() поверх перетрёт active_check; pop() — вернёт.
func push() -> void:
	(_gs._check_stack as Array).append((_gs.active_check as Dictionary).duplicate(true))


## Вернуть последнюю сохранённую проверку в active_check (либо {} если стек пуст).
func pop() -> void:
	var stack: Array = _gs._check_stack
	_gs.active_check = stack.pop_back() if not stack.is_empty() else {}


## Пул d6 = навык сыщика + модификаторы навыка + модификатор проверки + доп.кубы
## активированных карт (pre_roll_bonus). Для показа рубашек до броска и самого броска.
func pool(c: Dictionary) -> int:
	var p: Dictionary = _gs.players.get(String(c.get("pid", "")), {})
	var skill: String = String(c.get("skill", "will"))
	var inv: Dictionary = Investigators.get_data(String(p.get("investigator", "")))
	var base: int = int((inv.get("skills", {}) as Dictionary).get(skill, 1))
	var mods: int = int((p.get("skill_mods", {}) as Dictionary).get(skill, 0))
	var bonus: int = Dice.pre_roll_bonus(c.get("active_mods", []), skill)
	return maxi(1, base + mods + int(c.get("modifier", 0)) + bonus)


# ── Операции (хост) ───────────────────────────────────────────────────────────


## Хост: бросок проверки игрока pid. c — слот проверки (пусто → _gs.active_check; иначе
## per-player слот, напр. players[pid].reckoning_check). true — бросок сделан и разослан.
func roll(pid: String, c: Dictionary = {}) -> bool:
	if c.is_empty():
		c = _gs.active_check
	if c.is_empty() or String(c.get("pid", "")) != pid or bool(c.get("rolled", false)):
		return false
	_set_roll(c, Dice.roll(pool(c)))
	c["rolled"] = true
	c["rerolls_used"] = 0
	c["reroll_allowance"] = _allowance(c)
	c["reroll_all_used"] = 0
	c["reroll_all_allowance"] = _allowance_all(c)
	_sync()
	return true


## Хост: переброс выбранного куба. currency — ЯВНАЯ валюта (перетащили жетон:
## "concentration"/"clue"/"free") или "" = авто-приоритет (тап по кубу: карта →
## концентрация → улика). Куб должен быть провальным по отображаемому значению.
func reroll(pid: String, die_index: int, currency: String = "", c: Dictionary = {}) -> bool:
	if c.is_empty():
		c = _gs.active_check
	if c.is_empty() or String(c.get("pid", "")) != pid or not bool(c.get("rolled", false)):
		return false
	var p: Dictionary = _gs.players.get(pid, {})
	var base: Array = c.get("base", [])
	var shown: Array = c.get("dice", base)
	if (
		die_index < 0
		or die_index >= base.size()
		or Dice.is_success(int(shown[die_index]), _threshold(c))
	):
		return false
	var used: int = int(c.get("rerolls_used", 0))
	var free: bool = used < int(c.get("reroll_allowance", 0))
	var foc: int = int(p.get("concentration", 0))
	var clues: int = int(p.get("clues", 0))
	# Выбор валюты: явная (жетон) проверяет наличие; пустая — авто-приоритет.
	var pay: String = ""
	match currency:
		"free":
			pay = "free" if free else ""
		"concentration":
			pay = "concentration" if foc > 0 else ""
		"clue":
			pay = "clue" if clues > 0 else ""
		_:
			pay = (
				"free" if free else ("concentration" if foc > 0 else ("clue" if clues > 0 else ""))
			)
	if pay.is_empty():
		return false  # нечем перебрасывать выбранной/любой валютой
	base[die_index] = Dice.roll_one()
	_set_roll(c, base)
	match pay:
		"free":
			c["rerolls_used"] = used + 1
		"concentration":
			p["concentration"] = foc - 1
		"clue":
			p["clues"] = clues - 1
	# Монотонная метка переброса: даёт UI отличить «перебросил, выпало ТО ЖЕ значение»
	# от «ничего не нажалось». Без неё переброс в ту же грань не анимируется и клик
	# выглядит смазанным/съеденным (фокус потрачен, куб не дёрнулся).
	c["reroll_nonce"] = int(c.get("reroll_nonce", 0)) + 1
	c["reroll_index"] = die_index
	_sync()
	return true


## UI-валидация (без мутаций): можно ли перебросить ЭТОТ куб проверки c прямо сейчас —
## в диапазоне и НЕ успех по порогу проверки. Зеркалит гард reroll() ДО оплаты. Нужна,
## чтобы клик по неперебрасываемому кубу не «съедал» заряженный жетон и не засчитывал
## попытку (см. GameState.reroll_die): валюту тратим только при реальном перебросе.
func die_is_rerollable(pid: String, die_index: int, c: Dictionary = {}) -> bool:
	if c.is_empty():
		c = _gs.active_check
	if c.is_empty() or String(c.get("pid", "")) != pid or not bool(c.get("rolled", false)):
		return false
	var base: Array = c.get("base", [])
	var shown: Array = c.get("dice", base)
	if die_index < 0 or die_index >= shown.size():
		return false
	return not Dice.is_success(int(shown[die_index]), _threshold(c))


## Сколько зарядов +1 (addToDie) ещё не положено на кубы: всего зарядов из карт
## минус уже распределённых (add_targets). 0 → добавлять нечего.
func add_available(c: Dictionary = {}) -> int:
	if c.is_empty():
		c = _gs.active_check
	if c.is_empty() or not bool(c.get("rolled", false)):
		return 0
	var total: int = Dice.add_charges(c.get("active_mods", []), String(c.get("skill", ""))).size()
	return maxi(0, total - (c.get("add_targets", []) as Array).size())


## UI-валидация (без мутаций): можно ли положить +1 на ЭТОТ куб — есть свободный заряд
## и куб ещё не «шестёрка» (< SIDES). В отличие от переброса, применимо и к успешным
## кубам (5→6 ради карт, которым нужны шестёрки). Зеркалит гард apply_add_die.
func die_can_add(pid: String, die_index: int, c: Dictionary = {}) -> bool:
	if c.is_empty():
		c = _gs.active_check
	if c.is_empty() or String(c.get("pid", "")) != pid or not bool(c.get("rolled", false)):
		return false
	if add_available(c) <= 0:
		return false
	var shown: Array = c.get("dice", c.get("base", []))
	if die_index < 0 or die_index >= shown.size():
		return false
	return int(shown[die_index]) < Dice.SIDES


## Хост: положить +1 (addToDie) на выбранный игроком куб. Заряд один — куб любой < 6.
## Пересчёт идемпотентен (dice выводится из base + active_mods + add_targets). true —
## заряд лёг и разослан.
func add_die(pid: String, die_index: int, c: Dictionary = {}) -> bool:
	if c.is_empty():
		c = _gs.active_check
	if not die_can_add(pid, die_index, c):
		return false
	var targets: Array = c.get("add_targets", [])
	targets.append(die_index)
	c["add_targets"] = targets
	_set_roll(c, c.get("base", []))
	# reroll_nonce/index — чтобы лоток анимировал изменившийся куб (как при перебросе).
	c["reroll_nonce"] = int(c.get("reroll_nonce", 0)) + 1
	c["reroll_index"] = die_index
	_sync()
	return true


## Хост: применить карту руки (item_index) к активной проверке (тап в вееро). Любая
## карта применяется вручную — иммерсивно: и action (по выбору), и пассивы whileOwned
## (.38 Revolver, Lucky Ring). Способность правит бросок; карта оплачивается/истощается.
## Можно до и после броска. Каждую карту — раз за проверку. true при успехе.
func activate(pid: String, item_index: int) -> bool:
	var c: Dictionary = _gs.active_check
	if c.is_empty() or String(c.get("pid", "")) != pid:
		return false
	var p: Dictionary = _gs.players.get(pid, {})
	var items: Array = p.get("items", [])
	if item_index < 0 or item_index >= items.size():
		return false
	var it_v: Variant = items[item_index]
	if not (it_v is Dictionary):
		return false
	var it: Dictionary = it_v
	if bool(it.get("exhausted", false)):
		return false  # уже истощена в этом раунде (oncePerRound)
	if (c.get("exhausted_cards", []) as Array).has(item_index):
		return false  # уже применена в ЭТОЙ проверке
	var entry: String = AssetCatalog.entry_id(it)
	var asset: Dictionary = AssetCatalog.by_id(entry)
	# Glamour-заклинание: его пассив-аура применяется к проверке как пассив актива.
	var glamour: Dictionary = SpellCatalog.by_id(entry) if asset.is_empty() else {}
	var is_glam: bool = String(glamour.get("subtype", "")) == "glamour"
	if asset.is_empty() and not is_glam:
		return false
	var ctx: String = String(c.get("context", ""))
	var skill: String = String(c.get("skill", ""))
	var rolled: bool = bool(c.get("rolled", false))
	# Фильтр модов: (1) навык шага (карта боя combatEncounter несёт skill strength/will
	# — на «не свой» шаг не применяем, иначе карта истощится впустую); (2) ТАЙМИНГ —
	# усиление пула (навык/доп.кубы) только ДО броска, результат/перебросы только ПОСЛЕ.
	var ok := func(m_v3: Variant) -> bool:
		return Dice.mod_skill_ok(m_v3, skill) and Dice.mod_is_pre_roll(m_v3) != rolled
	# Glamour — только пассив-аура (без cost/limit); актив — action + passive.
	var action_mods: Array = (
		[] if is_glam else AssetCatalog.action_check_mods(asset, ctx).filter(ok)
	)
	var passive_mods: Array = (
		SpellCatalog.aura_check_mods(glamour, ctx).filter(ok)
		if is_glam
		else AssetCatalog.passive_check_mods(asset, ctx).filter(ok)
	)
	var mods: Array = action_mods.duplicate()
	mods.append_array(passive_mods)
	if mods.is_empty():
		return false  # нет применимой способности под контекст/навык/тайминг

	# Стоимость/лимит — из action-нод (пассивы без стоимости).
	var cost: Dictionary = {}
	var limit: String = ""
	for m_v: Variant in action_mods:
		var m: Dictionary = m_v
		if m.has("cost"):
			cost = m["cost"]
		if m.has("limit"):
			limit = String(m["limit"])
	if cost.has("spend"):
		var res: String = String(cost.get("spend", ""))
		var amt: int = int(cost.get("amount", 1))
		if not _can_pay(p, res, amt):
			return false
		_pay(p, res, amt)

	# Добавить модификаторы к активным (бонус навыка НЕ складывается — см.
	# Dice.pre_roll_bonus: берётся максимум, не сумма).
	var skill_c: String = String(c.get("skill", ""))
	var bonus_before: int = Dice.pre_roll_bonus(c.get("active_mods", []), skill_c)
	var active: Array = c.get("active_mods", [])
	for m_v2: Variant in mods:
		active.append(m_v2)
	c["active_mods"] = active

	# Бросок уже сделан → докидываем ТОЛЬКО прирост доп.кубов (дельта бонуса) и
	# пересчитываем. Так improveSkill не задваивает кубы при второй карте.
	if bool(c.get("rolled", false)):
		var base: Array = c.get("base", [])
		var add: int = Dice.pre_roll_bonus(active, skill_c) - bonus_before
		for _i in range(maxi(0, add)):
			base.append(Dice.roll_one())
		_set_roll(c, base)
		c["reroll_allowance"] = _allowance(c)
		c["reroll_all_allowance"] = _allowance_all(c)

	# Истощение/сброс: discardSelf сбрасывает карту; action oncePerRound — до конца
	# раунда (item.exhausted, Refresh-шаг); прочее (пассивы) — на ТЕКУЩУЮ проверку.
	if bool(cost.get("discardSelf", false)):
		items.remove_at(item_index)
		p["items"] = items
	elif limit == "oncePerRound":
		it["exhausted"] = true
	else:
		var ex: Array = c.get("exhausted_cards", [])
		ex.append(item_index)
		c["exhausted_cards"] = ex

	var card_id: String = String(glamour.get("id", "")) if is_glam else String(asset.get("id", ""))
	GameConsole.log("[Карта] %s применил «%s»" % [_gs._name_of(pid), card_id])
	_sync()
	return true


# ── Внутреннее ────────────────────────────────────────────────────────────────


# Выставить результат из сырых кубов base + active_mods (идемпотентно: dice/успехи
# всегда выводятся из base, addToDie не накапливается).
func _set_roll(c: Dictionary, base: Array) -> void:
	# add_targets (даже пустой) → addToDie кладётся ТОЛЬКО на выбранные игроком кубы,
	# без жадности: незаряженные +1 ждут тапа (apply_add_die).
	var r: Dictionary = Dice.result_with(
		base,
		c.get("active_mods", []),
		String(c.get("skill", "")),
		_threshold(c),
		c.get("add_targets", [])
	)
	c["base"] = base
	c["dice"] = r.get("dice", base)
	c["successes"] = int(r.get("successes", 0))
	c["passed"] = bool(r.get("passed", false))


# Порог успеха активного игрока проверки (Cursed → 6, Blessed → 4; дефолт 5).
# Защищённо: если у _gs нет _cond (тест-моки) — дефолт Dice.SUCCESS_MIN.
func _threshold(c: Dictionary) -> int:
	var cond: Variant = _gs.get("_cond")
	if cond != null and (cond as Object).has_method("player_success_threshold"):
		return int(cond.player_success_threshold(String(c.get("pid", ""))))
	return Dice.SUCCESS_MIN


# Запас ПОШТУЧНЫХ перебросов от карт = Σ rerollDice.count среди active_mods,
# КРОМЕ «перебросить всё» (count >= _REROLL_ALL_MIN — отдельный счётчик ниже).
func _allowance(c: Dictionary) -> int:
	var total: int = 0
	for m_v: Variant in c.get("active_mods", []):
		var m: Dictionary = m_v
		if String(m.get("do", "")) == "rerollDice":
			var cnt: int = int(m.get("count", 1))
			if cnt < _REROLL_ALL_MIN:
				total += cnt
	return total


# Сколько раз доступно «перебросить ВСЕ провальные кубы разом» = число rerollDice
# с count >= _REROLL_ALL_MIN среди active_mods (карты «перебрось сколько угодно»).
func _allowance_all(c: Dictionary) -> int:
	var n: int = 0
	for m_v: Variant in c.get("active_mods", []):
		var m: Dictionary = m_v
		if String(m.get("do", "")) == "rerollDice" and int(m.get("count", 1)) >= _REROLL_ALL_MIN:
			n += 1
	return n


## Хост: перебросить ВСЕ кубы разом (эффект карт «перебрось сколько угодно», напр.
## Счастливый талисман). Бесплатно — расход одно использование reroll-all.
## Перебрасывает все кубы пула (включая успешные — это явный «полный переброс»;
## выборочно провальные перебрасывают тапом по кубу). true при перебросе.
func reroll_all(pid: String, c: Dictionary = {}) -> bool:
	if c.is_empty():
		c = _gs.active_check
	if c.is_empty() or String(c.get("pid", "")) != pid or not bool(c.get("rolled", false)):
		return false
	if int(c.get("reroll_all_used", 0)) >= int(c.get("reroll_all_allowance", 0)):
		return false  # нет доступного «перебросить всё»
	var base: Array = c.get("base", [])
	if (base as Array).is_empty():
		return false
	for i in range(base.size()):
		base[i] = Dice.roll_one()
	_set_roll(c, base)
	c["reroll_all_used"] = int(c.get("reroll_all_used", 0)) + 1
	GameConsole.log("[Переброс] %s · перебросил все кубы" % _gs._name_of(pid))
	_sync()
	return true


# Может ли игрок оплатить ресурс-стоимость активации (asset/spell пока не поддержаны).
# Стоимость активации карты не может убить владельца → allow_lethal=false («> amt»).
func _can_pay(p: Dictionary, res: String, amt: int) -> bool:
	return ResourceLedger.can_pay(p, res, amt, false)


# Списать ресурс-стоимость активации.
func _pay(p: Dictionary, res: String, amt: int) -> void:
	ResourceLedger.spend(p, res, amt)


func _sync() -> void:
	_gs._broadcast_sync()
	_gs._emit_changed()
