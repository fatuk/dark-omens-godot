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
	"gainImprovement",
	"loseArtifact",
	"loseAsset",
	"loseSpell",
	"loseImprovement",
	"loseAllPossessions",
	"gainFocus",
	"loseFocus",
	"gainResource",
	"loseResource",
	"improveSkill",
	"impairSkill",
	"becomeDelayed",
	"extraAction",
	"gainTicket",
	"loseTicket",
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
	"cannotGainClues",
	"undiscardable",
	"cannotMove",
	"cannotAct",
	"cannotRecover",
	"removeFromBoard",
	"immuneToEffects",
]

# Навыки Dark Omens — для improveSkill/impairSkill со skill:"all" (Markings of Isis).
const _ALL_SKILLS := ["influence", "lore", "observation", "strength", "will"]

# Verb'ы, у которых skill:"choice" разворачивается в choice из пяти веток.
const _SKILL_CHOICE_VERBS := ["improveSkill", "impairSkill"]

# Предел модификатора навыка: skill_mods[skill] ∈ [−SKILL_MOD_CAP, +SKILL_MOD_CAP] —
# улучшить максимум на +2, ухудшить на −2 (касты/встречи/состояния не стекаются
# бесконечно). Эффективный навык (base + mods) дополнительно флорится в 1 при подсчёте
# пула (CheckFlow.pool / _roll_test / _lore_roll — maxi(1, …)).
const SKILL_MOD_CAP := 2

# Глубина вложенности в ветку, которую выбрал игрок (choice с записанным решением).
# >0 — эффекты «по своему выбору»: иммунитет «если только не выбрали сами» (Pocket
# Watch, пассив Солдата) их не гасит. Прогон синхронный и однопоточный — статика безопасна.
static var _chosen_depth: int = 0

## Откуда тянуть «случайный актив из колоды» (gainAsset без from): () -> Array id.
## GameState ставит ShopReserve.free_ids — колода без разобранного (витрина, руки
## всех игроков): каждый актив на поле уникален. Не задан (тесты, офлайн-хелперы) —
## весь доступный каталог. Свои карты получателя исключаются в любом случае.
static var asset_pool: Callable = Callable()


## ctx (опц.) — контекст исполнения: { skills, loc_type, is_lead, gates_matching_omen,
## gates_on_board, monsters_on_board, clues_on_board, rumors_in_play, monster_toughness,
## monster_choices (chosenMonster), space_choices (chosenSpace), other_pids (chosen*),
## locations (граф локаций — куда шагать по move) }.
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
		# repeat у group → повторить весь блок N раз (под-путь с индексом повтора).
		if node.has("repeat"):
			for r in range(_repeat(node, player, ctx)):
				for i in range(children.size()):
					if _stopped(flow):
						return
					_run_node(
						children[i], player, logs, board, ctx, flow, "%s/r%d_g%d" % [path, r, i]
					)
		else:
			for i in range(children.size()):
				if _stopped(flow):
					return
				_run_node(children[i], player, logs, board, ctx, flow, path + "/g" + str(i))
		return
	# «улучшите 1 навык на свой выбор» — самая частая формулировка встреч. Разворачиваем
	# в обычный choice из пяти веток: так выбор проходит по уже существующему тракту
	# пауз/решений (pending → игрок выбрал → переигровка), а не заводит второй.
	if (
		String(node.get("skill", "")) == "choice"
		and _SKILL_CHOICE_VERBS.has(String(node.get("do", "")))
	):
		_run_choice(_skill_choice_node(node), player, logs, board, ctx, flow, path)
		return
	# optional («можете …») в интерактивном прогоне — выбор «сделать / пропустить»
	# тем же трактом пауз, что choice: ветка с cost показывает цену и отсекается,
	# если платить нечем. Без interactive (фон, Расплата) — как раньше, применяем.
	if (
		bool(node.get("optional", false))
		and not node.has("choice")
		and bool(flow.get("interactive", false))
	):
		_run_choice(_optional_choice_node(node), player, logs, board, ctx, flow, path)
		return
	if node.has("choice"):
		# repeat у choice → N независимых выборов подряд (под-путь с индексом повтора);
		# каждый — своя пауза/решение. Без repeat — один выбор (прежний путь).
		if node.has("repeat"):
			for r in range(_repeat(node, player, ctx)):
				if _stopped(flow):
					return
				_run_choice(node, player, logs, board, ctx, flow, path + "/r" + str(r))
		else:
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
	if node.has("resultTiers"):
		# Ветвление по ЧИСЛУ УСПЕХОВ каст-теста (ctx.successes), не по грани d6.
		# Рубашка заклинания: «Resolve based on test result: 0 / 1-2 / 3+».
		var successes: int = int(ctx.get("successes", 0))
		var tiers: Array = node["resultTiers"]
		for i in range(tiers.size()):
			var tier: Dictionary = tiers[i]
			if _tier_match(successes, String(tier.get("on", ""))):
				var eff: Array = tier.get("effect", tier.get("then", []))
				for j in range(eff.size()):
					if _stopped(flow):
						return
					_run_node(eff[j], player, logs, board, ctx, flow, path + "/t%d_%d" % [i, j])
				break
		return
	if node.has("test"):
		# checks_visible (драйвер включил): ВИДИМАЯ проверка через CheckFlow (как choice
		# пендит решение) — нет результата → pend {kind:"check"}, есть decisions[path]=
		# passed → ветка. Иначе: прежний тихий seeded бросок (детерминизм тестов / фон,
		# + драйверы, ещё не переведённые на видимые проверки).
		var passed: bool
		if bool(flow.get("checks_visible", false)):
			var decisions: Dictionary = flow.get("decisions", {})
			if not decisions.has(path):
				flow["pending"] = {
					"kind": "check",
					"path": path,
					"skill": String(node.get("test", "will")),
					"modifier": int(node.get("modifier", 0)),
				}
				return
			passed = bool(decisions[path])
		else:
			passed = _roll_test(node, player, ctx, flow, path)
		var branch: Array = node.get("onPass" if passed else "onFail", [])
		var pfx: String = "/p" if passed else "/f"
		for i in range(branch.size()):
			if _stopped(flow):
				return
			_run_node(branch[i], player, logs, board, ctx, flow, path + pfx + str(i))
		return
	if node.has("do"):
		_run_action(node, player, logs, board, ctx, flow, path)


