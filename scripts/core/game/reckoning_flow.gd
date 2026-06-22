class_name ReckoningFlow
extends RefCounted

## Шаг Расплаты (host-only, корутина). Глобальные тиры ПОСЛЕДОВАТЕЛЬНО: Древний → карты
## Мифов в игре → монстры (хост-тихо, board-эффекты типа advanceDoom/dieRoll, цели
## target:each). Затем тир сыщиков ПАРАЛЛЕЛЬНО: каждый у себя одновременно резолвит свои
## карты Расплаты (состояния — видимая проверка + флип через ConditionFlow; активы —
## effect.onReckoning), фаза завершается, когда ВСЕ закончили (гейт player_reckoned).
## scope=="mythosInPlay" → только тир карт Мифов в игре (для строки «resolve the Reckoning
## of each Mythos card in play»). Создаётся в GameState (_reckoning).
##
## NB: порядок карт сыщика — АВТО (состояния, затем активы); per-player выбор порядка убран
## ради параллельности (одна модалка выбора на всех конфликтовала бы).

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")
const _CARD_DELAY := 0.3  # пауза между картами Расплаты сыщика (под анимацию)

signal player_reckoned  # сыщик закончил свою Расплату (для гейта завершения всех)

var _gs: Node
var _reck_total: int = 0  # сколько сыщиков в параллельном тире
var _reck_done: int = 0  # сколько уже закончили


func _init(gs: Node) -> void:
	_gs = gs


## Полный шаг Расплаты (или только mythosInPlay при scope). Host-only, корутина.
func run_reckoning(scope: String = "") -> void:
	if not _gs._is_host():
		return
	GameConsole.log("[Расплата] начало (%s)" % ("full" if scope.is_empty() else scope))
	if scope == "mythosInPlay":
		_reckon_mythos_in_play()
		_gs._broadcast_sync()
		_gs._emit_changed()
		return
	_reckon_ancient()
	_reckon_mythos_in_play()
	_reckon_monsters()
	_gs._broadcast_sync()
	_gs._emit_changed()
	await _reckon_investigators()


# ── Глобальные тиры (Древний / карты Мифов / монстры) ─────────────────────────


# Тир 1: Расплата активного Древнего.
func _reckon_ancient() -> void:
	# campaign.ancientOne.onReckoning — DSL Расплаты Древнего, приходит из CMS через
	# библию (relay campaign-fallback). Источник правды — админка (data.onReckoning).
	# Пусто → Древний в Расплате молчит.
	var ao: Dictionary = _gs.campaign.get("ancientOne", {})
	_apply_global(ao.get("onReckoning", []), "Древний")


# Тир 2: Расплата каждой карты Мифов в игре (её onReckoning-эффект, без триггеров).
# Узел discardCard в Расплате карты → карта уходит из игры (пересобираем mythos_in_play).
func _reckon_mythos_in_play() -> void:
	var keep: Array = []
	for c_v: Variant in _gs.mythos_in_play as Array:
		var card: Dictionary = c_v
		if _gs._rumor.is_rumor(card):
			_gs._rumor.reckon(card)  # Слух: снять жетон / Рок за врата. Остаётся в игре.
			keep.append(card)
			continue
		if _run_card_reckoning(card):
			GameConsole.log("[Расплата] карта Мифов «%s» сброшена" % String(card.get("name", "?")))
		else:
			keep.append(card)
	_gs.mythos_in_play = keep


