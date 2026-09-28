class_name AssetActionFlow
extends RefCounted

## Прогон программ актива — единственная точка, где исполняется Effect-DSL карты.
## Два слота:
##   action — самостоятельное действие (карточка с тегом "action"): тап по карте в
##            веере играет её как ОТДЕЛЬНОЕ действие фазы действий, а не как
##            модификатор проверки (те применяются тапом на брошенной проверке,
##            см. CheckFlow.activate);
##   onGain — программа при получении карты (услуги: сработала и ушла в сброс).
##
## Прогон ВСЕГДА интерактивный и шаговый: встретив узел, требующий игрока, движок
## останавливается, а мы показываем ему:
##   test          → общая модалка проверки (pending_check, driver="asset");
##   chosenMonster → модалка выбора монстра  (канал mythos_decision, driver="asset");
##   chosenSpace   → модалка выбора локации;
##   chosenInvestigator / choice → модалка выбора сыщика / ветки.
## Решение возвращается в resolve_check/resolve_decision, программа переигрывается
## с начала по записанным decisions/rolls и идёт дальше (тот же приём, что у мифов).
##
## Мутации игрока копим в dup и коммитим ТОЛЬКО в конце — переигровка после каждого
## решения иначе применила бы их повторно.
##
## Выдача карт (onGain) идёт ОЧЕРЕДЬЮ: покупка в магазине выдаёт несколько карт
## подряд, а прогон может встать на выборе — следующая ждёт своей очереди.
##
## Стоимость cost.discardSelf снимает карту из инвентаря ПОСЛЕ успешного прогона.

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

## Итог play(): нечего играть / отыграно сразу / ждём игрока (ход держим).
const PLAY_INVALID := -1
const PLAY_DONE := 0
const PLAY_WAITING := 1

var _gs: Node = null
var _run: Dictionary = {}  # {pid, slot, index, id, decisions, rolls, held} — идёт прогон
var _grants: Array = []  # очередь выдач onGain: [{pid, id}]


func _init(gs: Node) -> void:
	_gs = gs


# ── Публичное: действие актива ────────────────────────────────────────────────


## Актив игрока по индексу вместе с карточкой каталога: {} если индекс битый.
func asset_at(pid: String, index: int) -> Dictionary:
	var items: Array = (_gs.players.get(pid, {}) as Dictionary).get("items", [])
	if index < 0 or index >= items.size():
		return {}
	var it_v: Variant = items[index]
	if not (it_v is Dictionary):
		return {}
	return AssetCatalog.by_id(AssetCatalog.entry_id(it_v as Dictionary))


## Можно ли сыграть актив как самостоятельное действие (для UI и валидации хоста).
## Истощённая карта — нельзя: действие «раз в раунд» уже потрачено.
func can_play(pid: String, index: int) -> bool:
	var items: Array = (_gs.players.get(pid, {}) as Dictionary).get("items", [])
	if index < 0 or index >= items.size() or not (items[index] is Dictionary):
		return false
	if bool((items[index] as Dictionary).get("exhausted", false)):
		return false
	var asset: Dictionary = asset_at(pid, index)
	if not AssetCatalog.has_standalone_action(asset):
		return false
	# Карта бьёт по монстру, а монстров на поле нет — играть некого: действие
	# сгорело бы впустую, а карта выглядела бы доступной.
	if _needs_monster(AssetCatalog.standalone_action(asset)):
		return not (_gs._board.monster_choices() as Array).is_empty()
	return true


# Есть ли в программе узел, целящийся в монстра или в локацию с монстрами.
static func _needs_monster(node: Variant) -> bool:
	if node is Dictionary:
		var t: String = String((node as Dictionary).get("target", ""))
		if t == "chosenMonster" or t == "chosenSpace":
			return true
		for k: Variant in node:
			if _needs_monster((node as Dictionary)[k]):
				return true
	elif node is Array:
		for x: Variant in node:
			if _needs_monster(x):
				return true
	return false