## Публично: предикат when против игрока и контекста (TargetResolver — per-target).
static func eval_predicate(pred: Dictionary, player: Dictionary, ctx: Dictionary = {}) -> bool:
	return _predicate(pred, player, ctx)


# Игровой verb, адресованный другим сыщикам (не self/активному): его when
# откладывается до разрешения целей.
static func _targets_others(node: Dictionary) -> bool:
	var target: String = String(node.get("target", ""))
	return (
		_PLAYER_VERBS.has(String(node.get("do", "")))
		and not (target.is_empty() or target == "self")
	)


## Публично: применить ОДИН игровой verb к словарю игрока. Для GameState — когда
## эффект адресован другому сыщику (target lead/each/chosenInvestigator) и
## применяется на уровне поля. Возвращает строки-логи. board — куда сложить
## board-узлы verb'а (grantOnGain у выданной услуги); их применяет вызывающий.
static func apply_player_verb(
	verb: String, node: Dictionary, player: Dictionary, board: Array = []
) -> Array:
	var logs: Array = []
	_apply_player_verb(verb, node, player, logs, board)
	return logs


## Игровой ли это verb (меняет состояние сыщика). Для маршрутизации целей в GameState.
static func is_player_verb(verb: String) -> bool:
	return _PLAYER_VERBS.has(verb)


## Есть ли у игрока принадлежащий whileOwned-пассив с do==verb и field==value. Основа
## для иммунитета (immuneTo status:X — Pocket Watch) и защиты ресурса (protectResource
## resource:clue — Scribe's Journal).
static func _owns_whileowned(
	player: Dictionary, verb: String, field: String, value: String
) -> bool:
	for it_v: Variant in player.get("items", []):
		for n_v: Variant in _whileowned_of(it_v):
			var n: Dictionary = n_v
			if (
				String(n.get("do", "")) == verb
				and (field.is_empty() or String(n.get(field, "")) == value)
			):
				return true
	return false


# whileOwned-узлы предмета: актив или артефакт (у артефактов те же слоты эффектов).
static func _whileowned_of(entry: Variant) -> Array:
	var aid: String = AssetCatalog.entry_id(entry)
	var card: Dictionary = AssetCatalog.by_id(aid)
	if card.is_empty():
		card = ArtifactCatalog.by_id(aid)
	return (card.get("effect", {}) as Dictionary).get("whileOwned", [])


# Предмет нельзя сбросить (whileOwned undiscardable — Сноп): loseAsset/loseArtifact/
# loseAllPossessions его не трогают.
static func _item_undiscardable(entry: Variant) -> bool:
	for n_v: Variant in _whileowned_of(entry):
		if String((n_v as Dictionary).get("do", "")) == "undiscardable":
			return true
	return false


# Иммунитет к статусу ("delayed" / id состояния): предмет (Pocket Watch) или пассив
# сыщика (Фрэнк Далтон). Обе карты — «если только не выбрали сами»: внутри ветки,
# которую выбрал игрок, иммунитет молчит, иначе «станьте Задержанным, чтобы получить
# Артефакт» давал бы артефакт даром.
static func _owns_immunity(player: Dictionary, status: String) -> bool:
	if _chosen_depth > 0:
		return false
	return (
		_owns_whileowned(player, "immuneTo", "status", status)
		or (Investigators.passive_immune_to(String(player.get("investigator", "")), status))
	)


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
		_charge_cost(branches[idx], player, logs, board)
		_chosen_depth += 1  # ветку выбрал игрок — «если только не выбрали сами»
		_run_node(branches[idx], player, logs, board, ctx, flow, path + "/c" + str(idx))
		_chosen_depth -= 1
		return
	# Ветка с cost (spend/amount) доступна только если игрок может заплатить — гейт
	# «сделай X, иначе штраф» (closes «unless he spends 1 Clue» лазейку).
	var affordable: Array = []
	for k in range(branches.size()):
		if _can_afford(branches[k], player):
			affordable.append(k)
	# Платить нечем ни за одну ветку, а бесплатной нет («потратьте жетон навыка: …»
	# без жетонов) — ничего не происходит: ветку без оплаты не применяем.
	if (affordable as Array).is_empty():
		logs.append("платить нечем — выбор пропущен")
		return
	# Cost отсёк ветки до ≤1 доступной → выбора нет: применяем единственную (штраф).
	# Если cost ничего не отсёк — пауза как раньше (даже на одной ветке).
	if (affordable as Array).size() < branches.size() and (affordable as Array).size() <= 1:
		var bk: int = int(affordable[0]) if not (affordable as Array).is_empty() else 0
		_charge_cost(branches[bk], player, logs, board)
		_run_node(branches[bk], player, logs, board, ctx, flow, path + "/c" + str(bk))
		return
	# Несколько доступных → пауза; опции несут флаг доступности (_affordable) для модалки.
	var opts: Array = []
	for k in range(branches.size()):
		var o: Dictionary = (branches[k] as Dictionary).duplicate(true)
		o["_affordable"] = (affordable as Array).has(k)
		opts.append(o)
	flow["pending"] = {"path": path, "options": opts, "by": String(node.get("by", "active"))}


