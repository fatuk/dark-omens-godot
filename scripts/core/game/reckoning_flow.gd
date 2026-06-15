class_name ReckoningFlow
extends RefCounted

## Шаг Расплаты (host-only, корутина). Полный порядок: Древний → карты Мифов в игре →
## монстры → сыщики (по ходу, Ведущий первым). Глобальные тиры гоняют onReckoning через
## EffectRunner (board-эффекты типа advanceDoom/dieRoll и цели target:each). Тир сыщиков
## резолвит карты Расплаты: состояния — флип через ConditionFlow; активы — effect
## .onReckoning. scope=="mythosInPlay" → только тир карт Мифов в игре (для строки
## «resolve the Reckoning of each Mythos card in play»). Создаётся в GameState (_reckoning).
##
## NB: порядок карт сыщика здесь ДЕФОЛТНЫЙ (состояния, затем активы). Выбор порядка
## самим сыщиком добавляется отдельным шагом (через mythos_decision).

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")
const _CARD_DELAY := 0.3  # пауза между картами Расплаты сыщика (под анимацию)

var _gs: Node


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
	_apply_global(
		AncientCatalog.reckoning_of(String(_gs.campaign.get("ancientOne", ""))), "Древний"
	)


# Тир 2: Расплата каждой карты Мифов в игре (её onReckoning-эффект, без триггеров).
func _reckon_mythos_in_play() -> void:
	for c_v: Variant in _gs.mythos_in_play as Array:
		var card: Dictionary = c_v
		_apply_global(
			_effect_nodes(card.get("onReckoning", [])),
			"Миф «%s»" % String(card.get("name", "?")),
		)


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


# Сыщики по ходу (Ведущий первым); каждый резолвит свои карты Расплаты.
func _reckon_investigators() -> void:
	for pid_v: Variant in _gs._target._resolve_targets({"target": "each"}):
		await _reckon_investigator(String(pid_v))


# Расплата одного сыщика: его карты (состояния с onReckoning + активы с
# effect.onReckoning) в дефолтном порядке.
func _reckon_investigator(pid: String) -> void:
	if not _gs.players.has(pid):
		return
	for card_v: Variant in _collect_reckoning_cards(pid):
		await _resolve_card(pid, card_v as Dictionary)


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
		_gs._cond.reckon_condition(pid, String(card.get("id", "")))
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