## Хост: сыграть действие актива. PLAY_INVALID — играть нечего (действие не тратим),
## PLAY_DONE — отыграно целиком, PLAY_WAITING — ждём проверку/выбор, ход держим.
func play(pid: String, index: int) -> int:
	if not _gs.is_host() or not can_play(pid, index):
		return PLAY_INVALID
	if AssetCatalog.standalone_action(asset_at(pid, index)).is_empty():
		return PLAY_INVALID
	if not _run.is_empty():
		return PLAY_INVALID  # другой прогон ещё не закрыт — не начинаем второй
	var entry: String = String(asset_at(pid, index).get("id", ""))
	_run = {
		"pid": pid,
		"slot": "action",
		"index": index,
		"id": entry,
		"decisions": {},
		"rolls": {},
		"held": false,
	}
	_step()
	return PLAY_WAITING if not _run.is_empty() else PLAY_DONE


# ── Публичное: выдача карты с onGain ──────────────────────────────────────────


## Хост: выдать актив сыщику, исполнив его onGain. Услуга (onGain содержит
## discardCard) срабатывает и НЕ попадает в инвентарь; прочие — добавляются как
## {id, exhausted:false}. Единая точка получения актива (магазин и пр.).
func grant(pid: String, asset_id: String) -> void:
	if not _gs.is_host() or not _gs.players.has(pid):
		return
	var asset: Dictionary = AssetCatalog.by_id(asset_id)
	if asset.is_empty():
		return
	_take_from_supply(asset_id)
	if (_on_gain(asset) as Array).is_empty():
		_put_in_hand(pid, asset_id)  # без onGain — сразу в руку, очередь ни при чём
		return
	_grants.append({"pid": pid, "id": asset_id})
	_pump()


# Карта уходит из запасов: вон из колоды и с витрины. Сброс активов не хранится, а
# ВЫВОДИТСЯ (GameState.asset_discard_ids: поддержанные минус колода, витрина и руки),
# поэтому услуга, выданная мимо магазина (консоль, эффект карты), без этого шага
# так и считалась бы лежащей в колоде — и в сбросе не появлялась.
func _take_from_supply(asset_id: String) -> void:
	(_gs.asset_deck as Array).erase(asset_id)
	(_gs.shop_reserve as Array).erase(asset_id)


# ── Публичное: ответы игрока ──────────────────────────────────────────────────


## Хост: разрешена видимая проверка программы (диспетч из resolve_pending_check).
func resolve_check(pid: String, path: String, passed: bool) -> void:
	if not _gs.is_host() or _run.is_empty() or String(_run.get("pid", "")) != pid:
		return
	(_run["decisions"] as Dictionary)[path] = passed
	_step()


## Хост: игрок выбрал вариант в модалке решения (монстр / локация / сыщик / ветка).
## Что записать решением, зависит от вида: ref монстра или локации, pid сыщика,
## иначе — индекс ветки (так же разбирает выбор MythosFlow).
func resolve_decision(pid: String, index: int) -> void:
	if not _gs.is_host() or _run.is_empty() or String(_run.get("pid", "")) != pid:
		return
	var md: Dictionary = _gs.mythos_decision
	var opts: Array = md.get("options", [])
	var kind: String = String(md.get("kind", "choice"))
	var value: Variant = index
	if index >= 0 and index < (opts as Array).size():
		var opt: Dictionary = opts[index]
		match kind:
			"monster", "space", "destination", "asset":
				value = String(opt.get("ref", ""))
			"target":
				value = String(opt.get("pid", ""))
	(_run["decisions"] as Dictionary)[String(md.get("path", ""))] = value
	_gs.mythos_decision = {}
	_step()


# ── Внутреннее: шаг прогона ───────────────────────────────────────────────────