# Доступна ли ветка choice по стоимости. spend → хватает ресурса; discardCondition →
# есть состояние категории. Без cost — да.
static func _can_afford(branch: Variant, player: Dictionary) -> bool:
	if not (branch is Dictionary):
		return true
	var cost: Dictionary = (branch as Dictionary).get("cost", {})
	var spend: String = String(cost.get("spend", ""))
	if not spend.is_empty():
		return _resource_of(player, spend) >= int(cost.get("amount", 1))
	var dk: String = String(cost.get("discardCondition", ""))
	if not dk.is_empty():
		return not _condition_of_kind(player, dk).is_empty()
	# skillToken — жетон улучшения/ухудшения навыка («Маска Стенела»): есть ли он.
	var sk: String = String(cost.get("skillToken", ""))
	if not sk.is_empty():
		return int((player.get("skill_mods", {}) as Dictionary).get(sk, 0)) != 0
	return true


## Есть ли в программе действия хоть что-то, за что можно заплатить: верхний choice
## без доступных веток (и без бесплатной) — карту играть незачем (AssetActionFlow).
static func program_affordable(program: Array, player: Dictionary) -> bool:
	for n_v: Variant in program:
		if not (n_v is Dictionary):
			continue
		var n: Dictionary = n_v
		if n.has("choice"):
			var any: bool = false
			for b_v: Variant in n.get("choice", []):
				if _can_afford(b_v, player):
					any = true
					break
			if not any:
				return false
		elif n.has("cost") and not _can_afford(n, player):
			return false
	return true


# Списать стоимость выбранной ветки: spend-ресурс ЛИБО сброс состояния категории.
static func _charge_cost(branch: Variant, player: Dictionary, logs: Array, board: Array) -> void:
	if not (branch is Dictionary):
		return
	var cost: Dictionary = (branch as Dictionary).get("cost", {})
	# discardSelf — сброс карты-носителя: сам runner носителя не знает, отдаём
	# board-узлом discardCard — его читает прогон актива (consumed) / состояния.
	if bool(cost.get("discardSelf", false)):
		board.append({"do": "discardCard"})
		logs.append("карта сброшена как цена")
	var spend: String = String(cost.get("spend", ""))
	if not spend.is_empty():
		var amt: int = int(cost.get("amount", 1))
		_spend_resource(player, spend, amt)
		logs.append("потрачено %s ×%d" % [spend, amt])
		return
	# Потратить жетон навыка — снять его целиком (улучшение или ухудшение).
	var sk: String = String(cost.get("skillToken", ""))
	if not sk.is_empty():
		var mods: Dictionary = player.get("skill_mods", {})
		mods.erase(sk)
		player["skill_mods"] = mods
		logs.append("потрачен жетон навыка %s" % sk)
		return
	var dk: String = String(cost.get("discardCondition", ""))
	if dk.is_empty():
		return
	var cid: String = _condition_of_kind(player, dk)
	if cid.is_empty():
		return
	var conds: Array = player.get("conditions", [])
	conds.erase(cid)
	player["conditions"] = conds
	(player.get("conditions_flipped", {}) as Dictionary).erase(cid)
	logs.append("сброшено состояние «%s» (%s)" % [cid, dk])


# id первого held-состояния игрока категории kind ("" — нет такого).
static func _condition_of_kind(player: Dictionary, kind: String) -> String:
	for cid_v: Variant in player.get("conditions", []) as Array:
		if Conditions.kind_of(String(cid_v)) == kind:
			return String(cid_v)
	return ""


# Куда может уйти сыщик по узлу move: [{ref:<id локации>, name:<ключ перевода>}].
static func _move_options(player: Dictionary, ctx: Dictionary, node: Dictionary) -> Array:
	var locations: Array = ctx.get("locations", [])
	var origin: String = String(player.get("location", ""))
	var ids: Array = TravelPlanner.within_hops(locations, origin, _amount_or(node, 0))
	var name_of: Dictionary = {}
	for l_v: Variant in locations:
		var l: Dictionary = l_v
		name_of[String(l.get("id", ""))] = String(l.get("name", l.get("id", "")))
	var out: Array = []
	for id_v: Variant in ids:
		var id: String = String(id_v)
		out.append({"ref": id, "name": String(name_of.get(id, id))})
	return out


# Варианты монстра для chosenMonster с фильтрами узла: maxToughness (число — «стойкость
# N или меньше»; "testResult" здесь не фильтрует) и excludeEpic («кроме эпических»).
static func _monster_options(node: Dictionary, ctx: Dictionary) -> Array:
	var raw: Variant = node.get("maxToughness", null)
	var max_t: int = int(raw) if raw != null and str(raw).is_valid_int() else 999
	var no_epic: bool = bool(node.get("excludeEpic", false))
	var out: Array = []
	for o_v: Variant in ctx.get("monster_choices", []) as Array:
		var o: Dictionary = o_v
		if int(o.get("toughness", 0)) > max_t:
			continue
		if no_epic and bool(o.get("epic", false)):
			continue
		out.append(o)
	return out


# Все клетки карты как варианты назначения (moveMonster where:"chosen").
static func _all_location_options(ctx: Dictionary) -> Array:
	var out: Array = []
	for l_v: Variant in ctx.get("locations", []) as Array:
		var l: Dictionary = l_v
		out.append({"ref": String(l.get("id", "")), "name": String(l.get("name", l.get("id", "")))})
	return out


