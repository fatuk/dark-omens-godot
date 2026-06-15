class_name MythosFlow
extends RefCounted

## Фаза Мифов: вытяжка карты из колоды, отображение модалки всем игрокам,
## применение onDraw-эффектов по подтверждению, переход к новому раунду.
## Колода (_deck/_index) — host-only, не синкается; восстанавливается по
## campaign.id из снапшота через ContentApi (см. restore_deck).
##
## Owner — GameState (autoload). MythosFlow читает/пишет публичные поля
## GameState напрямую (current_mythos/players/doom/omens_step/phase…),
## зовёт _gs._broadcast_sync() и _gs._emit_changed() для рассылки и сигналов
## стейта, _gs._phase.start_new_round() — для перехода фазы. Это сознательная
## близкая связь: модуль владеет своими данными (deck/index), но не своим
## жизненным циклом.

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

# Колода и позиция — host-only. Колода восстанавливается по campaign.id из
# снапшота при реджойне хоста (см. restore_deck), индекс синкается через
# game_sync (см. GameState._broadcast_sync / _apply_snapshot).
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
	_gs.phase = "mythos"
	_gs.current_encounter = {}
	GameConsole.log("[Game] Фаза Мифов")
	_gs.phase_changed.emit(_gs.phase)
	if _gs._is_host():
		_draw_card()
		_gs._broadcast_sync()
	_gs._emit_changed()


## Любой игрок подтверждает «Дальше» в модалке мифа. Не-хост релеит хосту,
## хост применяет эффекты и стартует новый раунд.
func resolve() -> void:
	if _gs._is_host():
		_apply_resolve()
	else:
		_gs._nm.relay_all({"action": "game_resolve_mythos"})


# ── Host-only: вытяжка ───────────────────────────────────────────────────────


# Хост: вытянуть следующую карту из deck в current_mythos.
func _draw_card() -> void:
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
		return
	_gs.current_mythos = deck[index]
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
	if _gs.phase != "mythos" or _gs.current_mythos.is_empty():
		return
	var card: Dictionary = _gs.current_mythos
	var effects: Array = card.get("onDraw", [])
	GameConsole.log("[Mythos] %s — разрешается" % String(card.get("name", "?")))
	# Закрываем модалку мифа сразу, чтобы игроки видели анимации эффектов на карте.
	_gs.current_mythos = {}
	_gs._broadcast_sync()
	_gs._emit_changed()
	# Эффекты — последовательно, с ожиданием анимации каждого. Дум от омена
	# считается внутри шага омена (до открытия новых врат) — см. _apply_board_effect.
	await _apply_effects(effects)
	# Ongoing-карта (есть whileInPlay/onReckoning-эффект) остаётся в игре — до шага
	# Расплаты, чтобы свежая карта участвовала в текущей Расплате (тир «карты Мифов»).
	_register_in_play(card)
	# Карта-Расплата (её onReckoning содержит resolveReckoning) → выполняем шаг
	# Расплаты: onReckoning состояний и пр. (см. ConditionFlow.host_resolve_reckoning).
	var on_reck: Array = card.get("onReckoning", [])
	if _is_reckoning_card(on_reck):
		await _apply_effects(on_reck)
	# Конец Фазы Мифов: Тайны типа tokensOnCard решаются именно здесь.
	_gs._mystery.check_mystery_tokens_solve()
	_gs._phase.start_new_round()
	_gs._broadcast_sync()
	_gs._emit_changed()


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