# Один проход программы: либо останавливаемся на вопросе к игроку, либо завершаем
# (коммит мутаций + board + оплата/выдача + освобождение хода).
func _step() -> void:
	var pid: String = String(_run.get("pid", ""))
	if not _gs.players.has(pid):
		_finish_run()
		return
	var asset: Dictionary = _asset_of_run(pid)
	var program: Array = _program_of_run(asset)
	var dup: Dictionary = (_gs.players[pid] as Dictionary).duplicate(true)
	var flow: Dictionary = {
		"interactive": true,
		"checks_visible": true,
		"decisions": _run.get("decisions", {}),
		"rolls": _run.get("rolls", {}),
		"pending": {},
		"slot": "",
	}
	var res: Dictionary = _EffectRunner.run(program, dup, _ctx(pid), flow)
	_run["rolls"] = flow.get("rolls", {})

	var pending: Dictionary = res.get("pending", {})
	# Пауза без kind — обычный choice (ветки в options), как у Мифов/встреч.
	var kind: String = String(pending.get("kind", "choice" if pending.has("options") else ""))
	if kind == "check":
		_hold()
		_run["check_started"] = true
		_gs._check.start(
			"effectCheck",
			pid,
			String(pending.get("skill", "lore")),
			int(pending.get("modifier", 0)),
			"assetAction"
		)
		_gs.pending_check = {
			"pid": pid,
			"driver": "asset",
			"path": String(pending.get("path", "")),
			"subject": AssetCatalog.card_payload(asset),
		}
		_sync()
		return
	if not kind.is_empty():
		_hold()
		# Общий канал модалки решения (его же использует forEach Мифов) — кого
		# будить на ответе, говорит driver.
		_gs.mythos_decision = {
			"active": true,
			"pid": pid,
			"driver": "asset",
			"kind": kind,
			"path": String(pending.get("path", "")),
			"options": pending.get("options", []),
			"title_key": String(asset.get("nameKey", "MYTHOS_DECISION_TITLE")),
			"prompt_key": _prompt_key(kind, String(pending.get("verb", ""))),
		}
		_sync()
		return

	# Программа отыграна целиком — коммитим.
	var before: Dictionary = _gs.players[pid]
	_gs.players[pid] = dup
	_log(pid, String(asset.get("id", "")), res)
	# Исход — в ленту: скрытые броски d6 (dieRoll тихий, модалки нет — иначе игрок
	# не видит, что выпало) и дельты сыщика (+улика и т.п.) для остальных.
	var rolls: Array = []
	for path_v: Variant in _run.get("rolls", {}) as Dictionary:
		var rec: Array = _run["rolls"][path_v]
		if not rec.is_empty():
			rolls.append(int(rec[0]))
			_gs.announce_action(pid, "die_roll", {"value": str(int(rec[0]))})
	ActionFeed.announce_deltas(_gs, pid, before, dup)
	var consumed: bool = false
	var board_events: Array = []  # что сделали board-verb'ы (они пишут node._events)
	for node_v: Variant in res.get("board", []):
		var node: Dictionary = node_v
		if String(node.get("do", "")) == "discardCard":
			consumed = true  # услуга: сработала и сбрасывается — в инвентарь не идёт
		elif String(node.get("do", "")) == "takeFromReserve":
			# Карта взята с витрины (gainAsset from:reserve) — снять её оттуда и
			# дотянуть витрину; из колоды она тоже выбывает.
			_take_from_supply(String(node.get("id", "")))
			_gs._refill_shop_reserve([String(node.get("id", ""))])
		else:
			node["_anchor_pid"] = pid  # относительные цели — от этого сыщика
			_gs.apply_board_effect(node)
			board_events.append_array(node.get("_events", []))
	var slot: String = String(_run.get("slot", ""))
	# Розыгрыш по действию — явное окно результата владельцу (карта, кубы, исход).
	if slot == "action":
		ActionFeed.collect_card_result(
			_gs, pid, String(asset.get("id", "")), before, _gs.players[pid], rolls, board_events
		)
	if slot == "onGain":
		_finish_grant(pid, String(_run.get("id", "")), consumed)
	elif consumed:
		# discardCard в программе / cost.discardSelf выбранной ветки — карта уходит.
		_discard_at(pid, _index_of(pid, String(_run.get("id", ""))))
	elif slot == "action":
		_pay(pid, int(_run.get("index", -1)), program)
	# triggered без сброса — карту не истощаем: триггер не действие.
	_finish_run()


