class_name ConditionFlow
extends RefCounted

## Подсистема состояний и слотов эффектов (хост-only). Вынесена из GameState:
##   • Расплата (resolveReckoning): onReckoning состояний + двусторонний flip;
##   • whileHeld-ограничения (cannotMove/Act/Recover, removeFromBoard, immuneToEffects);
##   • triggered/action состояний (Hypothermia on:rest, Detained escape);
##   • выдача активов с исполнением onGain (одноразовые сервисы).
##
## Доступ к игровому стейту — через _gs (GameState): _gs.players, _gs._is_host(),
## _gs._name_of(), _gs._apply_board_effect(). Создаётся в GameState (поле _cond).

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


# ── Расплата (Reckoning): onReckoning состояний + двусторонний flip ────────────


## Хост: шаг Расплаты. Зовётся board-verb'ом resolveReckoning (мифос-карта
## reckoning). Проходит onReckoning всех держателей состояний и исполняет через
## интерпретатор; flipCard/discardCard обрабатываются над носителем-состоянием.
## flow (опц.) — детерминизм replay (как в EffectRunner): flow.rolls[path] фиксирует
## броски ворот (dieRoll/test в onReckoning), flow.outcomes[cid] форсирует исход
## flip'а. Пусто → прежнее случайное поведение. Используется тестами.
func host_resolve_reckoning(flow: Dictionary = {}) -> void:
	if not _gs._is_host():
		return
	GameConsole.log("[Расплата] начало")
	for pid_v: Variant in _gs.players.keys():
		_reckon_player(String(pid_v), flow)


func _reckon_player(pid: String, flow: Dictionary = {}) -> void:
	var p: Dictionary = _gs.players.get(pid, {})
	# Снимок списка: outcome-эффекты могут менять состав состояний в процессе.
	var conds: Array = (p.get("conditions", []) as Array).duplicate()
	for i in range(conds.size()):
		reckon_condition(pid, String(conds[i]), flow)


## Хост: Расплата ОДНОГО состояния сыщика (onReckoning + flip/discard через
## _apply_reckon_board). Уже перевёрнутое/снятое — no-op. Вынесено ради пер-карточного
## резолва в ReckoningFlow (сыщик выбирает порядок) и для _reckon_player.
func reckon_condition(pid: String, cid: String, flow: Dictionary = {}) -> void:
	var p: Dictionary = _gs.players.get(pid, {})
	if (p.get("conditions_flipped", {}) as Dictionary).has(cid):
		return  # уже перевёрнуто — фронтовой onReckoning не действует
	if not (p.get("conditions", []) as Array).has(cid):
		return  # снято в ходе этой же расплаты
	var def: Dictionary = Conditions.get_def(cid)
	var program: Array = def.get("onReckoning", [])
	if (program as Array).is_empty():
		return
	var inv: Dictionary = Investigators.get_data(String(p.get("investigator", "")))
	var ctx: Dictionary = {"skills": inv.get("skills", {})}
	var res: Dictionary = _EffectRunner.run(program, p, ctx, flow)
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[Расплата] %s · %s: %s" % [_gs._name_of(pid), cid, String(l_v)])
	for node_v: Variant in res.get("board", []):
		_apply_reckon_board(pid, cid, def, node_v as Dictionary, ctx, flow)


# board-узел из onReckoning состояния: flipCard/discardCard — над носителем cid,
# прочее (advanceDoom и т.п.) — обычным board-эффектом.
func _apply_reckon_board(
	pid: String,
	cid: String,
	def: Dictionary,
	node: Dictionary,
	ctx: Dictionary,
	flow: Dictionary = {}
) -> void:
	match String(node.get("do", "")):
		"flipCard":
			_flip_condition(pid, cid, def, ctx, flow)
		"discardCard":
			_discard_condition(pid, cid)
		_:
			_gs._apply_board_effect(node)