# Карта ongoing: есть whileInPlay ЛИБО onReckoning с эффектом (узел не-resolveReckoning;
# структурный узел dieRoll/choice/group тоже считается эффектом).
func _has_ongoing(card: Dictionary) -> bool:
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
		var verb: String = String(eff.get("do", ""))
		if eff.has("forEach"):
			await _run_for_each(eff)
			continue
		if eff.has("target"):
			for uid: String in _gs.players:
				if not bool(_gs.players[uid].get("connected", true)):
					continue
				if _gs._cond.player_has_constraint(uid, "immuneToEffects"):
					continue  # whileHeld immuneToEffects (Lost in Time)
				var res: Dictionary = _EffectRunner.run([eff], _gs.players[uid])
				for log_msg in res.get("logs", []):
					GameConsole.log("[Mythos→%s] %s" % [_gs._name_of(uid), String(log_msg)])
		else:
			var dummy: Dictionary = {}
			var res: Dictionary = _EffectRunner.run([eff], dummy)
			for node in res.get("board", []):
				_gs._apply_board_effect(node)
				verb = String(node.get("do", verb))  # реальный verb board-узла
			for log_msg in res.get("logs", []):
				GameConsole.log("[Mythos] %s" % String(log_msg))
		# Рассылаем результат этого эффекта и ждём его анимацию перед следующим.
		_gs._broadcast_sync()
		_gs._emit_changed()
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
	if not _gs._is_host():
		return
	var sub: Array = node.get("do", [])
	if (sub as Array).is_empty():
		return
	var pids: Array = _for_each_pids(String(node.get("forEach", "each")))
	for i: int in range(pids.size()):
		await _run_player_subprogram(String(pids[i]), sub)
	# Подчищаем выбор (на случай ранней очистки/дисконнекта) и синкаем.
	_gs.mythos_decision = {}
	_gs._broadcast_sync()
	_gs._emit_changed()


# Сыщики forEach-прохода: подключённые в порядке turn_order (Ведущий = turn_order[0]
# первым). Разбор цели (each/eachOn*) делегируем в TargetResolver.
func _for_each_pids(target: String) -> Array:
	return _gs._target._resolve_targets({"target": target})


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
	while true:
		var dup: Dictionary = (_gs.players[pid] as Dictionary).duplicate(true)
		var flow: Dictionary = {
			"interactive": true,
			"decisions": decisions,
			"rolls": rolls,
			"pending": {},
			"slot": "",
		}
		var res: Dictionary = _EffectRunner.run(sub, dup, {}, flow)
		rolls = flow.get("rolls", {})
		var pending: Dictionary = res.get("pending", {})
		if pending.is_empty():
			_gs.players[pid] = dup  # коммит мутаций самого сыщика
			for node_v: Variant in res.get("board", []):
				var bnode: Dictionary = node_v
				bnode["_anchor_pid"] = pid  # относительные цели — от этого сыщика
				_gs._apply_board_effect(bnode)
			for log_msg: Variant in res.get("logs", []):
				GameConsole.log("[Mythos→%s] %s" % [_gs._name_of(pid), String(log_msg)])
			_gs._broadcast_sync()
			_gs._emit_changed()
			await _gs.get_tree().create_timer(_DELAY_DEFAULT).timeout
			return
		# Пауза на выбор: показываем модалку сыщику pid, ждём его решение.
		_gs.mythos_decision = {
			"active": true,
			"pid": pid,
			"path": String(pending.get("path", "")),
			"options": pending.get("options", []),
			"by": String(pending.get("by", "self")),
		}
		_gs._broadcast_sync()
		_gs._emit_changed()
		decisions[String(pending.get("path", ""))] = await _await_decision()
		_gs.mythos_decision = {}


# Ждём решение сыщика. Уже проставлено (сигнал мог прийти до await) — берём сразу;
# иначе блокируемся на сигнале mythos_decided.
func _await_decision() -> int:
	var pre: Variant = (_gs.mythos_decision as Dictionary).get("picked", null)
	if pre != null:
		return int(pre)
	return int(await _gs.mythos_decided)


# ── Реджойн ──────────────────────────────────────────────────────────────────


## Хост: восстановить deck после реджойна. Полная библия живёт в relay-API
## (таблица `campaigns`), тянем её по campaign.id из снапшота. Индекс уже
## подтянулся из снапшота — здесь восстанавливаем только саму колоду.
func restore_deck(campaign_id: String) -> void:
	var api: Node = _gs.get_node_or_null("/root/ContentApi")
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