# Индекс карты id в руке pid (-1 — нет).
func _index_of(pid: String, id: String) -> int:
	var items: Array = _gs.players.get(pid, {}).get("items", [])
	for i in range(items.size()):
		if AssetCatalog.entry_id(items[i]) == id:
			return i
	return -1


# Завершение прогона: чистим состояние, отпускаем ход (если держали) и берём
# следующую выдачу из очереди.
# ── Публичное: событийные триггеры (effect.triggered, on:<событие>) ──────────


## Хост: событие event у сыщика pid (rest / focus / defeatMonster / closeGate /
## gainClueResearch / spendClue / researchResolved / encounterResolved) — каждая
## карта в руке с triggered.on == event встаёт в очередь прогона (по одной, как
## выдачи). Программа с проверкой/выбором ставит ход на удержание (asset_acting) —
## снимает release_asset_turn. Боевой триггер (combatEncounter) — отдельный путь
## в EncounterFlow. true — хоть одна карта поставлена.
func fire_triggered(pid: String, event: String) -> bool:
	if not _gs.is_host() or not _gs.players.has(pid):
		return false
	var items: Array = _gs.players[pid].get("items", [])
	var any: bool = false
	for i in range(items.size()):
		var asset: Dictionary = AssetCatalog.by_id(AssetCatalog.entry_id(items[i]))
		for t_v: Variant in (asset.get("effect", {}) as Dictionary).get("triggered", []):
			var t: Dictionary = t_v
			if String(t.get("on", "")) != event:
				continue
			var program: Array = t.get("do", [])
			if program.is_empty():
				continue
			_grants.append(
				{
					"pid": pid,
					"id": String(asset.get("id", "")),
					"slot": "triggered",
					"program": program
				}
			)
			any = true
	if any:
		_pump()
	return any


## Идёт ли прогон (или ждёт очередь) у сыщика pid — держать ли ему ход.
func is_busy(pid: String) -> bool:
	if String(_run.get("pid", "")) == pid:
		return true
	for g_v: Variant in _grants:
		if String((g_v as Dictionary).get("pid", "")) == pid:
			return true
	return false


func _finish_run() -> void:
	var pid: String = String(_run.get("pid", ""))
	var held: bool = bool(_run.get("held", false))
	var slot: String = String(_run.get("slot", ""))
	var had_check: bool = bool(_run.get("check_started", false))
	_run = {}
	if String(_gs.pending_check.get("driver", "")) == "asset":
		_gs.pending_check = {}
	if String(_gs.mythos_decision.get("driver", "")) == "asset":
		_gs.mythos_decision = {}
	if had_check:
		_gs._check.clear()  # чужую активную проверку (магазин/встреча) не трогаем
	if held and (slot == "action" or slot == "triggered"):
		_gs._phase.release_asset_turn(pid)
	_sync()
	_pump()


# Выдача карты после отработавшего onGain.
func _finish_grant(pid: String, asset_id: String, consumed: bool) -> void:
	if consumed:
		GameConsole.log(
			"[Актив] %s — услуга «%s» применена и сброшена" % [_gs.name_of(pid), asset_id]
		)
		return
	_put_in_hand(pid, asset_id)


func _put_in_hand(pid: String, asset_id: String) -> void:
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	items.append({"id": asset_id, "exhausted": false})
	p["items"] = items
	GameConsole.log("[Актив] %s получил «%s»" % [_gs.name_of(pid), asset_id])


# Взять следующую выдачу из очереди (если прогон не идёт).
func _pump() -> void:
	if not _run.is_empty() or _grants.is_empty():
		return
	var g: Dictionary = _grants.pop_front()
	var pid: String = String(g.get("pid", ""))
	if not _gs.players.has(pid):
		_pump()
		return
	if String(g.get("slot", "")) == "triggered":
		# Карта могла уйти, пока ждала очереди (сброшена предыдущим триггером) —
		# тогда срабатывать нечему.
		var idx: int = _index_of(pid, String(g.get("id", "")))
		if idx < 0:
			_pump()
			return
		_run = {
			"pid": pid,
			"slot": "triggered",
			"index": idx,
			"id": String(g.get("id", "")),
			"program": g.get("program", []),
			"decisions": {},
			"rolls": {},
			"held": false,
		}
		_step()
		return
	_run = {
		"pid": pid,
		"slot": "onGain",
		"index": -1,
		"id": String(g.get("id", "")),
		"decisions": {},
		"rolls": {},
		"held": false,
	}
	_step()


