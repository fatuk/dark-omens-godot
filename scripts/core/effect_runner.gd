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
	"loseHealth", "healHealth", "loseSanity", "healSanity",
	"gainClue", "loseClue", "spendClue",
	"gainCondition", "loseCondition",
	"gainAsset", "gainSpell", "gainArtifact", "gainImprovement",
	"loseAsset", "loseSpell", "loseImprovement",
	"gainFocus", "loseFocus", "improveSkill", "impairSkill",
	"becomeDelayed", "move", "text",
]


static func run(effects: Array, player: Dictionary) -> Dictionary:
	var logs: Array   = []
	var board: Array = []
	for i in range(effects.size()):
		var node: Dictionary = effects[i]
		_run_node(node, player, logs, board)
	return { "logs": logs, "board": board }


# ── Обход дерева ──────────────────────────────────────────────────────────────

static func _run_node(node: Dictionary, player: Dictionary, logs: Array, board: Array) -> void:
	if node.has("group"):
		var children: Array = node["group"]
		for i in range(children.size()):
			_run_node(children[i], player, logs, board)
		return
	if node.has("choice"):
		# MVP: интерактивный выбор не реализован — берём первую ветку.
		var branches: Array = node["choice"]
		if not branches.is_empty():
			_run_node(branches[0], player, logs, board)
		return
	if node.has("dieRoll"):
		var d: int = randi() % 6 + 1
		var rules: Array = node["dieRoll"]
		for i in range(rules.size()):
			var rule: Dictionary = rules[i]
			if _in_range(d, String(rule.get("on", ""))):
				var then: Array = rule.get("then", [])
				for j in range(then.size()):
					_run_node(then[j], player, logs, board)
				break
		return
	if node.has("test"):
		# MVP: вложенную проверку считаем пройденной — в исходах встреч
		# такие узлы практически не встречаются.
		var on_pass: Array = node.get("onPass", [])
		for i in range(on_pass.size()):
			_run_node(on_pass[i], player, logs, board)
		return
	if node.has("do"):
		_run_action(node, player, logs, board)


static func _run_action(node: Dictionary, player: Dictionary, logs: Array, board: Array) -> void:
	if node.has("when") and not _predicate(node["when"], player):
		return
	var verb: String = String(node["do"])
	if not _PLAYER_VERBS.has(verb):
		board.append(node)   # уровень поля — применит GameState
		return
	var times: int = _repeat(node)
	for _i in times:
		_apply_player_verb(verb, node, player, logs)


# ── Действия по игроку ────────────────────────────────────────────────────────

static func _apply_player_verb(verb: String, node: Dictionary, player: Dictionary, logs: Array) -> void:
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
			player["sanity"] = mini(int(player.get("sanity_max", 0)), int(player.get("sanity", 0)) + n)
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
			pass   # move — трекинга позиции пока нет; text — только показ
		_:
			pass


# ── Хелперы ───────────────────────────────────────────────────────────────────

## Величина действия: amount либо count, по умолчанию 1.
static func _amount(node: Dictionary) -> int:
	if node.has("amount"):
		return int(node["amount"])
	if node.has("count"):
		return int(node["count"])
	return 1


## Повтор действия. repeat-литерал → число; repeat по источнику → 1
## (систем поля для подсчёта пока нет).
static func _repeat(node: Dictionary) -> int:
	var r: Variant = node.get("repeat", 1)
	if r is int:
		return maxi(1, int(r))
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


## Предикат when. Непокрытые виды считаем истиной (эффект применяется).
static func _predicate(pred: Dictionary, player: Dictionary) -> bool:
	var kind: String = String(pred.get("kind", "always"))
	var negate: bool = bool(pred.get("not", false))
	var result: bool
	match kind:
		"hasCondition":
			var conds: Array = player.get("conditions", [])
			result = conds.has(String(pred.get("condition", "")))
		"healthAtMost":
			result = int(player.get("hp", 0)) <= int(pred.get("n", 0))
		"sanityAtMost":
			result = int(player.get("sanity", 0)) <= int(pred.get("n", 0))
		_:
			result = true
	return result != negate
