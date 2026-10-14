class_name MythosFlow
extends RefCounted

## Фаза Мифов: вытяжка карты из колоды, отображение модалки всем игрокам,
## применение onDraw-эффектов по подтверждению, переход к новому раунду.
## Колода (_deck/_index) — host-only, не синкается; восстанавливается по
## campaign.id из снапшота через ContentApi (см. restore_deck).
##
## Owner — GameState (autoload). MythosFlow читает/пишет публичные поля
## GameState напрямую (current_mythos/players/doom/omens_step/phase…),
## зовёт _gs.broadcast_sync() и _gs.emit_changed() для рассылки и сигналов
## стейта, _gs._phase.start_new_round() — для перехода фазы. Это сознательная
## близкая связь: модуль владеет своими данными (deck/index), но не своим
## жизненным циклом.

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

# Колода и позиция — host-only. Колода восстанавливается по campaign.id из
# снапшота при реджойне хоста (см. restore_deck), индекс синкается через
# game_sync (см. GameState.broadcast_sync / _apply_snapshot).
var deck: Array = []
var index: int = 0

var _gs: Node


func _init(gs: Node) -> void:
	_gs = gs


# ── Фаза ─────────────────────────────────────────────────────────────────────


## Вход в фазу Мифов из turn-flow (PhaseController.advance_encounter_turn /
## .enter_encounter).
## Хост сразу вытягивает карту и рассылает sync; не-хост дождётся синка с
## готовой current_mythos и покажет модалку.
func enter_phase() -> void:
	_gs.phase = Phases.MYTHOS
	_gs.current_encounter = {}
	GameConsole.log("[Game] Фаза Мифов")
	_gs.phase_changed.emit(_gs.phase)
	if _gs.is_host():
		# Две поломки, которые раньше были навсегда: обе лечатся здесь, потому
		# что фаза Мифов — единственное место, куда партия приходит регулярно.
		#
		# 1. Кампании нет вовсе: сборка при старте упала (API был недоступен), а
		#    игра пошла дальше без неё — без колоды Мифов и с заглушками вместо
		#    встреч (реле не знает Древнего). Перезапускаем сборку; она
		#    асинхронная, колода появится к следующей фазе, а встречи получат
		#    контекст кампании сразу, как она придёт.
		# 2. Кампания есть, колоды нет: единственная попытка восстановить её при
		#    реджойне упала. Пробуем ещё раз ПЕРЕД вытяжкой.
		if _campaign_id().is_empty():
			_retry_campaign()
		elif deck.is_empty():
			await restore_deck(_campaign_id())
		_draw_card()
		_gs.broadcast_sync()
	_gs.emit_changed()


## Перезапустить сборку кампании, если она не идёт прямо сейчас. Стабы без
## CampaignGen (тесты) — тихо ничего.
func _retry_campaign() -> void:
	if _gs.get("campaign_pending"):
		return
	var gen: Variant = _gs.get("_campaign")
	if gen == null or not gen.has_method("start_generation"):
		return
	GameConsole.warn("[Mythos] Кампании нет — перезапуск сборки")
	@warning_ignore("unsafe_method_access")
	gen.start_generation(gen.balance_player_count(), "")


## id кампании из GameState ("" — кампании нет или это стаб без поля).
func _campaign_id() -> String:
	var camp: Variant = _gs.get("campaign")
	if not (camp is Dictionary):
		return ""
	return String((camp as Dictionary).get("id", ""))


## Игрок нажал «Прочитал» в модалке мифа — отмечаем ЕГО. Не-хост шлёт хосту свой
## user_id, хост копит отметки; карта резолвится только когда отметились все
## подключённые (mark_read). Раньше любой игрок закрывал миф всем.
## Хост: отметить сыщика pid прочитавшим текущую карту мифа. Когда отметились ВСЕ
## подключённые — очищаем отметки и применяем эффекты (_apply_resolve). Вызывается
## из relay-роутера (RESOLVE_MYTHOS: хост — через act(), не-хост — через relay).
func mark_read(pid: String) -> void:
	if not _gs.is_host():
		return
	if _gs.phase != Phases.MYTHOS or _gs.current_mythos.is_empty():
		return
	if pid.is_empty() or not _gs.players.has(pid):
		return
	if not _gs.mythos_read.has(pid):
		_gs.mythos_read.append(pid)
	if _all_read():
		_gs.mythos_read = []
		_apply_resolve()
	else:
		_gs.broadcast_sync()  # обновляем прогресс «X/N» в модалках остальных
		_gs.emit_changed()