# amount/count узла без подстановки дефолта 1 (для move: «без amount» ≠ «1 шаг»).
static func _amount_or(node: Dictionary, fallback: int) -> int:
	return int(node.get("amount", node.get("count", fallback)))


# Стойкость выбранного монстра по его ref в ctx.monster_choices ([{ref,name,toughness}]).
static func _monster_choice_toughness(ctx: Dictionary, ref: String) -> int:
	for o_v: Variant in ctx.get("monster_choices", []) as Array:
		var o: Dictionary = o_v
		if String(o.get("ref", "")) == ref:
			return int(o.get("toughness", 0))
	return 0


static func _resource_of(player: Dictionary, res: String) -> int:
	return ResourceLedger.amount_of(player, res)


static func _spend_resource(player: Dictionary, res: String, amt: int) -> void:
	ResourceLedger.spend(player, res, amt)


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
	# Порог Blessed/Cursed действует и в тихих test'ах (как в видимом CheckFlow).
	var threshold: int = Conditions.success_threshold(
		player.get("conditions", []), player.get("conditions_flipped", {})
	)
	return bool(Dice.result(_roll_dice(flow, path, pool), threshold).get("passed", false))


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
	var verb: String = String(node["do"])
	# when адресного игрового verb'а (target: each/eachOnSpace/…) решается ПО КАЖДОЙ
	# цели в TargetResolver (eval_predicate), а не по «своему» игроку прогона.
	if node.has("when") and not _targets_others(node) and not _predicate(node["when"], player, ctx):
		return
	# Мета-verb: добавить успехи к результату каста (ctx.successes). Влияет на узлы
	# ПОСЛЕ него — resultTiers (ветвление по успехам) и board-verb'ы «по стойкости»
	# (_successes). Не player/board verb: мутирует общий ctx и выходит. (Banishment:
	# «discard monster с стойкостью ≤ успехи+1».)
	if verb == "addSuccesses":
		ctx["successes"] = maxi(0, int(ctx.get("successes", 0)) + _amount(node))
		return
	var target: String = String(node.get("target", ""))
	var interactive: bool = bool(flow.get("interactive", false))
	# loseCondition {choose:true}: интерактивно снять ОДНО из состояний сыщика —
	# разворачиваем в choice из веток loseCondition{condition:X} по его состояниям.
	# Дальше работает штатная choice-машинерия (пауза/решение/описатель веток).
	if verb == "loseCondition" and bool(node.get("choose", false)) and interactive:
		var held: Array = player.get("conditions", [])
		if (held as Array).is_empty():
			return  # нечего снимать — эффект пропадает
		if (held as Array).size() == 1:
			_apply_player_verb("loseCondition", {"condition": String(held[0])}, player, logs)
			return
		var copts: Array = []
		for c_v: Variant in held:
			copts.append({"do": "loseCondition", "condition": String(c_v)})
		_run_choice({"choice": copts}, player, logs, board, ctx, flow, path)
		return
	# move: сыщик сам выбирает, КУДА. Варианты считаем по графу локаций из ctx —
	# amount задаёт число шагов (Чартерный рейс: 2), без amount — куда угодно
	# (Частный рейс). Нет графа в ctx (мифы/встречи) — глагол остаётся заглушкой.
	if verb == "move" and interactive and ctx.has("locations"):
		var vdec: Dictionary = flow.get("decisions", {})
		if not vdec.has(path):
			var dests: Array = _move_options(player, ctx, node)
			if dests.is_empty():
				return  # идти некуда — эффект пропадает
			flow["pending"] = {"kind": "destination", "path": path, "options": dests, "verb": verb}
			return
		player["location"] = String(vdec[path])
		logs.append("перемещение")
		return
	# gainAsset from:"reserve" — «возьмите карту с витрины»: сыщик выбирает из
	# текущей витрины (ctx.reserve) карты нужного трейта, карта уходит с витрины
	# (board-узел takeFromReserve → ShopReserve.take). Подходящих на витрине нет / нет
	# ctx — деградация к случайной выдаче из колоды.
	if (
		verb == "gainAsset"
		and String(node.get("from", "")) == "reserve"
		and interactive
		and not (
			AssetCatalog
			. with_trait(ctx.get("reserve", []), String(node.get("trait", "")))
			. is_empty()
		)
	):
		var rdec: Dictionary = flow.get("decisions", {})
		if not rdec.has(path):
			var ropts: Array = []
			for aid_v: Variant in AssetCatalog.with_trait(
				ctx.get("reserve", []), String(node.get("trait", ""))
			):
				var a: Dictionary = AssetCatalog.by_id(String(aid_v))
				ropts.append(
					{"ref": String(aid_v), "name": String(a.get("nameKey", String(aid_v)))}
				)
			flow["pending"] = {"kind": "asset", "path": path, "options": ropts, "verb": verb}
			return
		var taken: String = String(rdec[path])
		var ritems: Array = player.get("items", [])
		ritems.append({"id": taken, "exhausted": false})
		player["items"] = ritems
		board.append({"do": "takeFromReserve", "id": taken})
		_note_on_gain(taken, player, board)
		logs.append("взят с витрины актив «%s»" % taken)
		return
	# (1) Игровой verb к ПЕРЕДАННОМУ игроку: самонаправленный, либо легаси-режим
	#     (мифос/хуки сами разворачивают target по игрокам и зовут run без flow —
	#     тогда применяем к тому игроку, что передали).
	if _PLAYER_VERBS.has(verb) and (target.is_empty() or target == "self" or not interactive):
		# Повторное получение состояния с onDuplicate:"flip" (Благословение, Проклятие):
		# карта не дублируется, а переворачивается — board-узел, флип делает ConditionFlow.
		if verb == "gainCondition" and _duplicate_flips(node, player):
			var dup_cid: String = String(node.get("condition", ""))
			board.append(
				{
					"do": "flipCondition",
					"condition": dup_cid,
					"_pid": String(player.get("user_id", ""))
				}
			)
			logs.append("«%s» уже есть — карта переворачивается" % dup_cid)
			return
		var times: int = _repeat(node, player, ctx)
		for _i in times:
			_apply_player_verb(verb, node, player, logs, board)
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
	# (2b) Интерактивный выбор МОНСТРА (discardMonster target:chosenMonster). Нет решения
	#      → пауза (kind:monster); есть → ставим ctx.chosenMonsterToughness из выбранной
	#      опции (для последующего repeat) и кладём board-узел с _target_monster (ref).
	if interactive and target == "chosenMonster":
		var mdec: Dictionary = flow.get("decisions", {})
		if not mdec.has(path):
			var mopts: Array = _monster_options(node, ctx)
			if mopts.is_empty():
				return  # подходящих монстров нет — эффект пропадает
			flow["pending"] = {"kind": "monster", "path": path, "options": mopts, "verb": verb}
			return
		var ref: String = String(mdec[path])
		ctx["chosenMonsterToughness"] = _monster_choice_toughness(ctx, ref)
		var mnode: Dictionary = node.duplicate(true)
		mnode["_target_monster"] = ref
		# moveMonster where:"chosen" — второе решение: куда переставить (любая клетка карты).
		if verb == "moveMonster" and String(node.get("where", "")) == "chosen":
			var dpath: String = path + "/dest"
			if not mdec.has(dpath):
				var dests: Array = _all_location_options(ctx)
				if dests.is_empty():
					return
				flow["pending"] = {
					"kind": "destination", "path": dpath, "options": dests, "verb": verb
				}
				return
			mnode["_target_space"] = String(mdec[dpath])
		board.append(mnode)  # GameState снимет/переставит именно этого монстра
		return
	# (2c) Интерактивный выбор ЛОКАЦИИ по монстрам (damageMonster target:chosenSpace —
	#      «выберите локацию, каждый монстр там теряет N»: Agency Quarantine, Police
	#      Raid). Варианты — только локации С монстрами (ctx.space_choices).
	if interactive and target == "chosenSpace":
		var sdec: Dictionary = flow.get("decisions", {})
		if not sdec.has(path):
			var sopts: Array = ctx.get("space_choices", [])
			if (sopts as Array).is_empty():
				return  # монстров нигде нет — эффект пропадает
			flow["pending"] = {
				"kind": "space", "path": path, "options": sopts.duplicate(), "verb": verb
			}
			return
		var snode: Dictionary = node.duplicate(true)
		snode["_target_space"] = String(sdec[path])
		board.append(snode)
		return
	# (3) board-verb ИЛИ игровой verb с детерминированной целью (lead/each/eachOn*)
	#     → на доску с разрешённым повтором; цель разрешит GameState.
	var bnode: Dictionary = node.duplicate(true)
	bnode["_times"] = _repeat(node, player, ctx)
	# Результат каст-теста — для board-verb'ов «по стойкости» (discardMonster/
	# defeatMonster с maxToughness:"testResult"; Poison Mist / Banishment / Binding).
	bnode["_successes"] = int(ctx.get("successes", 0))
	board.append(bnode)


