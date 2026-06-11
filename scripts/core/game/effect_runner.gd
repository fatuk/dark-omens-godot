## Интерпретатор Effect-DSL — обходит дерево эффектов и применяет к игроку.
## Встречи, карты Мифов и Мистерии используют один DSL (см. EFFECT-DSL.md
## в relay-репозитории).
##
##   run(effects, player) → { "logs": Array[String], "board": Array[Dictionary] }
##     player — словарь игрока из GameState.players, мутируется по месту;
##     board  — действия уровня поля (advanceDoom и т.п.); их применяет сам
##              GameState — у интерпретатора нет доступа к стейту поля.
##
## Подключается через preload (см. game_state.gd) — без class_name/autoload.

# Глаголы, меняющие игрока. Прочие — уровня поля, складываются в board.
const _PLAYER_VERBS := [
	"loseHealth",
	"healHealth",
	"loseSanity",
	"healSanity",
	"gainClue",
	"loseClue",
	"spendClue",
	"gainCondition",
	"loseCondition",
	"gainAsset",
	"gainSpell",
	"gainArtifact",
	"gainImprovement",
	"loseAsset",
	"loseSpell",
	"loseImprovement",
	"gainFocus",
	"loseFocus",
	"improveSkill",
	"impairSkill",
	"becomeDelayed",
	"move",
	"text",
	# v2/v3: пассивные модификаторы проверок/боя/правил — собираются в
	# player.passive_mods, слой разрешения читает их (см. EFFECT-DSL.md §11–12).
	"rerollDice",
	"rollAdditionalDice",
	"addToDie",
	"convertDie",
	"reduceMonsterDamage",
	"reduceMonsterHorror",
	"preventLoss",
	"substituteSkill",
	"substituteResource",
	"enhanceReroll",
	"rerollMatching",
	"minDice",
	"immuneTo",
	"protectResource",
	# v4: ограничения (пассивы состояний)
	"cannotMove",
	"cannotAct",
	"cannotRecover",
	"removeFromBoard",
	"immuneToEffects",
]

# Глаголы-пассивы: не мутируют игрока сразу, а копятся как модификаторы.
const _PASSIVE_VERBS := [
	"rerollDice",
	"rollAdditionalDice",
	"addToDie",
	"convertDie",
	"reduceMonsterDamage",
	"reduceMonsterHorror",
	"preventLoss",
	"substituteSkill",
	"substituteResource",
	"enhanceReroll",
	"rerollMatching",
	"minDice",
	"immuneTo",
	"protectResource",
	"cannotMove",
	"cannotAct",
	"cannotRecover",
	"removeFromBoard",
	"immuneToEffects",
]


## ctx (опц.) — контекст исполнения: { skills, loc_type, is_lead, gates_matching_omen,
## gates_on_board, monsters_on_board, clues_on_board, rumors_in_play, monster_toughness }.
## Нужен для реального test (навыки), предикатов when и счётчиков repeat. Пусто
## (мифос/хуки без контекста) → test считается пройденным, board-предикаты — истинными.
##
## flow (опц.) — состояние интерактивного прогона choice + детерминизма replay:
##   { interactive:bool, decisions:{path→idx}, rolls:{path→[d…]}, pending:{}, slot:String }.
##   Пусто → старое поведение (choice берёт первую ветку, проверки катятся заново).
##   interactive → встретив choice без записанного решения, кладём ветки в
##   flow.pending и ОСТАНАВЛИВАЕМ прогон; броски пишутся в rolls и переигрываются,
##   чтобы повтор после выбора шёл тем же путём. Возврат несёт pending (или {}).
static func run(
	effects: Array, player: Dictionary, ctx: Dictionary = {}, flow: Dictionary = {}
) -> Dictionary:
	var logs: Array = []
	var board: Array = []
	var root: String = String(flow.get("slot", ""))
	for i in range(effects.size()):
		if not _stopped(flow):
			_run_node(effects[i], player, logs, board, ctx, flow, root + str(i))
	return {"logs": logs, "board": board, "pending": flow.get("pending", {})}