## Хост: сыщик отключился. Если карта мифа открыта и ждали именно его «Прочитал»,
## а все оставшиеся подключённые уже отметились — резолвим (иначе миф зависнет,
## ожидая ответа от того, кого уже нет).
func on_player_left() -> void:
	if not _gs.is_host():
		return
	if _gs.phase != Phases.MYTHOS or _gs.current_mythos.is_empty():
		return
	if _all_read():
		_gs.mythos_read = []
		_apply_resolve()


# Все подключённые ЖИВЫЕ сыщики отметились прочитавшими текущую карту. Тень карту
# видит, но «Прочитал» не жмёт и миф не держит — иначе зависал бы на мёртвом.
func _all_read() -> bool:
	for uid_v: Variant in _gs.players:
		var uid: String = String(uid_v)
		if not bool(_gs.players[uid].get("connected", true)):
			continue
		if bool(_gs.players[uid].get("dead", false)):
			continue
		if not _gs.mythos_read.has(uid):
			return false
	return true


# ── Host-only: вытяжка ───────────────────────────────────────────────────────


# Хост: вытянуть следующую карту из deck в current_mythos.
func _draw_card() -> void:
	_gs.mythos_read = []  # новая карта — никто ещё не прочитал
	# Колода Мифов пройдена до конца — время Древнего вышло: поражение партии.
	# Отличаем настоящее исчерпание (deck не пуст, дошли до конца) от сбоя
	# загрузки (deck пуст при index==0 — карта-заглушка, не финал).
	if not deck.is_empty() and index >= deck.size():
		_gs.current_mythos = {}
		if _gs.outcome.is_empty():
			_gs.outcome = "defeat"
			GameConsole.warn(
				"[Финал] Колода Мифов исчерпана — Древний пробуждается, поражение партии"
			)
		return
	if deck.is_empty():
		# Колода не загрузилась (сбой восстановления) — пустышка, чтобы цикл не вставал.
		_gs.current_mythos = {
			"name": "Эхо Древних",
			"flavorText": "Колода Мифов недоступна.",
			"text": "Ничего нового не происходит — миф крутится по последнему витку.",
			"onDraw": [],
		}
		GameConsole.warn("[Mythos] Колода недоступна — карта-заглушка")
		_gs.last_mythos = _gs.current_mythos  # доступна на «перечитать»
		return
	_gs.current_mythos = deck[index]
	_gs.last_mythos = _gs.current_mythos  # доступна на «перечитать» после резолва
	index += 1
	GameConsole.log("[Mythos] вытянута карта: %s" % String(_gs.current_mythos.get("name", "?")))


# Задержки (сек) между эффектами — чтобы анимация предыдущего успела доиграть
# на клиентах, прежде чем применяется следующий.
const _DELAY_OMEN: float = 2.7  # проворот диска омена
const _DELAY_GATE: float = 0.9  # открытие врат + монстр
const _DELAY_MONSTER: float = 0.6
const _DELAY_SURGE: float = 1.2
const _DELAY_DEFAULT: float = 0.45