# ── Действия по игроку ────────────────────────────────────────────────────────


static func _apply_player_verb(
	verb: String, node: Dictionary, player: Dictionary, logs: Array, board: Array = []
) -> void:
	var n: int = _amount(node)
	match verb:
		"loseHealth":
			player["hp"] = maxi(0, int(player.get("hp", 0)) - n)
			logs.append("−%d здоровья" % n)
		"healHealth":
			# all:true — до максимума («полное лечение» в больнице), явно, а не amount 99.
			var hp_max: int = int(player.get("hp_max", 0))
			var hp_to: int = (
				hp_max
				if bool(node.get("all", false))
				else mini(hp_max, int(player.get("hp", 0)) + n)
			)
			logs.append("+%d здоровья" % maxi(0, hp_to - int(player.get("hp", 0))))
			player["hp"] = hp_to
		"loseSanity":
			player["sanity"] = maxi(0, int(player.get("sanity", 0)) - n)
			logs.append("−%d рассудка" % n)
		"healSanity":
			var san_max: int = int(player.get("sanity_max", 0))
			var san_to: int = (
				san_max
				if bool(node.get("all", false))
				else mini(san_max, int(player.get("sanity", 0)) + n)
			)
			logs.append("+%d рассудка" % maxi(0, san_to - int(player.get("sanity", 0))))
			player["sanity"] = san_to
		"gainClue":
			# cannotGainClues (whileOwned, Сноп) — улики не получить, пока предмет на руках.
			if _owns_whileowned(player, "cannotGainClues", "", ""):
				logs.append("улики не получить (предмет запрещает)")
			else:
				player["clues"] = int(player.get("clues", 0)) + n
				logs.append("+%d улик" % n)
		"loseClue":
			# protectResource clue (Scribe's Journal) — улики нельзя ОТНЯТЬ (невольная
			# потеря от эффектов); добровольная трата (spendClue) не защищается.
			if _owns_whileowned(player, "protectResource", "resource", "clue"):
				logs.append("улики защищены")
			else:
				player["clues"] = maxi(0, int(player.get("clues", 0)) - n)
				logs.append("−%d улик" % n)
		"spendClue":
			player["clues"] = maxi(0, int(player.get("clues", 0)) - n)
			logs.append("−%d улик" % n)
		"gainCondition":
			# condition — конкретная карта; kind — ВИД («получите состояние Безумие»):
			# берём случайное того вида, которого ещё нет на руках.
			var cid: String = String(node.get("condition", ""))
			if cid.is_empty():
				cid = _pick_condition(node, player)
			if not cid.is_empty() and _owns_immunity(player, cid):
				logs.append("иммунитет к состоянию «%s»" % cid)  # Солдат: Detained
			elif not cid.is_empty():
				var conds: Array = player.get("conditions", [])
				if not conds.has(cid):
					conds.append(cid)
				player["conditions"] = conds
				logs.append("состояние «%s»" % cid)
		"loseCondition":
			# Без condition снимаем held-состояние подходящего вида (kind: "madness"
			# или ["illness","injury"]). Без kind — первое имеющееся: карточки с
			# choose:true раньше стирали пустой id и не делали НИЧЕГО.
			var rid: String = String(node.get("condition", ""))
			var rconds: Array = player.get("conditions", [])
			if rid.is_empty():
				rid = _held_of_kinds(player, _kinds_of(node))
			if rid.is_empty():
				logs.append("нечего снимать")
			else:
				rconds.erase(rid)
				player["conditions"] = rconds
				(player.get("conditions_flipped", {}) as Dictionary).erase(rid)
				logs.append("снято состояние «%s»" % rid)
		"gainAsset":
			# Выдаём РЕАЛЬНУЮ карту из пула поддержанных активов. Раньше в items уезжал
			# литерал "gainAsset", а веер (AssetCatalog.deck_for_items) отбрасывает
			# неизвестные id — сыщик не получал ничего видимого.
			# trait сужает выдачу («получите случайное ОРУЖИЕ из колоды»). Трейта нет
			# ни у одного доступного актива → выдаём из общего пула, а не ничего:
			# пустая награда за успех хуже слегка неточной.
			var base: Array = (
				asset_pool.call() if asset_pool.is_valid() else AssetCatalog.available_ids()
			)
			var own: Dictionary = {}
			for it_v: Variant in player.get("items", []):
				own[AssetCatalog.entry_id(it_v)] = true
			base = base.filter(func(id: Variant) -> bool: return not own.has(String(id)))
			var pool: Array = _assets_with_trait(base, String(node.get("trait", "")))
			var items: Array = player.get("items", [])
			if pool.is_empty():
				logs.append("активов в пуле не осталось")
			else:
				var aid: String = String(pool[randi() % pool.size()])
				items.append({"id": aid, "exhausted": false})
				player["items"] = items
				logs.append("получен актив «%s»" % aid)
				_note_on_gain(aid, player, board)
		"gainImprovement":
			# MVP: маркер предмета — каталога улучшений пока нет. У артефактов он
			# появился, и gainArtifact ушёл в board-ветку GameState: выдача обязана
			# видеть ВЕСЬ стол, иначе уникальную карту получат двое.
			var mitems: Array = player.get("items", [])
			mitems.append(verb)
			player["items"] = mitems
			logs.append("получен предмет (%s)" % verb)
		"loseArtifact":
			_drop_items(verb, node, player, logs)
		"loseAsset", "loseSpell", "loseImprovement":
			_drop_items(verb, node, player, logs)
		"loseAllPossessions":
			# Сбросить весь инвентарь карт (активы/заклинания/артефакты). Состояния,
			# улики, билеты — НЕ имущество (хранятся отдельными полями), их не трогаем.
			var kept: Array = []
			for it_v: Variant in player.get("items", []):
				if _item_undiscardable(it_v):
					kept.append(it_v)  # Сноп и подобное остаются
			player["items"] = kept
			logs.append("утрачено всё имущество")
		"gainFocus":
			# Потолок концентрации (GameState.MAX_CONCENTRATION) — как и action «взять».
			player["concentration"] = mini(
				GameState.MAX_CONCENTRATION, int(player.get("concentration", 0)) + n
			)
			logs.append("+%d сосредоточения" % n)
		"loseFocus":
			player["concentration"] = maxi(0, int(player.get("concentration", 0)) - n)
			logs.append("−%d сосредоточения" % n)
		"gainResource":
			# Потолок ресурсов (GameState.MAX_RESOURCES) — как и action «получить».
			player["resources"] = mini(GameState.MAX_RESOURCES, int(player.get("resources", 0)) + n)
			logs.append("+%d ресурса" % n)
		"loseResource":
			player["resources"] = maxi(0, int(player.get("resources", 0)) - n)
			logs.append("−%d ресурса" % n)
		"extraAction":
			# Доп. действие(я) в этот ход (актив/событие/заклинание «выполни ещё
			# действие»). Слой хода читает actions_left; пока > 0 — игрок действует.
			player["actions_left"] = int(player.get("actions_left", 0)) + n
			logs.append("+%d действие" % n)
		"improveSkill", "impairSkill":
			var skill: String = String(node.get("skill", ""))
			var delta: int = n if verb == "improveSkill" else -n
			if skill == "all":
				var amods: Dictionary = player.get("skill_mods", {})
				for sk_v: Variant in _ALL_SKILLS:
					amods[String(sk_v)] = clampi(
						int(amods.get(String(sk_v), 0)) + delta, -SKILL_MOD_CAP, SKILL_MOD_CAP
					)
				player["skill_mods"] = amods
				logs.append("все навыки %+d" % delta)
			elif not skill.is_empty():
				# Пассив-триггер сыщика (Мэй Линь): улучшение навыка применяется ещё
				# раз. Только на improveSkill — ухудшение НЕ удваиваем. Потолок
				# SKILL_MOD_CAP всё равно клампит итог.
				var repeats: int = 1
				if verb == "improveSkill":
					repeats += Investigators.extra_skill_improvements(
						String(player.get("investigator", ""))
					)
				var mods: Dictionary = player.get("skill_mods", {})
				mods[skill] = clampi(
					int(mods.get(skill, 0)) + delta * repeats, -SKILL_MOD_CAP, SKILL_MOD_CAP
				)
				player["skill_mods"] = mods
				logs.append("навык %s %+d" % [skill, delta * repeats])
		"becomeDelayed":
			if _owns_immunity(player, "delayed"):
				logs.append("иммунитет к задержке")  # Pocket Watch: immuneTo delayed
			else:
				var dconds: Array = player.get("conditions", [])
				if not dconds.has("delayed"):
					dconds.append("delayed")
				player["conditions"] = dconds
				logs.append("задержка")
		"gainTicket", "loseTicket":
			# Билеты лежат отдельными полями (train_tickets/ship_tickets), а потолок
			# MAX_TICKETS — ОБЩИЙ на оба вида, поэтому клампим по сумме.
			var tf: String = (
				"ship_tickets" if String(node.get("kind", "")) == "ship" else "train_tickets"
			)
			var have: int = int(player.get(tf, 0))
			if verb == "gainTicket":
				var other: int = int(
					player.get("train_tickets" if tf == "ship_tickets" else "ship_tickets", 0)
				)
				var room: int = maxi(0, GameState.MAX_TICKETS - have - other)
				player[tf] = have + mini(n, room)
			else:
				player[tf] = maxi(0, have - n)
			logs.append("%s%d %s" % ["+" if verb == "gainTicket" else "−", n, tf])
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


