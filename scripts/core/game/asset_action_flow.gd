class_name AssetActionFlow
extends RefCounted

## Самостоятельное действие актива (карточка с тегом "action"): тап по карте в
## веере играет её программу как ОТДЕЛЬНОЕ действие фазы действий — не как
## модификатор проверки (те применяются тапом уже на брошенной проверке, см.
## CheckFlow.activate).
##
## Два пути, как у локальных действий состояний (ConditionFlow):
##   begin(pid, idx)      — программа с test-узлом: гоняем интерактивно, узел
##                          пендит видимую проверку (pending_check driver="asset"),
##                          ход держит phase_controller до «Применить».
##   host_run(pid, idx)   — программа без проверки: исполняем синхронно.
##
## Стоимость cost.discardSelf снимает карту из инвентаря ПОСЛЕ успешного прогона.

const _EffectRunner = preload("res://scripts/core/game/effect_runner.gd")

var _gs: Node = null
var _run: Dictionary = {}  # {pid, index, id, decisions, rolls} — идёт интерактивный прогон


func _init(gs: Node) -> void:
	_gs = gs


# ── Публичное ─────────────────────────────────────────────────────────────────


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
	return AssetCatalog.has_standalone_action(asset_at(pid, index))


## Хост: начать действие с ВИДИМОЙ проверкой. false — проверки в программе нет
## (вызывающий пробует синхронный host_run).
func begin(pid: String, index: int) -> bool:
	if not _gs._is_host() or not can_play(pid, index):
		return false
	if _test_node(asset_at(pid, index)).is_empty():
		return false
	var entry: String = String(asset_at(pid, index).get("id", ""))
	_run = {"pid": pid, "index": index, "id": entry, "decisions": {}, "rolls": {}}
	_step(pid)  # прогонит программу и запендит первую видимую проверку
	return true


## Хост: разрешить видимую проверку программы (диспетч из resolve_pending_check).
func resolve_check(pid: String, path: String, passed: bool) -> void:
	if not _gs._is_host() or _run.is_empty() or String(_run.get("pid", "")) != pid:
		return
	(_run["decisions"] as Dictionary)[path] = passed
	_step(pid)


## Хост: исполнить действие БЕЗ проверки синхронно. false — играть нечего.
func host_run(pid: String, index: int) -> bool:
	if not _gs._is_host() or not can_play(pid, index):
		return false
	var asset: Dictionary = asset_at(pid, index)
	var program: Array = AssetCatalog.standalone_action(asset)
	if program.is_empty():
		return false
	var p: Dictionary = _gs.players[pid]
	var inv: Dictionary = Investigators.get_data(String(p.get("investigator", "")))
	var res: Dictionary = _EffectRunner.run(program, p, {"skills": inv.get("skills", {})})
	_log(pid, String(asset.get("id", "")), res)
	for node_v: Variant in res.get("board", []):
		_gs._apply_board_effect(node_v as Dictionary)
	_pay(pid, index, program)
	return true


# ── Внутреннее ────────────────────────────────────────────────────────────────


# Шаг интерактивного прогона: либо пендим следующую видимую проверку, либо
# завершаем (коммит мутаций + board + оплата + освобождение хода).
func _step(pid: String) -> void:
	var index: int = int(_run.get("index", -1))
	var asset: Dictionary = asset_at(pid, index)
	var program: Array = AssetCatalog.standalone_action(asset)
	var inv: Dictionary = Investigators.get_data(String(_gs.players[pid].get("investigator", "")))
	var dup: Dictionary = (_gs.players[pid] as Dictionary).duplicate(true)
	var flow: Dictionary = {
		"interactive": true,
		"checks_visible": true,
		"decisions": _run.get("decisions", {}),
		"rolls": _run.get("rolls", {}),
		"pending": {},
		"slot": "",
	}
	var res: Dictionary = _EffectRunner.run(program, dup, {"skills": inv.get("skills", {})}, flow)
	_run["rolls"] = flow.get("rolls", {})

	var pending: Dictionary = res.get("pending", {})
	if String(pending.get("kind", "")) == "check":
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
		return  # ждём resolve_check; ход держит phase_controller

	_gs.players[pid] = dup
	_log(pid, String(asset.get("id", "")), res)
	for node_v: Variant in res.get("board", []):
		_gs._apply_board_effect(node_v as Dictionary)
	_pay(pid, index, program)
	_run = {}
	_gs.pending_check = {}
	_gs._check.clear()
	_gs._phase.release_asset_turn(pid)


# Первый test-узел программы ({} — действие без видимой проверки).
func _test_node(asset: Dictionary) -> Dictionary:
	for n_v: Variant in AssetCatalog.standalone_action(asset):
		if n_v is Dictionary and (n_v as Dictionary).has("test"):
			return n_v
	return {}


# Оплата: cost.discardSelf снимает карту из инвентаря; иначе — истощаем до конца
# раунда (действие актива «раз в раунд», снимается на шаге Refresh).
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


func _log(pid: String, card_id: String, res: Dictionary) -> void:
	for l_v: Variant in res.get("logs", []):
		GameConsole.log("[Актив] %s · %s: %s" % [_gs._name_of(pid), card_id, String(l_v)])