# Хост: применить onDraw активной карты (последовательно) и стартовать раунд.
# Корутина: эффекты проигрываются по одному с паузой на анимацию каждого.
func _apply_resolve() -> void:
	if _gs.phase != Phases.MYTHOS or _gs.current_mythos.is_empty():
		return
	var card: Dictionary = _gs.current_mythos
	var effects: Array = card.get("onDraw", [])
	GameConsole.log("[Mythos] %s — разрешается" % String(card.get("name", "?")))
	# Закрываем модалку мифа сразу, чтобы игроки видели анимации эффектов на карте.
	_gs.current_mythos = {}
	# Ongoing-карта (есть whileInPlay/onReckoning-эффект) входит в игру ДО onReveal —
	# чтобы её Расплата участвовала, если onReveal сам триггерит шаг Расплаты
	# (resolveReckoning scope:mythosInPlay — «resolve each Mythos card in play»).
	_register_in_play(card)
	_gs.broadcast_sync()
	_gs.emit_changed()
	# Эффекты — последовательно, с ожиданием анимации каждого. Дум от омена
	# считается внутри шага омена (до открытия новых врат) — см. apply_board_effect.
	# Узел resolveReckoning внутри запускает корутину Расплаты (ReckoningFlow).
	await _apply_effects(effects)
	# Триггер Расплаты в onReckoning (legacy) → шаг Расплаты тем же путём.
	var on_reck: Array = card.get("onReckoning", [])
	if _is_reckoning_card(on_reck):
		await _apply_effects(on_reck)
	sweep_in_play()  # длящаяся карта, вышедшая при закрытых вратах, сразу уходит
	# Конец Фазы Мифов: Тайны типа tokensOnCard решаются именно здесь.
	_gs._mystery.check_mystery_tokens_solve()
	_gs._death.flush_ghost_clues()  # отложенные улики Теней ложатся после Мифа
	_gs._phase.start_new_round()
	_gs.broadcast_sync()
	_gs.emit_changed()


# Регистрирует карту как «в игре» (ongoing), если у неё есть whileInPlay или
# onReckoning-ЭФФЕКТ (а не только триггер resolveReckoning). Без дублей по name.
# Чистые event/триггер-карты в игре не остаются.
func _register_in_play(card: Dictionary) -> void:
	if not _has_ongoing(card):
		return
	var nm: String = String(card.get("name", ""))
	for c_v: Variant in _gs.mythos_in_play:
		if String((c_v as Dictionary).get("name", "")) == nm:
			return  # уже в игре
	(_gs.mythos_in_play as Array).append(card)
	GameConsole.log("[Mythos] карта «%s» остаётся в игре" % nm)
	if _gs._rumor.is_rumor(card):
		_gs._rumor.on_enter(card)  # Слух: открыть врата-портал + задать счётчик жетонов


# Карта ongoing: есть whileInPlay ЛИБО onReckoning с эффектом (узел не-resolveReckoning;
# структурный узел dieRoll/choice/group тоже считается эффектом).
func _has_ongoing(card: Dictionary) -> bool:
	if _gs._rumor.is_rumor(card):
		return true  # Слух всегда остаётся в игре (таймер + решение через врата)
	if not (card.get("whileInPlay", []) as Array).is_empty():
		return true
	for n_v: Variant in card.get("onReckoning", []):
		if n_v is Dictionary and String((n_v as Dictionary).get("do", "")) != "resolveReckoning":
			return true
	return false


# Карта-триггер Расплаты: её onReckoning содержит узел resolveReckoning.
func _is_reckoning_card(on_reck: Array) -> bool:
	for i in range(on_reck.size()):
		var node: Dictionary = on_reck[i]
		if node is Dictionary and String(node.get("do", "")) == "resolveReckoning":
			return true
	return false