## Узел optional:true → choice из двух веток: сам узел (без флага) и «пропустить»
## (verb text с меткой DECISION_SKIP — ничего не делает, модалка покажет подпись).
static func _optional_choice_node(node: Dictionary) -> Dictionary:
	var take: Dictionary = node.duplicate(true)
	take.erase("optional")
	return {"choice": [take, {"do": "text", "text": "DECISION_SKIP"}]}


## Узел skill:"choice" → choice из пяти копий узла, по одной на навык. Прочие поля
## (amount, cost, limit, context) переезжают в каждую ветку как есть.
static func _skill_choice_node(node: Dictionary) -> Dictionary:
	var branches: Array = []
	for sk_v: Variant in _ALL_SKILLS:
		var b: Dictionary = node.duplicate(true)
		b["skill"] = String(sk_v)
		branches.append(b)
	return {"choice": branches}


## Виды состояний из узла: kind — строка ("madness") либо массив (["illness",
## "injury"] под «сбросьте Болезнь ИЛИ Травму»). Нет kind → пустой список.
static func _kinds_of(node: Dictionary) -> Array:
	var raw: Variant = node.get("kind", "")
	if raw is Array:
		var out: Array = []
		for k_v: Variant in raw as Array:
			out.append(String(k_v))
		return out
	var one: String = String(raw)
	return [] if one.is_empty() else [one]