# Перевернуть состояние: вытянуть случайный оборот из СОБСТВЕННЫХ backs состояния
# (инлайн, как рубашки заклинаний), применить effect, затем then: flip|discard.
func _flip_condition(
	pid: String, cid: String, def: Dictionary, ctx: Dictionary, flow: Dictionary = {}
) -> void:
	var p: Dictionary = _gs.players.get(pid, {})
	var backs: Array = def.get("backs", [])
	if (backs as Array).is_empty():
		_set_flipped(p, cid, "")
		GameConsole.log("[Расплата] %s · %s перевёрнуто" % [_gs._name_of(pid), cid])
		return
	var back: Dictionary = _pick_back(backs, cid, flow)
	var bid: String = String(back.get("id", ""))
	_set_reckoning_result(pid, cid, back)  # для модалки результата флипа игрока
	var res: Dictionary = _EffectRunner.run(back.get("effect", []), p, ctx, flow)
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[Расплата] %s · исход «%s»: %s" % [_gs._name_of(pid), bid, String(l_v)])
	for node_v: Variant in res.get("board", []):
		_gs._apply_board_effect(node_v as Dictionary)
	if String(back.get("then", "flip")) == "discard":
		_discard_condition(pid, cid)
	else:
		_set_flipped(p, cid, bid)
		GameConsole.log("[Расплата] %s · %s → «%s»" % [_gs._name_of(pid), cid, bid])


# Выбор оборота: форс через flow.outcomes[cid] по id (детерминизм/тесты/replay),
# иначе случайный из собственных backs состояния (как random_back у заклинаний).
func _pick_back(backs: Array, cid: String, flow: Dictionary) -> Dictionary:
	var forced: String = String((flow.get("outcomes", {}) as Dictionary).get(cid, ""))
	if not forced.is_empty():
		for b_v: Variant in backs:
			if String((b_v as Dictionary).get("id", "")) == forced:
				return b_v
	return backs[randi() % backs.size()]


# Записать результат флипа для модалки игрока (per-player): выпавший оборот —
# имя + художественный текст (самоописательный). Хост-авторитетно, синкается.
func _set_reckoning_result(pid: String, cid: String, back: Dictionary) -> void:
	_gs.reckoning_results[pid] = {
		"cid": cid,
		"back": String(back.get("id", "")),
		"name": String(back.get("name", "")),
		"text": String(back.get("text", "")),
	}


func _set_flipped(p: Dictionary, cid: String, outcome_id: String) -> void:
	var fl: Dictionary = p.get("conditions_flipped", {})
	fl[cid] = outcome_id
	p["conditions_flipped"] = fl


func _discard_condition(pid: String, cid: String) -> void:
	var p: Dictionary = _gs.players.get(pid, {})
	var conds: Array = p.get("conditions", [])
	conds.erase(cid)
	p["conditions"] = conds
	(p.get("conditions_flipped", {}) as Dictionary).erase(cid)
	GameConsole.log("[Расплата] %s · %s сброшено" % [_gs._name_of(pid), cid])


# ── whileHeld-ограничения состояний ───────────────────────────────────────────


## Активные whileHeld-ограничения сыщика из held-состояний. Словарь:
## {cannotMove:true, cannotAct:true, removeFromBoard:true, immuneToEffects:true,
##  cannotRecover:[stat,…]}. См. data/conditions.json (Detained, Lost in Time).
func player_constraints(pid: String) -> Dictionary:
	var out: Dictionary = {}
	var conds: Array = (_gs.players.get(pid, {}) as Dictionary).get("conditions", [])
	for i in range(conds.size()):
		var while_held: Array = Conditions.get_def(String(conds[i])).get("whileHeld", [])
		for j in range(while_held.size()):
			var node: Dictionary = while_held[j]
			var verb: String = String(node.get("do", ""))
			if verb == "cannotRecover":
				var stats: Array = out.get("cannotRecover", [])
				stats.append(String(node.get("stat", "health")))
				out["cannotRecover"] = stats
			elif not verb.is_empty():
				out[verb] = true
	return out


## Есть ли у сыщика whileHeld-ограничение verb (для cannotRecover см. сам словарь).
func player_has_constraint(pid: String, verb: String) -> bool:
	return player_constraints(pid).has(verb)