# Эффекты карты Мифов, по одному. Узлы с target (target=each) — к каждому
# подключённому игроку; без target — на «доску» (advanceDoom/advanceOmen/
# openGate и т.п.). После каждого эффекта рассылаем синк и ждём его анимацию.
func _apply_effects(effects: Array) -> void:
	for i in range(effects.size()):
		var eff: Dictionary = effects[i]
		# forEach ДО String(eff.do): у него do — под-программа (Array), не verb-строка.
		if eff.has("forEach"):
			await _run_for_each(eff)
			continue
		var verb: String = String(eff.get("do", ""))
		if verb == "resolveReckoning":
			await _gs._reckoning.run_reckoning(String(eff.get("scope", "")))
			continue
		# Player-verb без target трактуем как target:"each" (миф — глобальное событие
		# на всех сыщиков). Иначе он уходил в board-ветку с dummy-dict и молча терялся
		# (gainCondition/heal/loseHealth и т.п. — состояние не доходило до сыщиков).
		if not eff.has("target") and _EffectRunner.is_player_verb(verb):
			eff = eff.duplicate()
			eff["target"] = "each"
		if eff.has("target"):
			# Цель разбирает TargetResolver (lead/each/eachOn*/neighbor/chosen). Раньше
			# здесь был безусловный проход по ВСЕМ игрокам — любой target деградировал
			# в «each»: карта с target:"lead"/"rightNeighbor"/"eachOnSea" била по всем.
			for uid_v: Variant in _gs._target._resolve_targets(eff):
				var uid: String = String(uid_v)
				if not _gs.players.has(uid):
					continue
				if not bool(_gs.players[uid].get("connected", true)):
					continue  # lead/chosen резолвер не фильтрует отключённых — страхуем
				if _gs._cond.player_has_constraint(uid, "immuneToEffects"):
					continue  # whileHeld immuneToEffects (Lost in Time)
				var before: Dictionary = (_gs.players[uid] as Dictionary).duplicate(true)
				var res: Dictionary = _EffectRunner.run([eff], _gs.players[uid])
				# Выданная услуга (onGain) — общим путём выдачи, а не в руку.
				for g_v: Variant in res.get("board", []):
					if String((g_v as Dictionary).get("do", "")) == "grantOnGain":
						_gs.apply_board_effect(g_v as Dictionary)
				ActionFeed.announce_deltas(_gs, uid, before, _gs.players[uid])  # лента исходов мифа
				ActionFeed.collect_gains(_gs, uid, before, _gs.players[uid])  # окно «вы получили»
				for log_msg in res.get("logs", []):
					GameConsole.log("[Mythos→%s] %s" % [_gs.name_of(uid), String(log_msg)])
		else:
			var dummy: Dictionary = {}
			var res: Dictionary = _EffectRunner.run([eff], dummy)
			for node in res.get("board", []):
				_gs.apply_board_effect(node)
				verb = String(node.get("do", verb))  # реальный verb board-узла
			for log_msg in res.get("logs", []):
				GameConsole.log("[Mythos] %s" % String(log_msg))
		# Рассылаем результат этого эффекта и ждём его анимацию перед следующим.
		_gs.broadcast_sync()
		_gs.emit_changed()
		await _gs.get_tree().create_timer(_effect_delay(verb)).timeout


# Пауза под анимацию конкретного эффекта.
func _effect_delay(verb: String) -> float:
	match verb:
		"advanceOmen", "moveOmen":
			return _DELAY_OMEN
		"openGate":
			return _DELAY_GATE
		"spawnMonster":
			return _DELAY_MONSTER
		"monsterSurge":
			return _DELAY_SURGE
	return _DELAY_DEFAULT


# ── forEach: интерактивный проход по сыщикам ──────────────────────────────────


# Узел {forEach:"each", do:[…]} — проход по сыщикам (Ведущий первым); для КАЖДОГО
# гоняем под-программу `do` интерактивно: выбор делает сам сыщик. Host-only,
# корутина (ждёт решения каждого сыщика).
func _run_for_each(node: Dictionary) -> void:
	if not _gs.is_host():
		return
	var sub: Array = node.get("do", [])
	if (sub as Array).is_empty():
		return
	var pids: Array = _for_each_pids(
		String(node.get("forEach", "each")), String(node.get("location", ""))
	)
	for i: int in range(pids.size()):
		await _run_player_subprogram(String(pids[i]), sub)
	# Подчищаем выбор (на случай ранней очистки/дисконнекта) и синкаем.
	_gs.mythos_decision = {}
	_gs.broadcast_sync()
	_gs.emit_changed()


# Сыщики forEach-прохода: подключённые в порядке turn_order (Ведущий = turn_order[0]
# первым). Разбор цели (each/eachOn*) делегируем в TargetResolver.
func _for_each_pids(target: String, location: String = "") -> Array:
	var node: Dictionary = {"target": target}
	if not location.is_empty():
		node["location"] = location  # eachOnSpace: явная клетка («сыщики на поле»)
	return _gs._target._resolve_targets(node)


## Суммарный модификатор проверок сыщика pid от длящихся карт Мифов в игре:
## whileInPlay {do:"checkModifier", amount, location?} — на клетке location (без неё
## — везде). «Жатвенная луна: все проверки на поле −1».
func check_modifier(pid: String) -> int:
	var loc: String = String((_gs.players.get(pid, {}) as Dictionary).get("location", ""))
	var total: int = 0
	for c_v: Variant in _gs.mythos_in_play as Array:
		for n_v: Variant in (c_v as Dictionary).get("whileInPlay", []):
			var n: Dictionary = n_v if n_v is Dictionary else {}
			if String(n.get("do", "")) != "checkModifier":
				continue
			var where: String = String(n.get("location", ""))
			if where.is_empty() or where == loc:
				total += int(n.get("amount", -1))
	return total