# ── Обход дерева ──────────────────────────────────────────────────────────────


# Прогон остановлен — choice ждёт решения игрока (flow.pending заполнен).
static func _stopped(flow: Dictionary) -> bool:
	return not (flow.get("pending", {}) as Dictionary).is_empty()


static func _run_node(
	node: Dictionary,
	player: Dictionary,
	logs: Array,
	board: Array,
	ctx: Dictionary,
	flow: Dictionary,
	path: String
) -> void:
	if _stopped(flow):
		return
	if node.has("group"):
		var children: Array = node["group"]
		for i in range(children.size()):
			if _stopped(flow):
				return
			_run_node(children[i], player, logs, board, ctx, flow, path + "/g" + str(i))
		return
	if node.has("choice"):
		_run_choice(node, player, logs, board, ctx, flow, path)
		return
	if node.has("dieRoll"):
		var d: int = _die_value(flow, path)
		var rules: Array = node["dieRoll"]
		for i in range(rules.size()):
			var rule: Dictionary = rules[i]
			if _in_range(d, String(rule.get("on", ""))):
				var then: Array = rule.get("then", [])
				for j in range(then.size()):
					if _stopped(flow):
						return
					_run_node(then[j], player, logs, board, ctx, flow, path + "/d%d_%d" % [i, j])
				break
		return
	if node.has("test"):
		var passed: bool = _roll_test(node, player, ctx, flow, path)
		var branch: Array = node.get("onPass" if passed else "onFail", [])
		var pfx: String = "/p" if passed else "/f"
		for i in range(branch.size()):
			if _stopped(flow):
				return
			_run_node(branch[i], player, logs, board, ctx, flow, path + pfx + str(i))
		return
	if node.has("do"):
		_run_action(node, player, logs, board, ctx, flow, path)


## Публично: применить ОДИН игровой verb к словарю игрока. Для GameState — когда
## эффект адресован другому сыщику (target lead/each/chosenInvestigator) и
## применяется на уровне поля. Возвращает строки-логи.
static func apply_player_verb(verb: String, node: Dictionary, player: Dictionary) -> Array:
	var logs: Array = []
	_apply_player_verb(verb, node, player, logs)
	return logs


## Игровой ли это verb (меняет состояние сыщика). Для маршрутизации целей в GameState.
static func is_player_verb(verb: String) -> bool:
	return _PLAYER_VERBS.has(verb)


# Узел choice. Без interactive — берём первую ветку (легаси). С interactive: есть
# записанное решение (flow.decisions[path]) → идём в выбранную ветку; нет → кладём
# ветки в flow.pending и останавливаемся (игрок выберет, прогон переиграется).
static func _run_choice(
	node: Dictionary,
	player: Dictionary,
	logs: Array,
	board: Array,
	ctx: Dictionary,
	flow: Dictionary,
	path: String
) -> void:
	var branches: Array = node["choice"]
	if branches.is_empty():
		return
	if not bool(flow.get("interactive", false)):
		_run_node(branches[0], player, logs, board, ctx, flow, path + "/c0")
		return
	var decisions: Dictionary = flow.get("decisions", {})
	if decisions.has(path):
		var idx: int = clampi(int(decisions[path]), 0, branches.size() - 1)
		_run_node(branches[idx], player, logs, board, ctx, flow, path + "/c" + str(idx))
		return
	flow["pending"] = {
		"path": path, "options": branches.duplicate(), "by": String(node.get("by", "active"))
	}