# Прогон Расплаты одной карты Мифов в игре. Узел discardCard перехватывается →
# возвращаем true (карту убрать из игры); прочие board-эффекты применяются обычно.
# Зеркало обработки flipCard/discardCard над носителем-состоянием в ConditionFlow.
func _run_card_reckoning(card: Dictionary) -> bool:
	var prog: Array = _effect_nodes(card.get("onReckoning", []))
	if (prog as Array).is_empty():
		return false
	var flow: Dictionary = {
		"interactive": true, "decisions": {}, "rolls": {}, "pending": {}, "slot": ""
	}
	var res: Dictionary = _EffectRunner.run(prog, {}, {}, flow)
	if not (res.get("pending", {}) as Dictionary).is_empty():
		GameConsole.warn("[Расплата] выбор в Расплате карты Мифов не поддержан — пропуск")
		return false
	var discard: bool = false
	for node_v: Variant in res.get("board", []):
		if String((node_v as Dictionary).get("do", "")) == "discardCard":
			discard = true  # сброс ЭТОЙ карты из игры
		else:
			_gs._apply_board_effect(node_v as Dictionary)
	var label: String = "Миф «%s»" % String(card.get("name", "?"))
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[Расплата:%s] %s" % [label, String(l_v)])
	return discard


# Тир 3: Расплата каждого монстра на доске.
func _reckon_monsters() -> void:
	for loc_v: Variant in (_gs.monsters as Dictionary).keys():
		for inst_v: Variant in _gs.monsters[loc_v] as Array:
			var mid: String = String((inst_v as Dictionary).get("id", inst_v))
			_apply_global(MonsterCatalog.reckoning_of(mid), "Монстр %s" % mid)


# Прогон глобальной (не привязанной к сыщику) onReckoning-программы. interactive:true,
# чтобы цели target:each уходили в board (TargetResolver), а не на dummy-игрока. choice
# в глобальной Расплате не поддержан (некому выбирать) — pend → лог-предупреждение.
func _apply_global(prog: Array, label: String) -> void:
	if (prog as Array).is_empty():
		return
	var flow: Dictionary = {
		"interactive": true, "decisions": {}, "rolls": {}, "pending": {}, "slot": ""
	}
	var res: Dictionary = _EffectRunner.run(prog, {}, {}, flow)
	if not (res.get("pending", {}) as Dictionary).is_empty():
		GameConsole.warn("[Расплата:%s] выбор в глобальной Расплате не поддержан — пропуск" % label)
		return
	for node_v: Variant in res.get("board", []):
		_gs._apply_board_effect(node_v as Dictionary)
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[Расплата:%s] %s" % [label, String(l_v)])


# Узлы-ЭФФЕКТЫ программы (отбрасываем триггеры resolveReckoning — иначе рекурсия).
func _effect_nodes(prog: Array) -> Array:
	var out: Array = []
	for n_v: Variant in prog:
		if n_v is Dictionary and String((n_v as Dictionary).get("do", "")) == "resolveReckoning":
			continue
		out.append(n_v)
	return out


# ── Тир сыщиков ───────────────────────────────────────────────────────────────


# ПАРАЛЛЕЛЬНЫЙ тир: все сыщики резолвят свою Расплату одновременно (каждый у себя),
# фаза завершается, когда ВСЕ закончили. reckoning_active — для оверлея «ждём других».
func _reckon_investigators() -> void:
	var pids: Array = _gs._target._resolve_targets({"target": "each"})
	if (pids as Array).is_empty():
		return
	_reck_total = (pids as Array).size()
	_reck_done = 0
	for pid_v: Variant in pids:
		(_gs.players.get(String(pid_v), {}) as Dictionary).erase("reckoning_done")  # свежий старт
	_gs.reckoning_active = true
	_gs._broadcast_sync()
	_gs._emit_changed()
	for pid_v: Variant in pids:
		_reckon_investigator(String(pid_v))  # запускаем корутину БЕЗ await — параллельно
	while _reck_done < _reck_total:
		await player_reckoned  # ждём, пока все N не отметятся
	_gs.reckoning_active = false
	for pid_v: Variant in pids:
		(_gs.players.get(String(pid_v), {}) as Dictionary).erase("reckoning_done")
	_gs._broadcast_sync()
	_gs._emit_changed()