## Сбросить длящиеся карты Мифов, чьё условие discardWhen стало истинным («сбрасывается,
## когда врата закрыты»). Зовётся после закрытия врат и после розыгрыша карты.
func sweep_in_play() -> void:
	var keep: Array = []
	var dropped: bool = false
	# Врата текущего стола — явно в ctx (предикаты поля без ctx читают автолоад).
	var ctx: Dictionary = {}
	var gates: Variant = _gs.get("gates")
	if gates is Dictionary:
		ctx["gates"] = gates
	for c_v: Variant in _gs.mythos_in_play as Array:
		var card: Dictionary = c_v
		var cond: Dictionary = card.get("discardWhen", {})
		if not cond.is_empty() and _EffectRunner.eval_predicate(cond, {}, ctx):
			GameConsole.log("[Mythos] «%s» сброшена" % String(card.get("name", "?")))
			dropped = true
			continue
		keep.append(card)
	if dropped:
		_gs.mythos_in_play = keep
		_gs.broadcast_sync()
		_gs.emit_changed()


# Прочие подключённые сыщики (кроме active_pid) как [{pid, name}] — варианты для
# chosenInvestigator внутри forEach (зеркало EncounterFlow._other_investigators).
func _other_pids(active_pid: String) -> Array:
	var out: Array = []
	for pid_v: Variant in _gs.turn_order:
		var p: String = String(pid_v)
		if p == active_pid or not _gs.players.has(p):
			continue
		if not bool(_gs.players[p].get("connected", true)):
			continue
		if bool(_gs.players[p].get("dead", false)):
			continue  # Тень нельзя выбрать как «другого сыщика»
		out.append({"pid": p, "name": _gs.name_of(p)})
	return out


# Под-программа одного сыщика: dup-изоляция + интерактивный choice. Мутации игрока и
# board-эффекты коммитим ТОЛЬКО при завершении без pending (иначе переигровка после
# выбора применила бы их повторно). Относительные цели (rightNeighbor) внутри —
# от ЭТОГО сыщика: штампуем _anchor_pid на board-узлы.
func _run_player_subprogram(pid: String, sub: Array) -> void:
	if not _gs.players.has(pid):
		return
	if _gs._cond.player_has_constraint(pid, "immuneToEffects"):
		return  # whileHeld immuneToEffects (Lost in Time) — сыщик невосприимчив
	var decisions: Dictionary = {}
	var rolls: Dictionary = {}
	# Контекст интерактивного выбора: монстры на поле (chosenMonster) и прочие сыщики
	# (chosenInvestigator). Стабилен на время прохода сыщика (сброс — на завершении).
	var choices: Array = _gs._board.monster_choices()
	var others: Array = _other_pids(pid)
	var sub_before: Dictionary = (_gs.players[pid] as Dictionary).duplicate(true)  # для ленты исходов
	while true:
		var dup: Dictionary = (_gs.players[pid] as Dictionary).duplicate(true)
		var flow: Dictionary = {
			"interactive": true,
			"checks_visible": true,  # test в forEach → ВИДИМАЯ проверка (общий движок)
			"decisions": decisions,
			"rolls": rolls,
			"pending": {},
			"slot": "",
		}
		var res: Dictionary = _EffectRunner.run(
			sub, dup, {"monster_choices": choices, "other_pids": others}, flow
		)
		rolls = flow.get("rolls", {})
		var pending: Dictionary = res.get("pending", {})
		if pending.is_empty():
			_gs.players[pid] = dup  # коммит мутаций самого сыщика
			ActionFeed.announce_deltas(_gs, pid, sub_before, dup)  # лента исходов мифа (forEach)
			ActionFeed.collect_gains(_gs, pid, sub_before, dup)  # окно «вы получили»
			for node_v: Variant in res.get("board", []):
				var bnode: Dictionary = node_v
				bnode["_anchor_pid"] = pid  # относительные цели — от этого сыщика
				_gs.apply_board_effect(bnode)
			for log_msg: Variant in res.get("logs", []):
				GameConsole.log("[Mythos→%s] %s" % [_gs.name_of(pid), String(log_msg)])
			_gs.broadcast_sync()
			_gs.emit_changed()
			await _gs.get_tree().create_timer(_DELAY_DEFAULT).timeout
			return
		# Видимая проверка test: общая модалка проверки (CheckFlow), не модалка выбора.
		if String(pending.get("kind", "")) == "check":
			_gs._check.start(
				"effectCheck",
				pid,
				String(pending.get("skill", "will")),
				int(pending.get("modifier", 0)),
				"mythosEffect"
			)
			_gs.pending_check = {
				"pid": pid,
				"driver": "mythos",
				"path": String(pending.get("path", "")),
				"subject": {},
			}
			_gs.broadcast_sync()
			_gs.emit_changed()
			var passed: bool = await _await_check(pid)
			_gs.pending_check = {}
			_gs._check.clear()
			decisions[String(pending.get("path", ""))] = passed
			continue
		# Пауза на выбор: показываем модалку сыщику pid, ждём его решение.
		_gs.mythos_decision = {
			"active": true,
			"pid": pid,
			"path": String(pending.get("path", "")),
			"options": pending.get("options", []),
			"by": String(pending.get("by", "self")),
			"kind": String(pending.get("kind", "choice")),  # choice | target | monster
		}
		_gs.broadcast_sync()
		_gs.emit_changed()
		# Решение: для target/monster пишем ref/pid выбранной опции, иначе — индекс ветки.
		var idx: int = await _await_decision()
		var pkind: String = String(pending.get("kind", "choice"))
		var popts: Array = pending.get("options", [])
		var dval: Variant = idx
		if (pkind == "monster" or pkind == "target") and idx >= 0 and idx < (popts as Array).size():
			dval = String(
				(popts[idx] as Dictionary).get("ref" if pkind == "monster" else "pid", "")
			)
		decisions[String(pending.get("path", ""))] = dval
		_gs.mythos_decision = {}