## Случайное состояние заданных видов, которого у сыщика ещё нет. Все уже на
## руках (или вид пуст) → "" и verb ничего не делает.
static func _pick_condition(node: Dictionary, player: Dictionary) -> String:
	var kinds: Array = _kinds_of(node)
	if kinds.is_empty():
		return ""
	var held: Array = player.get("conditions", [])
	var pool: Array = []
	for id_v: Variant in Conditions.ids_of_kinds(kinds):
		if not held.has(String(id_v)):
			pool.append(String(id_v))
	if pool.is_empty():
		return ""
	return String(pool[randi() % pool.size()])


# gainCondition конкретной карты, которая уже на руках, и у которой в определении
# onDuplicate:"flip" → вместо дубля переворот.
static func _duplicate_flips(node: Dictionary, player: Dictionary) -> bool:
	var cid: String = String(node.get("condition", ""))
	if cid.is_empty() or not (player.get("conditions", []) as Array).has(cid):
		return false
	return String(Conditions.get_def(cid).get("onDuplicate", "")) == "flip"


## Первое held-состояние подходящего вида ("" — нет такого). Пустой список видов →
## первое любое: карточка «снимите состояние по выбору» без вида.
static func _held_of_kinds(player: Dictionary, kinds: Array) -> String:
	for c_v: Variant in player.get("conditions", []):
		var cid: String = String(c_v)
		if kinds.is_empty() or kinds.has(Conditions.kind_of(cid)):
			return cid
	return ""


## Активы из пула, имеющие трейт. Трейт пуст — пул целиком. Ни одного совпадения —
## тоже пул целиком (см. комментарий у gainAsset).
# Карта с onGain (услуги: Чартерный рейс и пр. — «получив, сразу …, затем сбросьте»)
# не должна просто лечь в руку: board-узел grantOnGain отдаёт её GameState, тот
# прогоняет onGain общим путём выдачи (AssetActionFlow.grant), услуга сбрасывается.
static func _note_on_gain(aid: String, player: Dictionary, board: Array) -> void:
	var on_gain: Array = (AssetCatalog.by_id(aid).get("effect", {}) as Dictionary).get("onGain", [])
	if on_gain.is_empty():
		return
	board.append({"do": "grantOnGain", "id": aid, "_pid": String(player.get("user_id", ""))})


static func _assets_with_trait(pool: Array, want: String) -> Array:
	if want.is_empty():
		return pool
	var out: Array = []
	for id_v: Variant in pool:
		var a: Dictionary = AssetCatalog.by_id(String(id_v))
		if (a.get("traits", []) as Array).has(want):
			out.append(String(id_v))
	return out if not out.is_empty() else pool