## Вложенная проверка. Есть навыки в ctx → реальный бросок (как CheckFlow.pool):
## pool = базовый навык + skill_mods + modifier, успех при ≥1 успехе. Нет навыков
## (нет контекста) → считаем пройденной. Бросок пишется/переигрывается через flow.
static func _roll_test(
	node: Dictionary, player: Dictionary, ctx: Dictionary, flow: Dictionary, path: String
) -> bool:
	var skills: Dictionary = ctx.get("skills", {})
	if (skills as Dictionary).is_empty():
		return true
	var skill: String = String(node["test"])
	var mods: Dictionary = player.get("skill_mods", {})
	var pool: int = maxi(
		1, int(skills.get(skill, 1)) + int(mods.get(skill, 0)) + int(node.get("modifier", 0))
	)
	return bool(Dice.result(_roll_dice(flow, path, pool)).get("passed", false))


# Бросок пула d6 с записью/переигровкой по path (детерминизм при возобновлении
# после choice). Без flow (легаси) — просто свежий бросок.
static func _roll_dice(flow: Dictionary, path: String, pool: int) -> Array:
	var rolls: Dictionary = flow.get("rolls", {})
	if rolls.has(path):
		return rolls[path]
	var dice: Array = Dice.roll(pool)
	if not flow.is_empty():
		rolls[path] = dice
		flow["rolls"] = rolls
	return dice


# Один d6 для dieRoll с записью/переигровкой по path (см. _roll_dice).
static func _die_value(flow: Dictionary, path: String) -> int:
	var rolls: Dictionary = flow.get("rolls", {})
	if rolls.has(path):
		var rec: Array = rolls[path]
		return int(rec[0]) if not rec.is_empty() else Dice.roll_one()
	var d: int = Dice.roll_one()
	if not flow.is_empty():
		rolls[path] = [d]
		flow["rolls"] = rolls
	return d


static func _run_action(
	node: Dictionary,
	player: Dictionary,
	logs: Array,
	board: Array,
	ctx: Dictionary,
	flow: Dictionary,
	path: String
) -> void:
	if node.has("when") and not _predicate(node["when"], player, ctx):
		return
	var verb: String = String(node["do"])
	var target: String = String(node.get("target", ""))
	var interactive: bool = bool(flow.get("interactive", false))
	# (1) Игровой verb к ПЕРЕДАННОМУ игроку: самонаправленный, либо легаси-режим
	#     (мифос/хуки сами разворачивают target по игрокам и зовут run без flow —
	#     тогда применяем к тому игроку, что передали).
	if _PLAYER_VERBS.has(verb) and (target.is_empty() or target == "self" or not interactive):
		var times: int = _repeat(node, player, ctx)
		for _i in times:
			_apply_player_verb(verb, node, player, logs)
		return
	# (2) Интерактивный выбор цели (передача активов/улик другому сыщику) — только
	#     в interactive-прогоне встречи. Нет решения → пауза; есть → нода в board.
	if interactive and (target == "chosenInvestigator" or target == "chosen"):
		var decisions: Dictionary = flow.get("decisions", {})
		if not decisions.has(path):
			var opts: Array = ctx.get("other_pids", [])
			if (opts as Array).is_empty():
				return  # некому передавать — эффект пропадает
			flow["pending"] = {"kind": "target", "path": path, "options": opts.duplicate()}
			return
		var rnode: Dictionary = node.duplicate(true)
		rnode["_target_pid"] = String(decisions[path])
		rnode["_times"] = _repeat(node, player, ctx)
		board.append(rnode)  # GameState применит к выбранному сыщику
		return
	# (3) board-verb ИЛИ игровой verb с детерминированной целью (lead/each/eachOn*)
	#     → на доску с разрешённым повтором; цель разрешит GameState.
	var bnode: Dictionary = node.duplicate(true)
	bnode["_times"] = _repeat(node, player, ctx)
	board.append(bnode)


# ── Действия по игроку ────────────────────────────────────────────────────────


