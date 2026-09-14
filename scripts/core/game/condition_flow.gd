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

# Идущее локальное действие состояния (хост-only, НЕ синкается): {pid, cid, decisions,
# rolls}. Накапливает решения видимых проверок между переигрываниями программы действия.
# {} — действия нет. Видимая часть (карта/кубы) — в синкаемых pending_check/active_check.
var _action_run: Dictionary = {}


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
## interactive=true (живой шаг Расплаты, корутина): test-узлы onReckoning → ВИДИМАЯ
## проверка игрока через общий движок (как cursed/anxious «тест Воли»). false (тесты,
## board-applier fallback): прежний тихий детерминированный путь (flow.rolls).
func reckon_condition(
	pid: String, cid: String, flow: Dictionary = {}, interactive: bool = false
) -> void:
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
	if not interactive:
		var recon_before: Dictionary = (p as Dictionary).duplicate(true)
		var res: Dictionary = _EffectRunner.run(program, p, ctx, flow)
		_apply_reckon_output(pid, cid, def, ctx, res, flow)
		ActionFeed.announce_deltas(_gs, pid, recon_before, _gs.players.get(pid, {}))  # лента Расплаты
		ActionFeed.collect_gains(_gs, pid, recon_before, _gs.players.get(pid, {}))
		return
	await _reckon_condition_interactive(pid, cid, def, program, ctx)


# Корутина интерактивной Расплаты состояния: test пендит видимую проверку (pending_check
# {driver:reckoning} + CheckFlow), ждём effect_check_applied, пишем decision и
# переигрываем (dup-изоляция, как mythos/encounter). dieRoll остаётся тихим.
func _reckon_condition_interactive(
	pid: String, cid: String, def: Dictionary, program: Array, ctx: Dictionary
) -> void:
	var decisions: Dictionary = {}
	var rolls: Dictionary = {}
	var recon_before: Dictionary = (_gs.players.get(pid, {}) as Dictionary).duplicate(true)
	while true:
		if not _gs.players.has(pid) or bool(_gs.players[pid].get(PlayerKeys.DEAD, false)):
			return  # погиб посреди интерактивной Расплаты — новую проверку не пендим
		var dup: Dictionary = (_gs.players[pid] as Dictionary).duplicate(true)
		var fl: Dictionary = {
			"interactive": true,
			"checks_visible": true,
			"decisions": decisions,
			"rolls": rolls,
			"pending": {},
			"slot": "",
		}
		var res: Dictionary = _EffectRunner.run(program, dup, ctx, fl)
		rolls = fl.get("rolls", {})
		var pending: Dictionary = res.get("pending", {})
		if String(pending.get("kind", "")) == "check":
			# Per-player слот проверки Расплаты (параллельно с другими сыщиками): своя
			# проверка в самом игроке, не в едином active_check. См. GameState.reckoning_*.
			var p: Dictionary = _gs.players[pid]
			p["reckoning_check"] = _gs._check.make_check(
				"reckoning",
				pid,
				String(pending.get("skill", "will")),
				int(pending.get("modifier", 0)),
				"reckoning"
			)
			p["reckoning_pending"] = {
				"cid": cid,
				"path": String(pending.get("path", "")),
				"subject": Conditions.card_payload(cid),
			}
			_gs._broadcast_sync()
			_gs._emit_changed()
			var passed: bool = await _await_my_check(pid)
			var pp: Dictionary = _gs.players.get(pid, {})
			pp.erase("reckoning_check")
			pp.erase("reckoning_pending")
			decisions[String(pending.get("path", ""))] = passed
			continue
		if not pending.is_empty():
			# Выбор (optional flipCard у Righteous/Funding, choice) — модалка решения
			# через общий канал mythos_decision; параллельные Расплаты ждут очереди.
			decisions[String(pending.get("path", ""))] = await _await_reckon_decision(
				pid, pending, String(def.get("name", "")), Conditions.card_payload(cid)
			)
			continue
		_gs.players[pid] = dup  # коммит мутаций сыщика
		_apply_reckon_output(pid, cid, def, ctx, res, {})
		ActionFeed.announce_deltas(_gs, pid, recon_before, _gs.players.get(pid, {}))  # лента Расплаты
		ActionFeed.collect_gains(_gs, pid, recon_before, _gs.players.get(pid, {}))
		return