# Ждём решение сыщика. Уже проставлено (сигнал мог прийти до await) — берём сразу;
# иначе блокируемся на сигнале mythos_decided.
func _await_decision() -> int:
	var pre: Variant = (_gs.mythos_decision as Dictionary).get("picked", null)
	if pre != null:
		return int(pre)
	return int(await _gs.mythos_decided)


# Ждём применения видимой проверки сыщика pid: общий сигнал effect_check_applied(pid,
# passed) — фильтруем по своему pid (на случай параллельных проверок Расплаты).
# Отвалившийся сыщик броска не пришлёт — считаем проверку проваленной, иначе фаза
# Мифов зависнет навсегда. _on_player_left будит парковку эмитом.
func _await_check(pid: String) -> bool:
	if not bool(_gs.players.get(pid, {}).get("connected", true)):
		return false
	var r: Array = await _gs.effect_check_applied
	while String(r[0]) != pid:
		if not bool(_gs.players.get(pid, {}).get("connected", true)):
			return false
		r = await _gs.effect_check_applied
	return bool(r[1])


# ── Реджойн ──────────────────────────────────────────────────────────────────


## Хост: восстановить deck после реджойна. Полная библия живёт в relay-API
## (таблица `campaigns`), тянем её по campaign.id из снапшота. Индекс уже
## подтянулся из снапшота — здесь восстанавливаем только саму колоду.
func restore_deck(campaign_id: String) -> void:
	# Абсолютный путь допустим только из дерева сцены: вне его (тесты, стабы)
	# Godot пишет ERROR в консоль вместо null.
	var api: Node = _gs.get_node_or_null("/root/ContentApi") if _gs.is_inside_tree() else null
	if api == null:
		GameConsole.warn("[Mythos] ContentApi недоступен — колоду не восстановить")
		return
	GameConsole.log("[Mythos] Восстановление колоды кампании %s..." % campaign_id.substr(0, 8))
	@warning_ignore("unsafe_method_access")
	var res: Dictionary = await api.get_campaign(campaign_id)
	if not bool(res.get("ok", false)):
		GameConsole.warn("[Mythos] Не удалось получить кампанию: %s" % String(res.get("error", "")))
		return
	var full: Dictionary = res.get("campaign", {})
	deck = full.get("mythosDeck", [])
	GameConsole.log("[Mythos] Колода восстановлена: %d карт (позиция %d)" % [deck.size(), index])