static func _apply_player_verb(
	verb: String, node: Dictionary, player: Dictionary, logs: Array
) -> void:
	var n: int = _amount(node)
	match verb:
		"loseHealth":
			player["hp"] = maxi(0, int(player.get("hp", 0)) - n)
			logs.append("−%d здоровья" % n)
		"healHealth":
			player["hp"] = mini(int(player.get("hp_max", 0)), int(player.get("hp", 0)) + n)
			logs.append("+%d здоровья" % n)
		"loseSanity":
			player["sanity"] = maxi(0, int(player.get("sanity", 0)) - n)
			logs.append("−%d рассудка" % n)
		"healSanity":
			player["sanity"] = mini(
				int(player.get("sanity_max", 0)), int(player.get("sanity", 0)) + n
			)
			logs.append("+%d рассудка" % n)
		"gainClue":
			player["clues"] = int(player.get("clues", 0)) + n
			logs.append("+%d улик" % n)
		"loseClue", "spendClue":
			player["clues"] = maxi(0, int(player.get("clues", 0)) - n)
			logs.append("−%d улик" % n)
		"gainCondition":
			var cid: String = String(node.get("condition", ""))
			if not cid.is_empty():
				var conds: Array = player.get("conditions", [])
				if not conds.has(cid):
					conds.append(cid)
				player["conditions"] = conds
				logs.append("состояние «%s»" % cid)
		"loseCondition":
			var rid: String = String(node.get("condition", ""))
			var rconds: Array = player.get("conditions", [])
			rconds.erase(rid)
			player["conditions"] = rconds
			(player.get("conditions_flipped", {}) as Dictionary).erase(rid)
			logs.append("снято состояние «%s»" % rid)
		"gainAsset", "gainSpell", "gainArtifact", "gainImprovement":
			# MVP: маркер предмета; полноценный карточный контент — отдельный слой.
			var items: Array = player.get("items", [])
			items.append(verb)
			player["items"] = items
			logs.append("получен предмет (%s)" % verb)
		"loseAsset", "loseSpell", "loseImprovement":
			var litems: Array = player.get("items", [])
			if not litems.is_empty():
				litems.pop_back()
			player["items"] = litems
			logs.append("утрачен предмет")
		"gainFocus":
			player["concentration"] = int(player.get("concentration", 0)) + n
			logs.append("+%d сосредоточения" % n)
		"loseFocus":
			player["concentration"] = maxi(0, int(player.get("concentration", 0)) - n)
			logs.append("−%d сосредоточения" % n)
		"improveSkill", "impairSkill":
			var skill: String = String(node.get("skill", ""))
			if not skill.is_empty():
				var mods: Dictionary = player.get("skill_mods", {})
				var delta: int = n if verb == "improveSkill" else -n
				mods[skill] = int(mods.get(skill, 0)) + delta
				player["skill_mods"] = mods
				logs.append("навык %s %+d" % [skill, delta])
		"becomeDelayed":
			var dconds: Array = player.get("conditions", [])
			if not dconds.has("delayed"):
				dconds.append("delayed")
			player["conditions"] = dconds
			logs.append("задержка")
		"move", "text":
			pass  # move — трекинга позиции пока нет; text — только показ
		_:
			if _PASSIVE_VERBS.has(verb):
				# Пассивный модификатор: сохраняем узел целиком — боевой/проверочный
				# слой прочитает его при разрешении (reroll, +к кубику, −урон монстра…).
				var mods: Array = player.get("passive_mods", [])
				mods.append(node)
				player["passive_mods"] = mods
				logs.append("модификатор: %s" % verb)


# ── Хелперы ───────────────────────────────────────────────────────────────────


## Величина действия: amount либо count, по умолчанию 1.
static func _amount(node: Dictionary) -> int:
	if node.has("amount"):
		return int(node["amount"])
	if node.has("count"):
		return int(node["count"])
	return 1


## Повтор действия. repeat-литерал → число; repeat по источнику ({source}) →
## из ctx/игрока (для-каждого). Нет данных → 1, чтобы поведение без контекста
## совпадало со старым.
static func _repeat(node: Dictionary, player: Dictionary, ctx: Dictionary) -> int:
	var r: Variant = node.get("repeat", 1)
	if r is int:
		return maxi(1, int(r))
	if r is Dictionary:
		return maxi(
			0,
			_count_source(String((r as Dictionary).get("source", "")), r as Dictionary, player, ctx)
		)
	return 1