# Выбор сыщика в onReckoning состояния через общий канал mythos_decision (driver по
# умолчанию → host_apply_mythos_decision пишет picked и будит mythos_decided). Канал
# один, а Расплаты сыщиков идут параллельно: занят — ждём, пока владелец решит.
# Владелец ждал сигнала раньше нас, поэтому при emit он возобновляется первым и
# успевает освободить канал до нашей проверки. Отвалившийся сыщик — выбор за него
# случайный (GameState._on_player_left → host_apply_absent_decision).
func _await_reckon_decision(
	pid: String, pending: Dictionary, title_key: String, subject: Dictionary
) -> int:
	while bool(_gs.mythos_decision.get("active", false)):
		await _gs.mythos_decided
	_gs.mythos_decision = {
		"active": true,
		"pid": pid,
		"path": String(pending.get("path", "")),
		"options": pending.get("options", []),
		"by": "self",
		"kind": String(pending.get("kind", "choice")),
		"title_key": title_key,  # заголовок — имя состояния, чтобы было ясно, о чём выбор
		"subject": subject,  # сама карта — что именно предлагают перевернуть
		"prompt_key": "RECKONING_DECISION_PROMPT",
	}
	_gs._broadcast_sync()
	_gs._emit_changed()
	var pre: Variant = (_gs.mythos_decision as Dictionary).get("picked", null)
	var idx: int = int(pre) if pre != null else int(await _gs.mythos_decided)
	_gs.mythos_decision = {}
	return idx


# Ждём применения СВОЕЙ проверки Расплаты: общий сигнал effect_check_applied(pid, passed)
# будит все ожидающие корутины — фильтруем по своему pid (остальные ждут дальше).
# Отвалившийся сыщик броска не пришлёт — считаем проверку проваленной и не ждём,
# иначе весь тир Расплаты зависнет навсегда. _on_player_left будит парковку эмитом.
func _await_my_check(pid: String) -> bool:
	if not bool(_gs.players.get(pid, {}).get("connected", true)):
		return false
	var r: Array = await _gs.effect_check_applied
	while String(r[0]) != pid:
		if not bool(_gs.players.get(pid, {}).get("connected", true)):
			return false
		r = await _gs.effect_check_applied
	return bool(r[1])


# Логи + board-эффекты прогона onReckoning (flipCard/discardCard над cid и пр.).
func _apply_reckon_output(
	pid: String, cid: String, def: Dictionary, ctx: Dictionary, res: Dictionary, flow: Dictionary
) -> void:
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
	return Conditions.success_threshold(p.get("conditions", []), p.get("conditions_flipped", {}))


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


# Контекст проверки состояния — по его виду, чтобы пассивы активов с context
# illnessInjuryEffect (Медицинский журнал, Обезболивающее) / madnessEffect
# (Психоаналитик) прикладывались; прочие виды — общий conditionAction.
func _check_context(cond_id: String) -> String:
	match String(Conditions.get_def(cond_id).get("kind", "")):
		"illness", "injury":
			return "illnessInjuryEffect"
		"madness":
			return "madnessEffect"
	return "conditionAction"


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