## Порог успеха проверок сыщика от held-состояний (whileHeld successThreshold):
## Cursed → 6 («только 6»), Blessed → 4 («4-6»). Перевёрнутые не действуют. Конфликт
## (Cursed+Blessed разом) → нейтральные 5. Нет таких состояний → дефолт Dice ≥5.
func player_success_threshold(pid: String) -> int:
	var p: Dictionary = _gs.players.get(pid, {})
	var conds: Array = p.get("conditions", [])
	var flipped: Dictionary = p.get("conditions_flipped", {})
	var vals: Array = []
	for i in range(conds.size()):
		var cid: String = String(conds[i])
		if flipped.has(cid):
			continue  # перевёрнутое состояние фронтом не действует
		for n_v: Variant in Conditions.get_def(cid).get("whileHeld", []):
			if String((n_v as Dictionary).get("do", "")) == "successThreshold":
				vals.append(int((n_v as Dictionary).get("value", Dice.SUCCESS_MIN)))
	if vals.is_empty():
		return Dice.SUCCESS_MIN
	var first: int = int(vals[0])
	for v_v: Variant in vals:
		if int(v_v) != first:
			return Dice.SUCCESS_MIN  # конфликт (напр. Cursed+Blessed) → нейтрально
	return first


# ── Триггеры (triggered) и локальные действия (action) состояний ───────────────


## Хост: сработавшие triggered held-состояний по событию (напр. "rest"). Возвращает
## список stat'ов cannotRecover (подавление лечения — на зовущей стороне); прочее
## (dieRoll/test → flipCard/discardCard и т.п.) исполняет через интерпретатор.
func fire_triggered(pid: String, event: String, flow: Dictionary = {}) -> Array:
	var no_recover: Array = []
	if not _gs._is_host():
		return no_recover
	var p: Dictionary = _gs.players.get(pid, {})
	var conds: Array = (p.get("conditions", []) as Array).duplicate()
	var inv: Dictionary = Investigators.get_data(String(p.get("investigator", "")))
	var ctx: Dictionary = {"skills": inv.get("skills", {})}
	for i in range(conds.size()):
		var cid: String = String(conds[i])
		if not (p.get("conditions", []) as Array).has(cid):
			continue
		var def: Dictionary = Conditions.get_def(cid)
		for t_v: Variant in def.get("triggered", []):
			var t: Dictionary = t_v
			if String(t.get("on", "")) != event:
				continue
			var rest_nodes: Array = []
			for n_v: Variant in t.get("do", []):
				var n: Dictionary = n_v
				if String(n.get("do", "")) == "cannotRecover":
					no_recover.append(String(n.get("stat", "health")))
				else:
					rest_nodes.append(n)
			_run_carrier_program(pid, cid, def, rest_nodes, ctx, "Триггер:" + event, flow)
	return no_recover


## Хост: локальное действие состояния (action-слот, напр. Detained: проверка Влияния
## → сброс). true — состояние держится и имеет action. Разрешено даже при cannotAct.
func host_run_condition_action(pid: String, cond_id: String, flow: Dictionary = {}) -> bool:
	if not _gs._is_host():
		return false
	if not (_gs.players.get(pid, {}).get("conditions", []) as Array).has(cond_id):
		return false
	var def: Dictionary = Conditions.get_def(cond_id)
	var program: Array = def.get("action", [])
	if (program as Array).is_empty():
		return false
	var inv: Dictionary = Investigators.get_data(String(_gs.players[pid].get("investigator", "")))
	_run_carrier_program(
		pid, cond_id, def, program, {"skills": inv.get("skills", {})}, "Действие", flow
	)
	return true


## Хост: начать ВИДИМУЮ проверку локального действия состояния (как каст ритуала).
## Старт CheckFlow owner=condition (БЕЗ броска) + GameState.condition_action; ход держит
## phase_controller (release_condition_turn). true — проверка начата (у действия есть
## test-узел); false — действия с проверкой нет (вызывающий пробует синхронный путь).
func begin_action(pid: String, cond_id: String) -> bool:
	if not _gs._is_host():
		return false
	if not (_gs.players.get(pid, {}).get("conditions", []) as Array).has(cond_id):
		return false
	var test_node: Dictionary = _action_test_node(Conditions.get_def(cond_id))
	if test_node.is_empty():
		return false  # действие без проверки → синхронный host_run_condition_action
	_gs._check.start(
		"condition",
		pid,
		String(test_node.get("test", "influence")),
		int(test_node.get("modifier", 0)),
		"conditionAction"
	)
	_gs.condition_action = {"pid": pid, "condition_id": cond_id}
	return true