## Подходит ли предмет инвентаря под verb сброса и трейт.
## loseSpell бьёт по заклинаниям ({id, kind:"spell"}), loseAsset — по активам,
## loseImprovement — по маркерам-строкам (каталога улучшений пока нет).
static func _item_matches(entry: Variant, verb: String, want_trait: String) -> bool:
	var is_spell: bool = (
		entry is Dictionary and String((entry as Dictionary).get("kind", "")) == "spell"
	)
	if verb == "loseSpell":
		return is_spell
	if verb == "loseImprovement":
		return entry is String
	if is_spell:
		return false
	var aid: String = AssetCatalog.entry_id(entry)
	# «Сбросьте 1 Артефакт» — это КЛАСС карты, а не трейт: артефакт и актив могут
	# делить трейт (обе бывают Книгой), поэтому различаем по каталогу-владельцу.
	var is_artifact: bool = ArtifactCatalog.has(aid)
	if (verb == "loseArtifact") != is_artifact:
		return false
	if want_trait.is_empty():
		return true
	var a: Dictionary = AssetCatalog.by_id(aid)
	return (a.get("traits", []) as Array).has(want_trait)


## Сброс предметов: trait сужает («сбросьте 1 Вещь»), count — сколько,
## keep — «оставьте N, остальное сбросьте». Снимаем С КОНЦА, как раньше делал
## pop_back: порядок детерминирован, а выбор игроком — отдельная механика (§15.2).
static func _drop_items(verb: String, node: Dictionary, player: Dictionary, logs: Array) -> void:
	var items: Array = player.get("items", [])
	var want_trait: String = String(node.get("trait", ""))
	var idx: Array = []
	for i in range(items.size()):
		if _item_matches(items[i], verb, want_trait) and not _item_undiscardable(items[i]):
			idx.append(i)
	if idx.is_empty():
		logs.append("нечего сбрасывать")
		return
	var drop: int = _amount(node)
	if node.has("keep"):
		drop = maxi(0, (idx as Array).size() - int(node["keep"]))
	drop = mini(drop, (idx as Array).size())
	for k in range(drop):
		items.remove_at(int(idx[(idx as Array).size() - 1 - k]))
	player["items"] = items
	logs.append("утрачено предметов: %d" % drop)


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
		"chosenMonsterToughness":
			# Стойкость монстра, выбранного ранее в этой же программе (chosenMonster).
			return int(ctx.get("chosenMonsterToughness", 0))
		"conditions", "conditionsOf":
			# conditionsOf — имя из словаря DSL, conditions — историческое имя движка.
			# Держим оба: карточка со счётчиком из словаря молча возвращала 1.
			var conds: Array = player.get("conditions", [])
			var cond: String = String(spec.get("condition", ""))
			if cond.is_empty():
				return conds.size()
			var c: int = 0
			for x in conds:
				if String(x) == cond:
					c += 1
			return c
		"conditionsOfKind":
			# repeat «по трейту» состояний: считаем conditions заданного вида (kind:
			# madness/injury/illness/bane/boon/…). Пустой kind → все состояния.
			var conds2: Array = player.get("conditions", [])
			var kind2: String = String(spec.get("kind", ""))
			if kind2.is_empty():
				return conds2.size()
			var cnt: int = 0
			for x2 in conds2:
				if Conditions.kind_of(String(x2)) == kind2:
					cnt += 1
			return cnt
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


## Совпадение тира успехов с диапазоном рубашки: "N" | "a-b" | "N+" (≥N).
## Для resultTiers (рубашки заклинаний по числу успехов каста).
static func _tier_match(value: int, spec: String) -> bool:
	if spec.is_empty():
		return false
	if spec.ends_with("+"):
		return value >= int(spec.substr(0, spec.length() - 1))
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
		"cluesAtMost":
			result = int(player.get("clues", 0)) <= int(pred.get("n", 0))
		"noInvestigatorsAt":
			# «На локации нет ни одного сыщика» (Расплата листа: поле нельзя бросать).
			# ctx.investigators_at {loc: n} кладёт ReckoningFlow; без него — живой стол.
			var loc: String = String(pred.get("location", ""))
			if ctx.has("investigators_at"):
				result = int((ctx["investigators_at"] as Dictionary).get(loc, 0)) == 0
			else:
				result = true
				for p_v: Variant in GameState.players.values():
					var pp: Dictionary = p_v
					if (
						String(pp.get("location", "")) == loc
						and bool(pp.get("connected", true))
						and not bool(pp.get("dead", false))
					):
						result = false
						break
		"noGatesOnBoard":
			var gs_gates: Dictionary = ctx.get("gates", GameState.gates)
			result = gs_gates.is_empty()
		"mysteryActive":
			# Активна Тайна номер n (1..3). ctx.active_mystery — индекс (0..2), без него — стол.
			var am: int = int(ctx.get("active_mystery", GameState.active_mystery))
			result = am == int(pred.get("n", 1)) - 1
		"gateAt", "noGateAt":
			# Открыты ли врата на локации {location}. ctx.gates — снимок поля, если
			# вызывающий его кладёт; без него — живой стол (Миф/Расплата исполняют узлы
			# по одному, так что следующий узел видит врата, открытые предыдущим).
			var gloc: String = String(pred.get("location", ""))
			var gates: Dictionary = ctx.get("gates", GameState.gates)
			result = gates.has(gloc) == (kind == "gateAt")
		"rolledAny":
			# В кубах каста (ctx.dice) есть заданная грань? Для рубашек заклинаний:
			# «if you rolled any 1's, discard». Нет ctx.dice → false.
			result = false
			var face: int = int(pred.get("face", 1))
			for d_v: Variant in ctx.get("dice", []):
				if int(d_v) == face:
					result = true
					break
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