## Хост: начать локальное действие состояния через ОБЩИЙ интерактивный движок test.
## Гоняет всю action-программу интерактивно (checks_visible) — её test-узел сам пендит
## видимую проверку (pending_check + CheckFlow owner=effectCheck); ход держит
## phase_controller (release_condition_turn). true — действие запущено (у него есть
## test-узел); false — действия с проверкой нет (вызывающий пробует синхронный путь).
func begin_action(pid: String, cond_id: String) -> bool:
	if not _gs._is_host():
		return false
	if not (_gs.players.get(pid, {}).get("conditions", []) as Array).has(cond_id):
		return false
	var def: Dictionary = Conditions.get_def(cond_id)
	if (def.get("action", []) as Array).is_empty():
		return false
	if _action_test_node(def).is_empty():
		return false  # действие без проверки → синхронный host_run_condition_action
	_action_run = {"pid": pid, "cid": cond_id, "decisions": {}, "rolls": {}}
	_run_action_program(pid)  # запустит программу и пендит первую видимую проверку
	return true


## Хост: разрешить видимую проверку action-программы (диспетч из resolve_pending_check).
## Пишет решение и ПЕРЕИГРЫВАЕТ программу: та либо пендит следующую проверку, либо
## завершается (применяя onPass/onFail). path — узел проверки, passed — результат.
func resolve_action_check(pid: String, path: String, passed: bool) -> void:
	if not _gs._is_host():
		return
	if _action_run.is_empty() or String(_action_run.get("pid", "")) != pid:
		return
	(_action_run["decisions"] as Dictionary)[path] = passed
	_run_action_program(pid)


## Прогон action-программы с dup-изоляцией (как mythos/encounter): на pend видимой
## проверки выставляет pending_check + CheckFlow и держит ход; на завершении коммитит
## мутации, применяет board (discardCard/flipCard над cid), чистит стейт и освобождает ход.
func _run_action_program(pid: String) -> void:
	var ar: Dictionary = _action_run
	var cid: String = String(ar.get("cid", ""))
	var def: Dictionary = Conditions.get_def(cid)
	var program: Array = def.get("action", [])
	var inv: Dictionary = Investigators.get_data(String(_gs.players[pid].get("investigator", "")))
	var dup: Dictionary = (_gs.players[pid] as Dictionary).duplicate(true)
	var flow: Dictionary = {
		"interactive": true,
		"checks_visible": true,
		"decisions": ar.get("decisions", {}),
		"rolls": ar.get("rolls", {}),
		"pending": {},
		"slot": "",
	}
	var res: Dictionary = _EffectRunner.run(program, dup, {"skills": inv.get("skills", {})}, flow)
	ar["rolls"] = flow.get("rolls", {})
	var pending: Dictionary = res.get("pending", {})
	if String(pending.get("kind", "")) == "check":
		_gs._check.start(
			"effectCheck",
			pid,
			String(pending.get("skill", "influence")),
			int(pending.get("modifier", 0)),
			_check_context(cid)
		)
		_gs.pending_check = {
			"pid": pid,
			"driver": "condition",
			"path": String(pending.get("path", "")),
			"subject": Conditions.card_payload(cid),
		}
		return  # ждём resolve_action_check; ход держит phase_controller
	# Завершено: коммит мутаций игрока + board-эффекты над носителем cid.
	_gs.players[pid] = dup
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[Действие] %s · %s: %s" % [_gs._name_of(pid), cid, String(l_v)])
	for node_v: Variant in res.get("board", []):
		_apply_reckon_board(pid, cid, def, node_v as Dictionary, {}, {})
	GameConsole.log("[Действие] %s · %s — завершено" % [_gs._name_of(pid), cid])
	_action_run = {}
	_gs.pending_check = {}
	_gs._check.clear()
	_gs._phase.release_condition_turn(pid)


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


## Хост: выдать актив сыщику, исполнив его onGain. Делегат в AssetActionFlow —
## программа карты может спросить игрока (какого монстра ранить, кому отдать вещи),
## поэтому выдача идёт тем же шаговым прогоном и очередью, что и действия активов.
func host_grant_asset(pid: String, asset_id: String) -> void:
	_gs._asset_action.grant(pid, asset_id)