## Хост: применить результат проверки локального действия (кнопка «Применить»). По
## active_check.passed применяет onPass/onFail test-узла над носителем cid (discardCard
## и пр.), снимает проверку, освобождает ход.
func apply_action(pid: String, flow: Dictionary = {}) -> bool:
	if not _gs._is_host():
		return false
	var ca: Dictionary = _gs.condition_action
	if ca.is_empty() or String(ca.get("pid", "")) != pid:
		return false
	var c: Dictionary = _gs.active_check
	if String(c.get("owner", "")) != "condition":
		return false
	if not bool(c.get("rolled", false)):
		_gs._check.roll(pid)  # страховка: применить без явного броска
		c = _gs.active_check
	var cid: String = String(ca.get("condition_id", ""))
	var def: Dictionary = Conditions.get_def(cid)
	var passed: bool = bool(c.get("passed", false))
	var branch: Array = _action_test_node(def).get("onPass" if passed else "onFail", [])
	var inv: Dictionary = Investigators.get_data(String(_gs.players[pid].get("investigator", "")))
	_run_carrier_program(pid, cid, def, branch, {"skills": inv.get("skills", {})}, "Действие", flow)
	GameConsole.log(
		(
			"[Действие] %s · %s — проверка %s"
			% [_gs._name_of(pid), cid, "успех" if passed else "провал"]
		)
	)
	_gs._check.clear()
	_gs.condition_action = {}
	_gs._phase.release_condition_turn(pid)
	return true


# Первый test-узел в локальном действии состояния ({} если действие без проверки).
func _action_test_node(def: Dictionary) -> Dictionary:
	for n_v: Variant in def.get("action", []):
		if n_v is Dictionary and (n_v as Dictionary).has("test"):
			return n_v
	return {}


# Прогон Effect-программы носителя-состояния (триггер/действие): мутирует игрока,
# flipCard/discardCard — над cid, прочий board — обычным эффектом.
func _run_carrier_program(
	pid: String,
	cid: String,
	def: Dictionary,
	program: Array,
	ctx: Dictionary,
	tag: String,
	flow: Dictionary = {}
) -> void:
	var p: Dictionary = _gs.players.get(pid, {})
	var res: Dictionary = _EffectRunner.run(program, p, ctx, flow)
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[%s] %s · %s: %s" % [tag, _gs._name_of(pid), cid, String(l_v)])
	for node_v: Variant in res.get("board", []):
		_apply_reckon_board(pid, cid, def, node_v as Dictionary, ctx, flow)


# ── Выдача активов с исполнением onGain ───────────────────────────────────────


## Хост: выдать актив сыщику, исполнив его onGain. Сервис-актив (onGain содержит
## discardCard) срабатывает и НЕ попадает в инвентарь; прочие — добавляются как
## {id, exhausted:false}. Единая точка получения актива (магазин и пр.).
func host_grant_asset(pid: String, asset_id: String) -> void:
	if not _gs._is_host() or not _gs.players.has(pid):
		return
	var asset: Dictionary = AssetCatalog.by_id(asset_id)
	if asset.is_empty():
		return
	var p: Dictionary = _gs.players[pid]
	var on_gain: Array = (asset.get("effect", {}) as Dictionary).get("onGain", [])
	var consumed: bool = false
	if not (on_gain as Array).is_empty():
		var inv: Dictionary = Investigators.get_data(String(p.get("investigator", "")))
		var res: Dictionary = _EffectRunner.run(on_gain, p, {"skills": inv.get("skills", {})})
		for l_v: Variant in res.get("logs", []):
			GameConsole.log("[onGain %s] %s · %s" % [asset_id, _gs._name_of(pid), String(l_v)])
		for node_v: Variant in res.get("board", []):
			if String((node_v as Dictionary).get("do", "")) == "discardCard":
				consumed = true  # сервис: сработал и сбрасывается — в инвентарь не идёт
			else:
				_gs._apply_board_effect(node_v as Dictionary)
	if consumed:
		GameConsole.log(
			"[Актив] %s — сервис «%s» применён и сброшен" % [_gs._name_of(pid), asset_id]
		)
		return
	var items: Array = p.get("items", [])
	items.append({"id": asset_id, "exhausted": false})
	p["items"] = items
	GameConsole.log("[Актив] %s получил «%s»" % [_gs._name_of(pid), asset_id])