## Счётчик источника для repeat/«для каждого». Нет данных в ctx → 1 (мягко).
static func _count_source(
	source: String, spec: Dictionary, player: Dictionary, ctx: Dictionary
) -> int:
	match source:
		"gatesMatchingOmen":
			return int(ctx.get("gates_matching_omen", 1))
		"gatesOnBoard":
			return int(ctx.get("gates_on_board", 1))
		"monstersOnBoard":
			return int(ctx.get("monsters_on_board", 1))
		"cluesOnBoard":
			return int(ctx.get("clues_on_board", 1))
		"rumorsInPlay":
			return int(ctx.get("rumors_in_play", 1))
		"monsterToughness":
			return int(ctx.get("monster_toughness", 1))
		"conditions":
			var conds: Array = player.get("conditions", [])
			var cond: String = String(spec.get("condition", ""))
			if cond.is_empty():
				return conds.size()
			var c: int = 0
			for x in conds:
				if String(x) == cond:
					c += 1
			return c
		_:
			return 1


## Проверка значения d6 на попадание в диапазон: "6" | "1-3" | "4-6".
static func _in_range(value: int, spec: String) -> bool:
	if spec.is_empty():
		return false
	if spec.contains("-"):
		var parts: PackedStringArray = spec.split("-")
		if parts.size() == 2:
			return value >= int(parts[0]) and value <= int(parts[1])
		return false
	return value == int(spec)


## Предикат when. Виды, требующие данных поля, читают ctx; при отсутствии данных
## (нет контекста) считаем истиной — эффект применяется (старое поведение).
static func _predicate(pred: Dictionary, player: Dictionary, ctx: Dictionary) -> bool:
	var kind: String = String(pred.get("kind", "always"))
	var negate: bool = bool(pred.get("not", false))
	var result: bool
	match kind:
		"always":
			result = true
		"hasCondition":
			result = (player.get("conditions", []) as Array).has(String(pred.get("condition", "")))
		"hasAsset":
			result = _has_asset(player, String(pred.get("trait", "")))
		"healthAtMost":
			result = int(player.get("hp", 0)) <= int(pred.get("n", 0))
		"sanityAtMost":
			result = int(player.get("sanity", 0)) <= int(pred.get("n", 0))
		"isLead":
			result = bool(ctx.get("is_lead", true))
		"onLocationType":
			result = (
				not ctx.has("loc_type")
				or String(ctx.get("loc_type", "")) == String(pred.get("type", ""))
			)
		"monsterToughnessAtMost":
			result = (
				not ctx.has("monster_toughness")
				or int(ctx.get("monster_toughness", 0)) <= int(pred.get("n", 0))
			)
		"noGatesMatchingOmen":
			result = int(ctx.get("gates_matching_omen", 0)) == 0
		"noMonstersOnBoard":
			result = int(ctx.get("monsters_on_board", 0)) == 0
		"noRumorsInPlay":
			result = int(ctx.get("rumors_in_play", 0)) == 0
		_:
			result = true
	return result != negate


## Есть ли у игрока актив (опц. с трейтом). Трейт пуст → любой актив. Если активы
## хранятся как id без трейтов — точную проверку трейта подтвердить нельзя, считаем
## выполненной при наличии активов (мягко, как прочие предикаты без данных).
static func _has_asset(player: Dictionary, trait_name: String) -> bool:
	var items: Array = player.get("items", [])
	if items.is_empty():
		return false
	if trait_name.is_empty():
		return true
	for it_v in items:
		if it_v is Dictionary:
			var traits: Array = (it_v as Dictionary).get("traits", [])
			if traits.has(trait_name):
				return true
	return true