# Расплата одного сыщика (своя корутина): его карты в АВТО-порядке (состояния → активы);
# по карте await своей проверки. На финише ставит reckoning_done (для оверлея «ждём
# других» — не мигает между своими картами) + инкремент гейта + сигнал player_reckoned.
func _reckon_investigator(pid: String) -> void:
	if _gs.players.has(pid):
		var cards: Array = _collect_reckoning_cards(pid)
		while not (cards as Array).is_empty():
			var card: Dictionary = cards[0]
			(cards as Array).remove_at(0)
			await _resolve_card(pid, card)
			cards = _filter_valid(pid, cards)
		if _gs.players.has(pid):
			(_gs.players[pid] as Dictionary)["reckoning_done"] = true
		_gs._broadcast_sync()
		_gs._emit_changed()
	_reck_done += 1
	player_reckoned.emit()


# Оставшиеся карты, что ещё валидны после резолва соседней (состояние могло быть
# снято/перевёрнуто). Активы оставляем (в рамках одной Расплаты не «снимаются»).
func _filter_valid(pid: String, cards: Array) -> Array:
	var p: Dictionary = _gs.players.get(pid, {})
	var out: Array = []
	for c_v: Variant in cards:
		var c: Dictionary = c_v
		if String(c.get("kind", "")) != "condition":
			out.append(c)
		elif (
			(p.get("conditions", []) as Array).has(String(c.get("id", "")))
			and not (p.get("conditions_flipped", {}) as Dictionary).has(String(c.get("id", "")))
		):
			out.append(c)
	return out


# Карты Расплаты сыщика: [{kind:"condition"|"asset", id, name_key}].
func _collect_reckoning_cards(pid: String) -> Array:
	var out: Array = []
	var p: Dictionary = _gs.players.get(pid, {})
	for cid_v: Variant in p.get("conditions", []) as Array:
		var cid: String = String(cid_v)
		if (p.get("conditions_flipped", {}) as Dictionary).has(cid):
			continue
		if (Conditions.get_def(cid).get("onReckoning", []) as Array).is_empty():
			continue
		out.append({"kind": "condition", "id": cid, "name_key": Conditions.name_key(cid)})
	for item_v: Variant in p.get("items", []) as Array:
		var aid: String = AssetCatalog.entry_id(item_v)
		if aid.is_empty() or AssetCatalog.reckoning_of(aid).is_empty():
			continue
		out.append(
			{
				"kind": "asset",
				"id": aid,
				"name_key": String(AssetCatalog.by_id(aid).get("nameKey", aid))
			}
		)
	return out


# Резолв одной карты Расплаты сыщика + синк/пауза под анимацию.
func _resolve_card(pid: String, card: Dictionary) -> void:
	if String(card.get("kind", "")) == "condition":
		# interactive: test-узлы onReckoning → видимая проверка игрока (корутина).
		await _gs._cond.reckon_condition(pid, String(card.get("id", "")), {}, true)
	else:
		_reckon_asset(pid, String(card.get("id", "")))
	_gs._broadcast_sync()
	_gs._emit_changed()
	await _gs.get_tree().create_timer(_CARD_DELAY).timeout


# Расплата актива сыщика (effect.onReckoning) — на владельца. «Можете» (optional) и
# discardSelf пока пропускаем — отдельная интерактивная логика (TODO).
func _reckon_asset(pid: String, aid: String) -> void:
	var prog: Array = AssetCatalog.reckoning_of(aid)
	if (prog as Array).size() == 1 and bool((prog[0] as Dictionary).get("optional", false)):
		return
	var p: Dictionary = _gs.players.get(pid, {})
	var inv: Dictionary = Investigators.get_data(String(p.get("investigator", "")))
	var res: Dictionary = _EffectRunner.run(prog, p, {"skills": inv.get("skills", {})})
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[Расплата актив %s] %s · %s" % [aid, _gs._name_of(pid), String(l_v)])
	for node_v: Variant in res.get("board", []):
		_gs._apply_board_effect(node_v as Dictionary)