# ── Внутреннее: мелочи ────────────────────────────────────────────────────────


# Контекст интерактивного прогона: навыки для test плюс варианты выбора цели.
func _ctx(pid: String) -> Dictionary:
	var inv: Dictionary = Investigators.get_data(String(_gs.players[pid].get("investigator", "")))
	return {
		"skills": inv.get("skills", {}),
		"monster_choices": _gs._board.monster_choices(),  # chosenMonster
		"space_choices": _gs._board.space_choices(),  # chosenSpace
		"other_pids": _gs._target.other_pids(pid),  # chosenInvestigator
		"locations": _gs.map.all(),  # move — куда шагать
		"reserve": (_gs.shop_reserve as Array).duplicate(),  # gainAsset from:reserve
	}


# Карточка каталога текущего прогона: для action — по индексу в руке, для onGain
# карты в руке ещё нет, поэтому по id.
func _asset_of_run(pid: String) -> Dictionary:
	if String(_run.get("slot", "")) != "action":
		return AssetCatalog.by_id(String(_run.get("id", "")))  # onGain/triggered — по id
	return asset_at(pid, int(_run.get("index", -1)))


func _program_of_run(asset: Dictionary) -> Array:
	match String(_run.get("slot", "")):
		"onGain":
			return _on_gain(asset)
		"triggered":
			return _run.get("program", [])
	return AssetCatalog.standalone_action(asset)


func _on_gain(asset: Dictionary) -> Array:
	return (asset.get("effect", {}) as Dictionary).get("onGain", [])


# Подсказка модалки: по виду выбора и глаголу — «кого сбросить» и «кого ранить»
# читаются по-разному. Пусто → модалка возьмёт подсказку по умолчанию.
func _prompt_key(kind: String, verb: String) -> String:
	match [kind, verb]:
		["monster", "discardMonster"], ["monster", "defeatMonster"]:
			return "PICK_MONSTER_DISCARD"
		["monster", "damageMonster"]:
			return "PICK_MONSTER_DAMAGE"
		["space", "damageMonster"]:
			return "PICK_SPACE_DAMAGE"
	return ""


# Прогон встал на вопросе к игроку — отмечаем, что ход придётся отпускать явно.
func _hold() -> void:
	_run["held"] = true
	# Триггер запускает не действие игрока, а событие — флаг удержания хода ставим
	# сами (у действия актива его ставит PhaseController по PLAY_WAITING).
	if String(_run.get("slot", "")) == "triggered":
		var pid: String = String(_run.get("pid", ""))
		if _gs.players.has(pid):
			_gs.players[pid]["asset_acting"] = true


func _sync() -> void:
	_gs.broadcast_sync()
	_gs.emit_changed()


# Оплата действия: cost.discardSelf снимает карту из инвентаря; иначе — истощаем до
# конца раунда (действие актива «раз в раунд», снимается на шаге Refresh).
func _pay(pid: String, index: int, program: Array) -> void:
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	if index < 0 or index >= items.size():
		return
	for n_v: Variant in program:
		var cost: Dictionary = (n_v as Dictionary).get("cost", {})
		if bool(cost.get("discardSelf", false)):
			items.remove_at(index)
			p["items"] = items
			return
	(items[index] as Dictionary)["exhausted"] = true


func _discard_at(pid: String, index: int) -> void:
	var p: Dictionary = _gs.players[pid]
	var items: Array = p.get("items", [])
	if index < 0 or index >= items.size():
		return
	GameConsole.log(
		"[Актив] %s — «%s» сброшен" % [_gs.name_of(pid), AssetCatalog.entry_id(items[index])]
	)
	items.remove_at(index)
	p["items"] = items


func _log(pid: String, card_id: String, res: Dictionary) -> void:
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[Актив] %s · %s: %s" % [_gs.name_of(pid), card_id, String(l_v)])
